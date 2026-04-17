import Foundation
@preconcurrency import AVFoundation

struct MumbleTransmitAudioFrame: Sendable {
    let frameNumber: UInt64
    let payload: Data
    let isTerminator: Bool
    let targetOrContext: UInt32
}

struct MumbleTransmitPCMAccumulator: Sendable {
    static let packetFrameSize = 960

    private(set) var pendingSamples: [Float] = []

    mutating func append(samples: [Float]) -> [[Float]] {
        pendingSamples.append(contentsOf: samples)

        var frames: [[Float]] = []
        while pendingSamples.count >= Self.packetFrameSize {
            frames.append(Array(pendingSamples.prefix(Self.packetFrameSize)))
            pendingSamples.removeFirst(Self.packetFrameSize)
        }

        return frames
    }

    mutating func finishFrame() -> [Float] {
        let frame: [Float]
        if pendingSamples.isEmpty {
            frame = [Float](repeating: 0, count: Self.packetFrameSize)
        } else if pendingSamples.count == Self.packetFrameSize {
            frame = pendingSamples
        } else {
            frame = pendingSamples + [Float](repeating: 0, count: Self.packetFrameSize - pendingSamples.count)
        }

        pendingSamples.removeAll(keepingCapacity: true)
        return frame
    }
}

struct MumbleTransmitFrameSequencer: Sendable {
    private(set) var nextFrameNumber: UInt64 = 0

    mutating func reserveFrameNumber(forPCMFrameCount frameCount: Int) -> UInt64 {
        let reservedFrameNumber = nextFrameNumber
        let frameStep = max(1, frameCount / 480)
        nextFrameNumber += UInt64(frameStep)
        return reservedFrameNumber
    }
}

final class MumbleAudioCaptureController: @unchecked Sendable {
    private let logger: AppLogger
    private let onEncodedFrame: @Sendable (MumbleTransmitAudioFrame) -> Void
    private let processingQueue = DispatchQueue(label: "dev.kiwiapps.Mumble.audio.capture")
    private let engine = AVAudioEngine()
    private let targetPCMFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    private var pcmConverter: AVAudioConverter?
    private var opusEncoder: MumbleOpusEncoder?
    private var accumulator = MumbleTransmitPCMAccumulator()
    private var frameSequencer = MumbleTransmitFrameSequencer()
    private var inputVolume: Float = 1.0
    private var isMicrophoneMuted = false
    private var isTransmitting = false
    private var transmitMode: MumblePushToTalkMode = .localChannel
    private var didInstallTap = false
    private var encodedFrameCount = 0
    private var failedPCMConversionCount = 0

    init(
        logger: AppLogger,
        onEncodedFrame: @escaping @Sendable (MumbleTransmitAudioFrame) -> Void
    ) {
        self.logger = logger
        self.onEncodedFrame = onEncodedFrame
    }

