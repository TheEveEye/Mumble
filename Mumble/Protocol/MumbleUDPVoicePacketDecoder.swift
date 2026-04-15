import Foundation

struct MumbleVoicePacket: Equatable, Sendable {
    let senderSession: UInt32
    let frameNumber: UInt64
    let payload: Data
    let isTerminator: Bool
    let targetOrContext: UInt32
    let volumeAdjustment: Float
}

enum MumbleUDPMessage: Equatable, Sendable {
    case ping(MumblePingResponse)
    case audio(MumbleVoicePacket)
}

enum MumbleUDPVoicePacketDecoder {
    private static let protobufAudioHeader: UInt8 = 0x00
    private static let protobufPingHeader: UInt8 = 0x01
    private static let legacyMessageTypeMask: UInt8 = 0xE0
    private static let legacyTargetMask: UInt8 = 0x1F
    private static let legacyOpusMessageType: UInt8 = 0x80

    static func decode(_ packet: Data) -> MumbleUDPMessage? {
        guard let header = packet.first else {
            return nil
        }

        switch header {
        case protobufAudioHeader:
            return decodeProtobufAudio(packet.dropFirst()).map(MumbleUDPMessage.audio)
        case protobufPingHeader:
            return MumbleProtobufPingPacket.parseResponse(packet).map(MumbleUDPMessage.ping)
        default:
            return decodeLegacyAudio(packet).map(MumbleUDPMessage.audio)
        }
    }

    private static func decodeLegacyAudio(_ packet: Data) -> MumbleVoicePacket? {
        guard
            let header = packet.first,
            (header & legacyMessageTypeMask) == legacyOpusMessageType
        else {
            return nil
        }

        let targetOrContext = UInt32(header & legacyTargetMask)
        let payload = packet.dropFirst()
        var index = payload.startIndex

        guard
            let senderSessionVarint = decodeLegacyVarint(from: payload, index: &index),
            let senderSession = UInt32(exactly: senderSessionVarint),
            let frameNumber = decodeLegacyVarint(from: payload, index: &index),
            let opusHeader = decodeLegacyVarint(from: payload, index: &index)
        else {
            return nil
        }

        let opusPayloadSize = Int(opusHeader & 0x1FFF)
        let isTerminator = (opusHeader & 0x2000) != 0

        guard payload.distance(from: index, to: payload.endIndex) >= opusPayloadSize else {
            return nil
        }

        let payloadEnd = payload.index(index, offsetBy: opusPayloadSize)
        let opusPayload = Data(payload[index..<payloadEnd])
        index = payloadEnd

        let trailingByteCount = payload.distance(from: index, to: payload.endIndex)
        guard trailingByteCount == 0 || trailingByteCount == 12 else {
            return nil
        }

        guard !opusPayload.isEmpty else {
            return nil
        }

        return MumbleVoicePacket(
            senderSession: senderSession,
            frameNumber: frameNumber,
            payload: opusPayload,
            isTerminator: isTerminator,
            targetOrContext: targetOrContext,
            volumeAdjustment: 1.0
        )
    }

    private static func decodeProtobufAudio(_ payload: Data.SubSequence) -> MumbleVoicePacket? {
        var index = payload.startIndex

        var targetOrContext: UInt32 = 0
        var senderSession: UInt32?
        var frameNumber: UInt64?
        var opusPayload: Data?
        var positionalComponents: [Float] = []
        var volumeAdjustment: Float = 1.0
        var isTerminator = false

        while index < payload.endIndex {
            guard let rawKey = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                return nil
            }

            let fieldNumber = rawKey >> 3
            let wireType = rawKey & 0x07

            switch (fieldNumber, wireType) {
            case (2, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }
                targetOrContext = UInt32(exactly: value) ?? 0
            case (3, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }
                senderSession = UInt32(exactly: value)
            case (4, 0):
                frameNumber = MumbleProtobufWire.decodeVarint(from: payload, index: &index)
            case (5, 2):
                guard let value = MumbleProtobufWire.decodeLengthDelimited(from: payload, index: &index) else {
                    return nil
                }
                opusPayload = Data(value)
            case (6, 5):
                guard let value = decodeFixed32(from: payload, index: &index) else {
                    return nil
                }
                positionalComponents.append(Float(bitPattern: value))
            case (7, 5):
                guard let value = decodeFixed32(from: payload, index: &index) else {
                    return nil
                }
                volumeAdjustment = Float(bitPattern: value)
            case (16, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }
                isTerminator = value != 0
            default:
                guard MumbleProtobufWire.skipField(wireType: wireType, payload: payload, index: &index) else {
                    return nil
                }
            }
        }

