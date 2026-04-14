import Foundation
import Network

struct MumbleServerPingTarget: Hashable, Sendable {
    let id: UUID
    let host: String
    let port: Int
}

struct MumbleServerStatus: Equatable, Sendable {
    let pingMilliseconds: Int
    let userCount: Int?
    let maximumUserCount: Int?
}

struct MumblePingResponse: Equatable, Sendable {
    let timestamp: UInt64
    let userCount: Int?
    let maximumUserCount: Int?
    let maximumBandwidthPerUser: Int?
}

enum MumbleLegacyPingPacket {
    static func makeExtendedPingRequest(timestamp: UInt64) -> Data {
        var packet = Data(repeating: 0, count: 12)
        packet.replaceSubrange(4..<12, with: bytes(of: timestamp.bigEndian))
        return packet
    }

    static func parseResponse(_ data: Data) -> MumblePingResponse? {
        switch data.count {
        case 12:
            return MumblePingResponse(
                timestamp: readUInt64(from: data, offset: 4),
                userCount: nil,
                maximumUserCount: nil,
                maximumBandwidthPerUser: nil
            )
        case 24:
            return MumblePingResponse(
                timestamp: readUInt64(from: data, offset: 4),
                userCount: Int(readUInt32(from: data, offset: 12)),
                maximumUserCount: Int(readUInt32(from: data, offset: 16)),
                maximumBandwidthPerUser: Int(readUInt32(from: data, offset: 20))
            )
        default:
            return nil
        }
    }

    private static func bytes<T>(of value: T) -> [UInt8] {
        withUnsafeBytes(of: value) { Array($0) }
    }

    private static func readUInt32(from data: Data, offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32.zero) { partialResult, byte in
            (partialResult << 8) | UInt32(byte)
        }
    }

    private static func readUInt64(from data: Data, offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(UInt64.zero) { partialResult, byte in
            (partialResult << 8) | UInt64(byte)
        }
    }
}

enum MumbleProtobufPingPacket {
    private static let pingHeader: UInt8 = 0x01
    private static let timestampFieldKey: UInt8 = 0x08
    private static let extendedInformationRequestFieldKey: UInt8 = 0x10
    private static let serverVersionFieldKey: UInt8 = 0x18
    private static let userCountFieldKey: UInt8 = 0x20
    private static let maximumUserCountFieldKey: UInt8 = 0x28
    private static let maximumBandwidthPerUserFieldKey: UInt8 = 0x30

    static func makeExtendedPingRequest(timestamp: UInt64) -> Data {
        var packet = Data([pingHeader, timestampFieldKey])
        packet.append(contentsOf: encodeVarint(timestamp))
        packet.append(extendedInformationRequestFieldKey)
        packet.append(0x01)
        return packet
    }

    static func parseResponse(_ data: Data) -> MumblePingResponse? {
        guard data.first == pingHeader else {
            return nil
        }

        let payload = data.dropFirst()
        var index = payload.startIndex

        var timestamp: UInt64?
        var serverVersion: UInt64?
        var userCount: UInt32?
        var maximumUserCount: UInt32?
        var maximumBandwidthPerUser: UInt32?

        while index < payload.endIndex {
            guard let rawKey = decodeVarint(from: payload, index: &index) else {
                return nil
            }

            let fieldNumber = rawKey >> 3
            let wireType = rawKey & 0x07

            switch (fieldNumber, wireType) {
            case (1, 0):
                timestamp = decodeVarint(from: payload, index: &index)
            case (2, 0):
                _ = decodeVarint(from: payload, index: &index)
            case (3, 0):
                serverVersion = decodeVarint(from: payload, index: &index)
            case (4, 0):
                guard let value = decodeVarint(from: payload, index: &index) else {
                    return nil
                }
                userCount = UInt32(exactly: value)
            case (5, 0):
                guard let value = decodeVarint(from: payload, index: &index) else {
                    return nil
                }
                maximumUserCount = UInt32(exactly: value)
            case (6, 0):
                guard let value = decodeVarint(from: payload, index: &index) else {
                    return nil
                }
                maximumBandwidthPerUser = UInt32(exactly: value)
            default:
                guard skipField(wireType: wireType, payload: payload, index: &index) else {
                    return nil
                }
            }
        }

        guard let timestamp else {
            return nil
        }

        let containsExtendedInformation = (serverVersion ?? 0) != 0

        return MumblePingResponse(
            timestamp: timestamp,
            userCount: containsExtendedInformation ? userCount.map(Int.init) : nil,
            maximumUserCount: containsExtendedInformation ? maximumUserCount.map(Int.init) : nil,
            maximumBandwidthPerUser: containsExtendedInformation ? maximumBandwidthPerUser.map(Int.init) : nil
        )
    }

    private static func encodeVarint(_ value: UInt64) -> [UInt8] {
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

        return bytes
    }