    func updatePreferences(inputVolume: Double, isMicrophoneMuted: Bool) {
        processingQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.inputVolume = Float(min(max(inputVolume, 0), 2))
            self.isMicrophoneMuted = isMicrophoneMuted
        }
    }

    func startTransmitting(mode: MumblePushToTalkMode) {
        processingQueue.async { [weak self] in
            self?.startTransmittingOnQueue(mode: mode)
        }
    }

    func stopTransmitting() {
        processingQueue.async { [weak self] in
            self?.stopTransmittingOnQueue()
        }
    }

    func stop() {
        processingQueue.async { [weak self] in
            self?.stopCaptureOnQueue(sendTerminator: false)
            self?.frameSequencer = MumbleTransmitFrameSequencer()
        }
    }

    private func startTransmittingOnQueue(mode: MumblePushToTalkMode) {
        transmitMode = mode

        guard !isTransmitting else {
            return
        }

        guard !isMicrophoneMuted else {
            logger.info("Ignoring push-to-talk because the microphone is muted.")
            return
        }

        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch authorizationStatus {
        case .authorized:
            doStartCaptureOnQueue()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else {
                    return
                }

                self.processingQueue.async {
                    if granted {
                        self.doStartCaptureOnQueue()
                    } else {
                        self.logger.error("Microphone access was denied by macOS.")
                    }
                }
            }
        default:
            logger.error("Microphone access is unavailable. Grant microphone permission to enable push-to-talk.")
        }
    }

    private func doStartCaptureOnQueue() {
        guard !isTransmitting else {
            return
        }

        do {
            try ensureCapturePipelineOnQueue()
            accumulator = MumbleTransmitPCMAccumulator()
            isTransmitting = true
            if !engine.isRunning {
                try engine.start()
                logger.info(
                    "Microphone engine started with input format " +
                    "\(inputFormatDescription(engine.inputNode.inputFormat(forBus: 0)))."
                )
            }
            logger.info("Push-to-talk audio capture started.")
        } catch {
            logger.error("Failed to start microphone capture: \(error.localizedDescription)")
            stopCaptureOnQueue(sendTerminator: false)
        }
    }

    private func stopTransmittingOnQueue() {
        guard isTransmitting else {
            return
        }

        isTransmitting = false
        sendTerminatorFrameOnQueue()
        accumulator = MumbleTransmitPCMAccumulator()
        logger.info("Push-to-talk audio capture stopped.")
    }

    private func stopCaptureOnQueue(sendTerminator: Bool) {
        if sendTerminator {
            sendTerminatorFrameOnQueue()
        }

        if didInstallTap {
            engine.inputNode.removeTap(onBus: 0)
            didInstallTap = false
        }

        if engine.isRunning {
            engine.stop()
        }

        accumulator = MumbleTransmitPCMAccumulator()
        failedPCMConversionCount = 0
    }

    private func ensureCapturePipelineOnQueue() throws {
        if opusEncoder == nil {
            guard let opusEncoder = MumbleOpusEncoder() else {
                throw MumbleAudioCaptureError.encoderUnavailable
            }
            self.opusEncoder = opusEncoder
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        if pcmConverter == nil || pcmConverter?.inputFormat != inputFormat {
            pcmConverter = AVAudioConverter(from: inputFormat, to: targetPCMFormat)
            logger.info(
                "Configured microphone PCM converter from \(inputFormatDescription(inputFormat)) " +
                "to \(inputFormatDescription(targetPCMFormat))."
            )
        }

        if !didInstallTap {
            inputNode.installTap(
                onBus: 0,
                bufferSize: 1_024,
                format: inputFormat
            ) { [weak self] buffer, _ in
                guard let self else {
                    return
                }

                guard let copiedBuffer = buffer.mumble_copy() else {
                    return
                }

                self.processingQueue.async {
                    self.handleCapturedBufferOnQueue(copiedBuffer)
                }
            }
            didInstallTap = true
        }

        engine.prepare()
    }

    private func handleCapturedBufferOnQueue(_ buffer: AVAudioPCMBuffer) {
        guard isTransmitting else {
            return
        }

        guard let convertedBuffer = convertToTargetPCM(buffer) else {
            logger.error("Failed to convert microphone audio into the Opus input format.")
            return
        }

        let samples = convertedBuffer.mumble_samples()
        guard !samples.isEmpty else {
            return
        }

        let scaledSamples = inputVolume == 1.0
            ? samples
            : samples.map { min(max($0 * inputVolume, -1.0), 1.0) }

        for frameSamples in accumulator.append(samples: scaledSamples) {
            encodeAndEmitFrameOnQueue(frameSamples, isTerminator: false)
        }
    }

    private func convertToTargetPCM(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.mumble_matches(targetPCMFormat) {
            return buffer
        }

        guard let pcmConverter else {
            return nil
        }

        let ratio = targetPCMFormat.sampleRate / buffer.format.sampleRate
        let estimatedFrameCapacity = AVAudioFrameCount(
            max(Double(buffer.frameLength) * ratio + 32, Double(MumbleTransmitPCMAccumulator.packetFrameSize))
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetPCMFormat,
            frameCapacity: estimatedFrameCapacity
        ) else {
            return nil
        }

        var didSupplyInput = false
        var conversionError: NSError?
        pcmConverter.reset()

        let status = pcmConverter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didSupplyInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            didSupplyInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            failedPCMConversionCount += 1
            logger.error(
                "Microphone PCM conversion failed #\(failedPCMConversionCount): \(conversionError.localizedDescription). " +
                "source=\(inputFormatDescription(buffer.format)), target=\(inputFormatDescription(targetPCMFormat)), " +
                "frames=\(buffer.frameLength)"
            )
            return nil
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return outputBuffer.frameLength > 0 ? outputBuffer : nil
        case .error:
            failedPCMConversionCount += 1
            logger.error(
                "Microphone PCM conversion returned .error #\(failedPCMConversionCount). " +
                "source=\(inputFormatDescription(buffer.format)), target=\(inputFormatDescription(targetPCMFormat)), " +
                "frames=\(buffer.frameLength)"
            )
            return nil
        @unknown default:
            failedPCMConversionCount += 1
            logger.error(
                "Microphone PCM conversion returned an unknown status #\(failedPCMConversionCount). " +
                "source=\(inputFormatDescription(buffer.format)), target=\(inputFormatDescription(targetPCMFormat)), " +
                "frames=\(buffer.frameLength)"
            )
            return nil
        }
    }

    private func sendTerminatorFrameOnQueue() {
        encodeAndEmitFrameOnQueue(accumulator.finishFrame(), isTerminator: true)
    }

    private func encodeAndEmitFrameOnQueue(_ frameSamples: [Float], isTerminator: Bool) {
        guard let opusEncoder else {
            return
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: targetPCMFormat,
            frameCapacity: AVAudioFrameCount(frameSamples.count)
        ) else {
            logger.error("Failed to allocate microphone PCM buffer.")
            return
        }

        buffer.frameLength = AVAudioFrameCount(frameSamples.count)
        guard let channelData = buffer.floatChannelData?.pointee else {
            logger.error("Failed to access microphone PCM channel data.")
            return
        }

        frameSamples.withUnsafeBufferPointer { samples in
            guard let baseAddress = samples.baseAddress else {
                return
            }

            channelData.update(from: baseAddress, count: frameSamples.count)
        }

        do {
            guard let payload = try opusEncoder.encode(buffer: buffer), !payload.isEmpty else {
                logger.error("Opus encoder returned an empty payload for transmit audio.")
                return
            }

            let frameNumber = frameSequencer.reserveFrameNumber(forPCMFrameCount: frameSamples.count)
            onEncodedFrame(
                MumbleTransmitAudioFrame(
                    frameNumber: frameNumber,
                    payload: payload,
                    isTerminator: isTerminator,
                    targetOrContext: transmitMode.targetOrContext
                )
            )

            encodedFrameCount += 1
            if encodedFrameCount <= 5 || encodedFrameCount % 50 == 0 {
                logger.info(
                    "Encoded transmit audio frame #\(encodedFrameCount), frameNumber=\(frameNumber), " +
                    "payloadBytes=\(payload.count), terminator=\(isTerminator)"
                )
            }
        } catch {
            logger.error("Failed to encode microphone audio: \(error.localizedDescription)")
        }
    }

    private func inputFormatDescription(_ format: AVAudioFormat) -> String {
        let commonFormat: String
        switch format.commonFormat {
        case .pcmFormatFloat32:
            commonFormat = "float32"
        case .pcmFormatFloat64:
            commonFormat = "float64"
        case .pcmFormatInt16:
            commonFormat = "int16"
        case .pcmFormatInt32:
            commonFormat = "int32"
        case .otherFormat:
            commonFormat = "other"
        @unknown default:
            commonFormat = "unknown"
        }

        return "\(commonFormat), \(Int(format.channelCount))ch, \(Int(format.sampleRate))Hz, interleaved=\(format.isInterleaved)"
    }
}

