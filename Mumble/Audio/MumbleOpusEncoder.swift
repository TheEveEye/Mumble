import Foundation
@preconcurrency import AVFoundation
import AudioToolbox

final class MumbleOpusEncoder: @unchecked Sendable {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    nonisolated init?(
        sampleRate: Double = 48_000,
        channelCount: AVAudioChannelCount = 1,
        bitrate: Int = 40_000
    ) {
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channelCount,
                interleaved: false
            ),
            let outputFormat = AVAudioFormat(
                settings: [
                    AVFormatIDKey: kAudioFormatOpus,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channelCount,
                    AVEncoderBitRateKey: bitrate,
                ]
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            return nil
        }

        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    nonisolated var pcmInputFormat: AVAudioFormat {
        inputFormat
    }

    nonisolated func encode(buffer: AVAudioPCMBuffer) throws -> Data? {
        guard buffer.frameLength > 0 else {
            return nil
        }

        let compressedBuffer = AVAudioCompressedBuffer(
            format: outputFormat,
            packetCapacity: 1,
            maximumPacketSize: max(converter.maximumOutputPacketSize, 4_096)
        )

        var didSupplyInput = false
        var conversionError: NSError?

        let status = converter.convert(to: compressedBuffer, error: &conversionError) { _, outStatus in
            if didSupplyInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            didSupplyInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            throw conversionError
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            guard compressedBuffer.byteLength > 0 else {
                return nil
            }

            return Data(bytes: compressedBuffer.data, count: Int(compressedBuffer.byteLength))
        case .error:
            throw MumbleOpusEncoderError.conversionFailed
        @unknown default:
            throw MumbleOpusEncoderError.conversionFailed
        }
    }
}

enum MumbleOpusEncoderError: Error {
    case conversionFailed
}