        guard
            let senderSession,
            let frameNumber,
            let opusPayload,
            !opusPayload.isEmpty
        else {
            return nil
        }

        if !positionalComponents.isEmpty, positionalComponents.count != 3 {
            return nil
        }

        return MumbleVoicePacket(
            senderSession: senderSession,
            frameNumber: frameNumber,
            payload: opusPayload,
            isTerminator: isTerminator,
            targetOrContext: targetOrContext,
            volumeAdjustment: volumeAdjustment == 0 ? 1.0 : volumeAdjustment
        )
    }

    private static func decodeFixed32<C: RandomAccessCollection>(
        from payload: C,
        index: inout C.Index
    ) -> UInt32? where C.Element == UInt8 {
        guard payload.distance(from: index, to: payload.endIndex) >= 4 else {
            return nil
        }

        let start = index
        let end = payload.index(start, offsetBy: 4)
        index = end

        let bytes = Array(payload[start..<end])
        return bytes.enumerated().reduce(UInt32.zero) { partialResult, item in
            partialResult | (UInt32(item.element) << (item.offset * 8))
        }
    }

    private static func decodeLegacyVarint<C: RandomAccessCollection>(
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
        } else if (value & 0xF0) == 0xF0 {
            switch value & 0xFC {
            case 0xF0:
                guard let bytes = nextBytes(count: 4, from: payload, index: &index) else {
                    return nil
                }
                return bytes.reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
            case 0xF4:
                guard let bytes = nextBytes(count: 8, from: payload, index: &index) else {
                    return nil
                }
                return bytes.reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
            case 0xF8:
                guard let nested = decodeLegacyVarint(from: payload, index: &index) else {
                    return nil
                }
                return ~nested
            case 0xFC:
                return ~(value & 0x03)
            default:
                return nil
            }
        } else if (value & 0xF0) == 0xE0 {
            guard let bytes = nextBytes(count: 3, from: payload, index: &index) else {
                return nil
            }
            return ((value & 0x0F) << 24)
                | (UInt64(bytes[0]) << 16)
                | (UInt64(bytes[1]) << 8)
                | UInt64(bytes[2])
        } else if (value & 0xE0) == 0xC0 {
            guard let bytes = nextBytes(count: 2, from: payload, index: &index) else {
                return nil
            }
            return ((value & 0x1F) << 16)
                | (UInt64(bytes[0]) << 8)
                | UInt64(bytes[1])
        }

        return nil
    }

    private static func nextByte<C: RandomAccessCollection>(
        from payload: C,
        index: inout C.Index
    ) -> UInt8? where C.Element == UInt8 {
        guard index < payload.endIndex else {
            return nil
        }

        let value = payload[index]
        index = payload.index(after: index)
        return value
    }

    private static func nextBytes<C: RandomAccessCollection>(
        count: Int,
        from payload: C,
        index: inout C.Index
    ) -> [UInt8]? where C.Element == UInt8 {
        guard payload.distance(from: index, to: payload.endIndex) >= count else {
            return nil
        }

        let start = index
        let end = payload.index(start, offsetBy: count)
        index = end
        return Array(payload[start..<end])
    }
}