private extension AVAudioPCMBuffer {
    func mumble_copy() -> AVAudioPCMBuffer? {
        guard let copiedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }

        copiedBuffer.frameLength = frameLength

        let byteSize = Int(format.streamDescription.pointee.mBytesPerFrame) * Int(frameLength)
        if let source = floatChannelData, let destination = copiedBuffer.floatChannelData {
            for channelIndex in 0..<Int(format.channelCount) {
                memcpy(destination[channelIndex], source[channelIndex], byteSize)
            }
            return copiedBuffer
        }

        if let source = int16ChannelData, let destination = copiedBuffer.int16ChannelData {
            for channelIndex in 0..<Int(format.channelCount) {
                memcpy(destination[channelIndex], source[channelIndex], byteSize)
            }
            return copiedBuffer
        }

        return nil
    }

    func mumble_samples() -> [Float] {
        guard
            format.channelCount == 1,
            let channelData = floatChannelData?.pointee
        else {
            return []
        }

        let frameCount = Int(frameLength)
        return Array(UnsafeBufferPointer(start: channelData, count: frameCount))
    }
}

private extension AVAudioFormat {
    func mumble_matches(_ other: AVAudioFormat) -> Bool {
        commonFormat == other.commonFormat &&
        channelCount == other.channelCount &&
        sampleRate == other.sampleRate &&
        isInterleaved == other.isInterleaved
    }
}

enum MumbleAudioCaptureError: Error {
    case encoderUnavailable
}
