import Foundation

enum MumbleUDPVoicePacketEncoder {
    private static let legacyOpusMessageType: UInt8 = 0x80

    static func encodeLegacyClientOpusPacket(
        frameNumber: UInt64,
        payload: Data,
        isTerminator: Bool,
        targetOrContext: UInt32
    ) -> Data? {
        guard !payload.isEmpty else {
            return nil
        }

        guard targetOrContext < 32 else {
            return nil
        }

        guard payload.count < (1 << 13) else {
            return nil
        }

        var packet = Data()
        packet.append(legacyOpusMessageType | UInt8(targetOrContext))
        packet.append(encodeLegacyVarint(frameNumber))
        let payloadHeader = UInt64(payload.count) | (isTerminator ? 0x2000 : 0)
        packet.append(encodeLegacyVarint(payloadHeader))
        packet.append(payload)
        return packet
    }

    private static func encodeLegacyVarint(_ value: UInt64) -> Data {
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
