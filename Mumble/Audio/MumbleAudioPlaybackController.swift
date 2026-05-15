import Foundation
import AVFoundation
import AudioToolbox

struct MumbleAudioSessionContext {
    let currentSessionID: UInt32?
    let activeChannelID: UInt32?
    let usersBySession: [UInt32: MumbleUser]
    let channelsByID: [UInt32: MumbleChannel]
}

actor MumbleAudioPlaybackController {
    private let logger: AppLogger
    private let outputDeviceCatalog: any MumbleAudioOutputDeviceCatalog
    private let engine = AVAudioEngine()
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    private var decoders: [UInt32: MumbleOpusDecoder] = [:]
    private var playerNodes: [UInt32: AVAudioPlayerNode] = [:]
    private var context = MumbleAudioSessionContext(
        currentSessionID: nil,
        activeChannelID: nil,
        usersBySession: [:],
        channelsByID: [:]
    )
    private var hasStartedEngine = false
    private var outputVolume: Float = 1.0
    private var isOutputMuted = false
    private var selectedOutputDeviceUID: String?
    private var receivedVoicePacketCount = 0
    private var rejectedVoicePacketCount = 0
    private var scheduledBufferCount = 0

    init(
        logger: AppLogger,
        outputDeviceCatalog: any MumbleAudioOutputDeviceCatalog = CoreAudioInputDeviceCatalog()
    ) {
        self.logger = logger
        self.outputDeviceCatalog = outputDeviceCatalog
    }

    func updatePreferences(outputVolume: Double, isOutputMuted: Bool, selectedOutputDeviceUID: String?) {
        let normalizedOutputDeviceUID = MumbleAudioOutputDeviceSelection.normalizedUID(selectedOutputDeviceUID)
        let didChangeOutputDevice = self.selectedOutputDeviceUID != normalizedOutputDeviceUID

        self.outputVolume = Float(min(max(outputVolume, 0), 2))
        self.isOutputMuted = isOutputMuted
        self.selectedOutputDeviceUID = normalizedOutputDeviceUID
        engine.mainMixerNode.outputVolume = isOutputMuted ? 0 : self.outputVolume

        if didChangeOutputDevice, hasStartedEngine {
            resetPlaybackPipeline()
        }

        logger.info(
            "Audio playback preferences updated: muted=\(isOutputMuted), " +
            "volume=\(String(format: "%.2f", self.outputVolume)), " +
            "outputDevice=\(normalizedOutputDeviceUID ?? "system-default")"
        )
    }

    func updateSession(channels: [MumbleChannel], users: [MumbleUser], currentSessionID: UInt32?) {
        let usersBySession = Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0) })
        let channelsByID = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })
        let activeChannelID = currentSessionID.flatMap { usersBySession[$0]?.channelID }

        context = MumbleAudioSessionContext(
            currentSessionID: currentSessionID,
            activeChannelID: activeChannelID,
            usersBySession: usersBySession,
            channelsByID: channelsByID
        )

        let activeSessions = Set(users.map(\.id))
        let removableSessions = Set(playerNodes.keys).subtracting(activeSessions)
        for sessionID in removableSessions {
            removePlaybackResources(for: sessionID)
        }

        logger.debug(
            "Audio session updated: currentSessionID=\(currentSessionID.map(String.init) ?? "nil"), " +
            "activeChannelID=\(activeChannelID.map(String.init) ?? "nil"), users=\(users.count)"
        )
    }

    func handleVoicePacket(_ packet: MumbleVoicePacket) {
        receivedVoicePacketCount += 1
        if shouldLog(packetIndex: receivedVoicePacketCount) {
            logger.info(
                "Received voice packet #\(receivedVoicePacketCount) from session \(packet.senderSession), " +
                "frame=\(packet.frameNumber), payloadBytes=\(packet.payload.count)"
            )
        }

        if let rejectionReason = MumbleAudioPlaybackPolicy.rejectionReason(
            for: packet,
            context: context,
            isOutputMuted: isOutputMuted
        ) {
            logRejectedPacket(reason: rejectionReason, packet: packet)
            return
        }

        do {
            try startEngineIfNeeded()
            let decoder = try decoder(for: packet.senderSession)

            guard let buffer = try decoder.decode(packet: packet.payload) else {
                logger.error("Opus decoder returned no PCM buffer for session \(packet.senderSession).")
                return
            }

            if packet.volumeAdjustment != 1.0 {
                scale(buffer: buffer, by: packet.volumeAdjustment)
            }

            let playerNode = playerNode(for: packet.senderSession)
            playerNode.scheduleBuffer(buffer)
            scheduledBufferCount += 1
            if shouldLog(packetIndex: scheduledBufferCount) {
                logger.info(
                    "Scheduled audio buffer #\(scheduledBufferCount) for session \(packet.senderSession), " +
                    "frames=\(buffer.frameLength), sampleRate=\(Int(buffer.format.sampleRate))"
                )
            }

            if !playerNode.isPlaying {
                playerNode.play()
                logger.info("Started playback node for session \(packet.senderSession).")
            }
        } catch {
            logger.error("Audio playback failed for session \(packet.senderSession): \(error.localizedDescription)")
        }
    }

    func stop() {
        resetPlaybackPipeline()
        context = MumbleAudioSessionContext(
            currentSessionID: nil,
            activeChannelID: nil,
            usersBySession: [:],
            channelsByID: [:]
        )
        logger.info("Audio playback stopped and session state cleared.")
    }

    private func startEngineIfNeeded() throws {
        guard !hasStartedEngine else {
            return
        }

        configureOutputDevice()
        engine.mainMixerNode.outputVolume = isOutputMuted ? 0 : outputVolume
        try engine.start()
        hasStartedEngine = true
        logger.info("Audio engine started for receive-only playback.")
    }

    private func configureOutputDevice() {
        let requestedUID = selectedOutputDeviceUID
        let resolution: MumbleAudioOutputDeviceResolution

        do {
            resolution = try outputDeviceCatalog.resolveOutputDevice(selectedUID: requestedUID)
        } catch {
            logger.error("Failed to enumerate playback output devices: \(error.localizedDescription). Using the system default output.")
            return
        }

        if resolution.didFallbackFromMissingSelection, let requestedUID = resolution.requestedUID {
            logger.error("Selected playback output \(requestedUID) is not available. Falling back to the system default output.")
        }

        guard let device = resolution.device else {
            logger.error("No available playback output device was found. Using AVAudioEngine's default output.")
            return
        }

        do {
            try setEngineOutputDevice(device)
            logger.info("Using playback output device \"\(device.displayName)\" (\(device.uid)).")
        } catch {
            guard requestedUID != nil else {
                logger.error("Failed to open the system default playback output: \(error.localizedDescription).")
                return
            }

            logger.error("Failed to open selected playback output \"\(device.displayName)\": \(error.localizedDescription). Falling back to the system default output.")
            do {
                let fallbackResolution = try outputDeviceCatalog.resolveOutputDevice(selectedUID: nil)
                guard let fallbackDevice = fallbackResolution.device else {
                    logger.error("No system default playback output is available.")
                    return
                }

                try setEngineOutputDevice(fallbackDevice)
                logger.info("Using fallback playback output device \"\(fallbackDevice.displayName)\" (\(fallbackDevice.uid)).")
            } catch {
                logger.error("Failed to open fallback system playback output: \(error.localizedDescription).")
            }
        }
    }

    private func setEngineOutputDevice(_ device: MumbleAudioOutputDevice) throws {
        guard let audioUnit = engine.outputNode.audioUnit else {
            throw MumbleAudioPlaybackError.outputAudioUnitUnavailable
        }

        var deviceID = device.audioDeviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw MumbleAudioPlaybackError.outputDeviceSelectionFailed(status)
        }
    }

    private func decoder(for sessionID: UInt32) throws -> MumbleOpusDecoder {
        if let decoder = decoders[sessionID] {
            return decoder
        }

        guard let decoder = MumbleOpusDecoder() else {
            throw MumbleAudioPlaybackError.decoderUnavailable
        }

        decoders[sessionID] = decoder
        return decoder
    }

    private func playerNode(for sessionID: UInt32) -> AVAudioPlayerNode {
        if let existingNode = playerNodes[sessionID] {
            return existingNode
        }

        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: outputFormat)
        playerNodes[sessionID] = node
        logger.debug("Created playback node for session \(sessionID).")
        return node
    }

    private func removePlaybackResources(for sessionID: UInt32) {
        if let playerNode = playerNodes.removeValue(forKey: sessionID) {
            playerNode.stop()
            engine.disconnectNodeOutput(playerNode)
            engine.detach(playerNode)
        }

        decoders.removeValue(forKey: sessionID)
    }

    private func resetPlaybackPipeline() {
        for sessionID in Array(playerNodes.keys) {
            removePlaybackResources(for: sessionID)
        }

        if engine.isRunning {
            engine.stop()
        }

        engine.reset()
        hasStartedEngine = false
    }

    private func logRejectedPacket(reason: PlaybackRejectionReason, packet: MumbleVoicePacket) {
        rejectedVoicePacketCount += 1
        guard shouldLog(packetIndex: rejectedVoicePacketCount) else {
            return
        }

        logger.info(
            "Rejected voice packet #\(rejectedVoicePacketCount) from session \(packet.senderSession): \(reason.rawValue). " +
            "currentSessionID=\(context.currentSessionID.map(String.init) ?? "nil"), " +
            "activeChannelID=\(context.activeChannelID.map(String.init) ?? "nil"), " +
            "senderChannelID=\(context.usersBySession[packet.senderSession]?.channelID.map(String.init) ?? "nil")"
        )
    }

    private func shouldLog(packetIndex: Int) -> Bool {
        packetIndex <= 5 || packetIndex % 50 == 0
    }

    private func scale(buffer: AVAudioPCMBuffer, by factor: Float) {
        guard let channelData = buffer.floatChannelData else {
            return
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        for channelIndex in 0..<channelCount {
            let samples = channelData[channelIndex]
            for frameIndex in 0..<frameCount {
                samples[frameIndex] *= factor
            }
        }
    }
}

enum MumbleAudioPlaybackError: Error {
    case decoderUnavailable
    case outputAudioUnitUnavailable
    case outputDeviceSelectionFailed(OSStatus)
}

enum PlaybackRejectionReason: String {
    case outputMuted = "output muted"
    case missingCurrentSession = "missing current session"
}

enum MumbleAudioPlaybackPolicy {
    nonisolated static func rejectionReason(
        for packet: MumbleVoicePacket,
        context: MumbleAudioSessionContext,
        isOutputMuted: Bool
    ) -> PlaybackRejectionReason? {
        if isOutputMuted {
            return .outputMuted
        }

        guard let currentSessionID = context.currentSessionID, currentSessionID != 0 else {
            return .missingCurrentSession
        }

        _ = currentSessionID
        _ = context
        _ = packet
        return nil
    }
}