    private static func decodeVarint<C: RandomAccessCollection>(
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

    private static func skipField<C: RandomAccessCollection>(
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

enum MumblePingPacket {
    static func parseResponse(_ data: Data) -> MumblePingResponse? {
        MumbleLegacyPingPacket.parseResponse(data) ?? MumbleProtobufPingPacket.parseResponse(data)
    }
}

struct MumbleServerStatusService: Sendable {
    private let logger: AppLogger

    init(logger: AppLogger) {
        self.logger = logger
    }

    func fetchStatuses(for targets: [MumbleServerPingTarget]) async -> [UUID: MumbleServerStatus?] {
        await withTaskGroup(of: (UUID, MumbleServerStatus?).self, returning: [UUID: MumbleServerStatus?].self) { group in
            for target in targets {
                group.addTask {
                    let status = await fetchStatus(host: target.host, port: target.port)
                    return (target.id, status)
                }
            }

            var statuses: [UUID: MumbleServerStatus?] = [:]

            for await (id, status) in group {
                statuses[id] = status
            }

            return statuses
        }
    }

    func fetchStatus(host: String, port: Int, timeout: TimeInterval = 3.0) async -> MumbleServerStatus? {
        let timestamp = DispatchTime.now().uptimeNanoseconds
        let requestPackets = [
            MumbleLegacyPingPacket.makeExtendedPingRequest(timestamp: timestamp),
            MumbleProtobufPingPacket.makeExtendedPingRequest(timestamp: timestamp),
        ]
        let sendStartedAt = DispatchTime.now().uptimeNanoseconds

        do {
            let response = try await exchangePackets(
                host: host,
                port: port,
                requestPackets: requestPackets,
                timeout: timeout
            )

            guard response.timestamp == timestamp else {
                logger.debug("Ignoring mismatched ping response from \(host):\(port)")
                return nil
            }

            let pingMilliseconds = max(0, Int((DispatchTime.now().uptimeNanoseconds - sendStartedAt) / 1_000_000))

            return MumbleServerStatus(
                pingMilliseconds: pingMilliseconds,
                userCount: response.userCount,
                maximumUserCount: response.maximumUserCount
            )
        } catch {
            logger.debug("Server status ping failed for \(host):\(port): \(error.localizedDescription)")
            return nil
        }
    }

    private func exchangePackets(
        host: String,
        port: Int,
        requestPackets: [Data],
        timeout: TimeInterval
    ) async throws -> MumblePingResponse {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw PingError.invalidPort
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        let queue = DispatchQueue(label: "dev.kiwiapps.Mumble.protocol.server-status.\(UUID().uuidString)")

        return try await withCheckedThrowingContinuation { continuation in
            let state = PingContinuationState()

            @Sendable func resume(_ result: Result<MumblePingResponse, Error>) {
                guard state.beginResuming() else {
                    return
                }

                connection.cancel()
                continuation.resume(with: result)
            }

            connection.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    resume(.failure(error))
                }
            }

            @Sendable func receiveNextResponse() {
                connection.receiveMessage { data, _, _, error in
                    if let error {
                        resume(.failure(error))
                        return
                    }

                    guard let data, !data.isEmpty else {
                        receiveNextResponse()
                        return
                    }

                    guard let response = MumblePingPacket.parseResponse(data) else {
                        receiveNextResponse()
                        return
                    }

                    if response.userCount == nil {
                        state.storeProvisionalResponse(response)
                        receiveNextResponse()
                        return
                    }

                    resume(.success(response))
                }
            }

            connection.start(queue: queue)
            sendPackets(
                requestPackets,
                over: connection,
                at: 0,
                completion: { result in
                    switch result {
                    case .failure(let error):
                        resume(.failure(error))
                    case .success:
                        receiveNextResponse()
                    }
                }
            )

            queue.asyncAfter(deadline: .now() + timeout) {
                if let response = state.takeProvisionalResponse() {
                    resume(.success(response))
                } else {
                    resume(.failure(PingError.timeout))
                }
            }
        }
    }

    private func sendPackets(
        _ packets: [Data],
        over connection: NWConnection,
        at index: Int,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        guard index < packets.count else {
            completion(.success(()))
            return
        }

        connection.send(content: packets[index], completion: .contentProcessed { error in
            if let error {
                completion(.failure(error))
                return
            }

            sendPackets(packets, over: connection, at: index + 1, completion: completion)
        })
    }
}

private final class PingContinuationState: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var hasResumed = false
    nonisolated(unsafe) private var provisionalResponse: MumblePingResponse?

    nonisolated func beginResuming() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !hasResumed else {
            return false
        }

        hasResumed = true
        return true
    }

    nonisolated func storeProvisionalResponse(_ response: MumblePingResponse) {
        lock.lock()
        defer { lock.unlock() }

        guard provisionalResponse != nil else {
            provisionalResponse = response
            return
        }
    }

    nonisolated func takeProvisionalResponse() -> MumblePingResponse? {
        lock.lock()
        defer { lock.unlock() }
        return provisionalResponse
    }
}

private enum PingError: LocalizedError {
    case invalidPort
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "Invalid UDP port"
        case .timeout:
            return "Timed out waiting for UDP response"
        }
    }
}
