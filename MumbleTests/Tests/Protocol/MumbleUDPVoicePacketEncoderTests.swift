import Foundation
import Testing
@testable import Mumble

struct MumbleUDPVoicePacketEncoderTests {
    @Test
    func legacyClientOpusPacketEncoderSetsTargetFrameAndTerminatorBit() {
        let opusPayload = Data([0xde, 0xad, 0xbe, 0xef])

        guard let packet = MumbleUDPVoicePacketEncoder.encodeLegacyClientOpusPacket(
            frameNumber: 9001,
            payload: opusPayload,
            isTerminator: true,
            targetOrContext: 3
        ) else {
            Issue.record("Expected legacy client voice packet")
            return
        }

        #expect(packet.first == 0x83)

        let payload = packet.dropFirst()
        var index = payload.startIndex
        let decodedFrameNumber = decodeLegacyVarint(from: payload, index: &index)
        let decodedPayloadHeader = decodeLegacyVarint(from: payload, index: &index)
        let remainingPayload = Data(payload[index...])

        #expect(decodedFrameNumber == 9001)
        #expect(decodedPayloadHeader == UInt64(0x2000 | opusPayload.count))
        #expect(remainingPayload == opusPayload)
    }

    @Test
    func legacyClientOpusPacketEncoderRejectsInvalidTarget() {
        let packet = MumbleUDPVoicePacketEncoder.encodeLegacyClientOpusPacket(
            frameNumber: 1,
            payload: Data([0x01]),
            isTerminator: false,
            targetOrContext: 32
        )

        #expect(packet == nil)
    }

    private func decodeLegacyVarint<C: RandomAccessCollection>(
        from payload: C,
        index: inout C.Index
    ) -> UInt64? where C.Element == UInt8 {
        guard index < payload.endIndex else {
            return nil
        }

        let value = UInt64(payload[index])
        index = payload.index(after: index)

        if (value & 0x80) == 0x00 {
            return value & 0x7F
        } else if (value & 0xC0) == 0x80 {
            guard let byte1 = nextByte(from: payload, index: &index) else {
                return nil
            }
            return ((value & 0x3F) << 8) | UInt64(byte1)
        } else if (value & 0xE0) == 0xC0 {
            guard let bytes = nextBytes(count: 2, from: payload, index: &index) else {
                return nil
            }
            return ((value & 0x1F) << 16)
                | (UInt64(bytes[0]) << 8)
                | UInt64(bytes[1])
        } else if (value & 0xF0) == 0xE0 {
            guard let bytes = nextBytes(count: 3, from: payload, index: &index) else {
                return nil
            }
            return ((value & 0x0F) << 24)
                | (UInt64(bytes[0]) << 16)
                | (UInt64(bytes[1]) << 8)
                | UInt64(bytes[2])
        } else if value == 0xF0 {
            guard let bytes = nextBytes(count: 4, from: payload, index: &index) else {
                return nil
            }
            return bytes.reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
        } else if value == 0xF4 {
            guard let bytes = nextBytes(count: 8, from: payload, index: &index) else {
                return nil
            }
            return bytes.reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
        }

        return nil
    }

    private func nextByte<C: RandomAccessCollection>(
        from payload: C,
        index: inout C.Index
    ) -> UInt8? where C.Element == UInt8 {
        guard index < payload.endIndex else {
            return nil
        }

        let byte = payload[index]
        index = payload.index(after: index)
        return byte
    }

    private func nextBytes<C: RandomAccessCollection>(
        count: Int,
        from payload: C,
        index: inout C.Index
    ) -> [UInt8]? where C.Element == UInt8 {
        guard payload.distance(from: index, to: payload.endIndex) >= count else {
            return nil
        }

        let endIndex = payload.index(index, offsetBy: count)
        let bytes = Array(payload[index..<endIndex])
        index = endIndex
        return bytes
    }
}
