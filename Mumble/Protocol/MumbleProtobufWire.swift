import Foundation

enum MumbleProtobufWire {
    static func encodeVarint(_ value: UInt64) -> Data {
        var remaining = value
        var bytes: [UInt8] = []

        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7

            if remaining != 0 {
                byte |= 0x80
            }

            bytes.append(byte)
        } while remaining != 0

        return Data(bytes)
    }

    static func appendVarintField(_ fieldNumber: UInt64, value: UInt64, to payload: inout Data) {
        payload.append(encodeVarint((fieldNumber << 3) | 0))
        payload.append(encodeVarint(value))
    }

    static func appendBoolField(_ fieldNumber: UInt64, value: Bool, to payload: inout Data) {
        appendVarintField(fieldNumber, value: value ? 1 : 0, to: &payload)
    }

    static func appendStringField(_ fieldNumber: UInt64, value: String, to payload: inout Data) {
        guard let data = value.data(using: .utf8), !data.isEmpty else {
            return
        }

        appendBytesField(fieldNumber, value: data, to: &payload)
    }

    static func appendBytesField(_ fieldNumber: UInt64, value: Data, to payload: inout Data) {
        guard !value.isEmpty else {
            return
        }

        payload.append(encodeVarint((fieldNumber << 3) | 2))
        payload.append(encodeVarint(UInt64(value.count)))
        payload.append(value)
    }

    static func decodeVarint<C: RandomAccessCollection>(
        from payload: C,
        index: inout C.Index
    ) -> UInt64? where C.Element == UInt8 {
        var shift: UInt64 = 0
        var result: UInt64 = 0

        while index < payload.endIndex {
            let byte = payload[index]
            payload.formIndex(after: &index)

            result |= UInt64(byte & 0x7F) << shift

            if (byte & 0x80) == 0 {
                return result
            }

            shift += 7
            if shift >= 64 {
                return nil
            }
        }

        return nil
    }

    static func decodeLengthDelimited<C: RandomAccessCollection>(
        from payload: C,
        index: inout C.Index
    ) -> Data? where C.Element == UInt8 {
        guard let length = decodeVarint(from: payload, index: &index) else {
            return nil
        }

        guard let data = readBytes(from: payload, index: &index, count: Int(length)) else {
            return nil
        }

        return data
    }

    static func skipField<C: RandomAccessCollection>(
        wireType: UInt64,
        payload: C,
        index: inout C.Index
    ) -> Bool where C.Element == UInt8 {
        switch wireType {
        case 0:
            return decodeVarint(from: payload, index: &index) != nil
        case 1:
            return advance(index: &index, in: payload, by: 8)
        case 2:
            guard let length = decodeVarint(from: payload, index: &index) else {
                return false
            }

            return advance(index: &index, in: payload, by: Int(length))
        case 5:
            return advance(index: &index, in: payload, by: 4)
        default:
            return false
        }
    }

    static func decodeInt32(_ value: UInt64) -> Int {
        let bitPattern = UInt32(truncatingIfNeeded: value)
        return Int(Int32(bitPattern: bitPattern))
    }

    private static func readBytes<C: RandomAccessCollection>(
        from payload: C,
        index: inout C.Index,
        count: Int
    ) -> Data? where C.Element == UInt8 {
        guard count >= 0 else {
            return nil
        }

        let start = index

        for _ in 0..<count {
            guard index < payload.endIndex else {
                return nil
            }

            payload.formIndex(after: &index)
        }

        return Data(payload[start..<index])
    }

    private static func advance<C: RandomAccessCollection>(
        index: inout C.Index,
        in payload: C,
        by count: Int
    ) -> Bool where C.Element == UInt8 {
        guard count >= 0 else {
            return false
        }

        for _ in 0..<count {
            guard index < payload.endIndex else {
                return false
            }

            payload.formIndex(after: &index)
        }

        return true
    }
}
