import Foundation
import Testing
@testable import Mumble

struct MumbleUDPVoicePacketDecoderTests {
    @Test
    func legacyOpusAudioPacketDecoderParsesServerVoicePacket() {
        let payload = Data([0xde, 0xad, 0xbe, 0xef])
        var packet = Data([0x80])
        packet.append(encodeLegacyVarint(42))
        packet.append(encodeLegacyVarint(9001))
        packet.append(encodeLegacyVarint(0x2000 | UInt64(payload.count)))
        packet.append(payload)

        let decoded = MumbleUDPVoicePacketDecoder.decode(packet)

        guard case .audio(let voicePacket)? = decoded else {
            Issue.record("Expected legacy audio packet")
            return
        }

        #expect(voicePacket.senderSession == 42)
        #expect(voicePacket.frameNumber == 9001)
        #expect(voicePacket.payload == payload)
        #expect(voicePacket.targetOrContext == 0)
        #expect(voicePacket.isTerminator == true)
        #expect(voicePacket.volumeAdjustment == 1.0)
    }

    @Test
    func protobufAudioPacketDecoderParsesSessionFrameAndPayload() {
        let payload = Data([0xde, 0xad, 0xbe, 0xef])
        var packet = Data([0x00])
        MumbleProtobufWire.appendVarintField(2, value: 3, to: &packet)
        MumbleProtobufWire.appendVarintField(3, value: 42, to: &packet)
        MumbleProtobufWire.appendVarintField(4, value: 9001, to: &packet)
        MumbleProtobufWire.appendBytesField(5, value: payload, to: &packet)
        packet.append(contentsOf: [0x3d, 0x00, 0x00, 0x40, 0x3f])
        MumbleProtobufWire.appendBoolField(16, value: true, to: &packet)

        let decoded = MumbleUDPVoicePacketDecoder.decode(packet)

        guard case .audio(let voicePacket)? = decoded else {
            Issue.record("Expected audio packet")
            return
        }

        #expect(voicePacket.senderSession == 42)
        #expect(voicePacket.frameNumber == 9001)
        #expect(voicePacket.payload == payload)
        #expect(voicePacket.targetOrContext == 3)
        #expect(voicePacket.isTerminator == true)
        #expect(abs(voicePacket.volumeAdjustment - 0.75) < 0.0001)
    }

    @Test
    func protobufPingPacketDecoderDelegatesToPingParser() {
        let packet = MumbleProtobufPingPacket.makeExtendedPingRequest(timestamp: 1234)

        let decoded = MumbleUDPVoicePacketDecoder.decode(packet)

        guard case .ping(let pingResponse)? = decoded else {
            Issue.record("Expected ping packet")
            return
        }

        #expect(pingResponse.timestamp == 1234)
    }

    private func encodeLegacyVarint(_ value: UInt64) -> Data {
        if value < 0x80 {
            return Data([UInt8(value)])
        } else if value < 0x4000 {
            return Data([
                UInt8((value >> 8) | 0x80),
                UInt8(value & 0xFF),
            ])
        } else if value < 0x20_0000 {
            return Data([
                UInt8((value >> 16) | 0xC0),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF),
            ])
        } else if value < 0x1000_0000 {
            return Data([
                UInt8((value >> 24) | 0xE0),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF),
            ])
        } else if value < 0x1_0000_0000 {
            return Data([
                0xF0,
                UInt8((value >> 24) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF),
            ])
        } else {
            return Data([
                0xF4,
                UInt8((value >> 56) & 0xFF),
                UInt8((value >> 48) & 0xFF),
                UInt8((value >> 40) & 0xFF),
                UInt8((value >> 32) & 0xFF),
                UInt8((value >> 24) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF),
            ])
        }
    }
}
