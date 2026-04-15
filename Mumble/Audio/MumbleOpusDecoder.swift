import Foundation
@preconcurrency import AVFoundation
import AudioToolbox

final class MumbleOpusDecoder: @unchecked Sendable {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    nonisolated init?() {
        let sampleRate = 48_000.0
        let channelCount: AVAudioChannelCount = 2

        guard
            let inputFormat = AVAudioFormat(
                settings: [
                    AVFormatIDKey: kAudioFormatOpus,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channelCount,
                ]
            ),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channelCount,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            return nil
        }

        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    nonisolated func decode(packet: Data) throws -> AVAudioPCMBuffer? {
        guard !packet.isEmpty else {
            return nil
        }

        let maximumFrameCount: AVAudioFrameCount = 2_880

        let compressedBuffer = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: 1,
            maximumPacketSize: packet.count
        )
        compressedBuffer.byteLength = UInt32(packet.count)
        compressedBuffer.packetCount = 1
        packet.withUnsafeBytes { packetBytes in
            guard let packetBaseAddress = packetBytes.baseAddress else {
                return
            }

            memcpy(compressedBuffer.data, packetBaseAddress, packet.count)
        }

        compressedBuffer.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(packet.count)
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: maximumFrameCount
        ) else {
            throw MumbleOpusDecoderError.outputBufferAllocationFailed
        }

        var didSupplyInput = false
        var conversionError: NSError?

        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didSupplyInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didSupplyInput = true
            outStatus.pointee = .haveData
            return compressedBuffer
        }

        if let conversionError {
            throw conversionError
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return outputBuffer.frameLength == 0 ? nil : outputBuffer
        case .error:
            throw MumbleOpusDecoderError.conversionFailed
        @unknown default:
            throw MumbleOpusDecoderError.conversionFailed
        }
    }
}

enum MumbleOpusDecoderError: Error {
    case outputBufferAllocationFailed
    case conversionFailed
}
