import Foundation
import Network
import Security

struct MumbleConnectionTarget: Equatable, Sendable {
    let serverID: UUID
    let label: String
    let host: String
    let port: Int
    let username: String
    let password: String?

    var endpointDescription: String {
        port == 64738 ? host : "\(host):\(port)"
    }
}

struct MumbleChannel: Identifiable, Equatable, Sendable {
    let id: UInt32
    var name: String
    var parentID: UInt32?
    var position: Int
}

struct MumbleUser: Identifiable, Equatable, Hashable, Sendable {
    let id: UInt32
    var name: String
    var channelID: UInt32?
    var registeredUserID: UInt32?
    var isServerMuted: Bool
    var isServerDeafened: Bool
    var isSuppressed: Bool
    var isSelfMuted: Bool
    var isSelfDeafened: Bool

    var isAuthenticated: Bool {
        guard let registeredUserID else {
            return false
        }

        return registeredUserID > 0
    }
}

enum MumbleChannelListEvent: Sendable {
    case log(String)
    case synchronized(welcomeText: String?, currentSessionID: UInt32?)
    case channelsUpdated([MumbleChannel])
    case usersUpdated([MumbleUser])
    case failed(String, MumbleRejectType?)
    case disconnected(String?)
}

enum MumbleRejectType: UInt64, Sendable {
    case none = 0
    case wrongVersion = 1
    case invalidUsername = 2
    case wrongUserPassword = 3
    case wrongServerPassword = 4
    case usernameInUse = 5
    case serverFull = 6
    case noCertificate = 7
    case authenticatorFail = 8
}

final class MumbleChannelListConnectionHandle {
    private let cancellation: () -> Void

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation()
    }
}

struct MumbleChannelListService: Sendable {
    private let logger: AppLogger

    init(logger: AppLogger) {
        self.logger = logger
    }

    func connect(
        to target: MumbleConnectionTarget,
        onEvent: @escaping @Sendable (MumbleChannelListEvent) -> Void
    ) -> MumbleChannelListConnectionHandle {
        let client = MumbleChannelListClient(
            target: target,
            logger: logger,
            onEvent: onEvent
        )
        client.start()

        return MumbleChannelListConnectionHandle {
            client.cancel(isUserInitiated: true)
        }
    }
}

struct MumbleRejectMessage {
    let type: MumbleRejectType?
    let reason: String
}

struct MumbleServerSyncMessage {
    let currentSessionID: UInt32?
    let welcomeText: String?
}

struct MumbleChannelStateMessage {
    let channelID: UInt32
    let hasParent: Bool
    let parentID: UInt32?
    let name: String?
    let position: Int?
}

struct MumbleUserStateMessage {
    let sessionID: UInt32
    let name: String?
    let registeredUserID: UInt32?
    let channelID: UInt32?
    let isServerMuted: Bool?
    let isServerDeafened: Bool?
    let isSuppressed: Bool?
    let isSelfMuted: Bool?
    let isSelfDeafened: Bool?
}

private enum MumbleSessionPayloads {
    private static let currentMajor: UInt64 = UInt64(MumbleProtocolVersion.currentMajor)
    private static let currentMinor: UInt64 = UInt64(MumbleProtocolVersion.currentMinor)
    private static let currentPatch: UInt64 = 0

    static func versionPacket() -> Data {
        let versionV1 = (currentMajor << 16) | (currentMinor << 8) | currentPatch
        let versionV2 = (currentMajor << 48) | (currentMinor << 32) | (currentPatch << 16)

        var payload = Data()
        MumbleProtobufWire.appendVarintField(1, value: versionV1, to: &payload)
        MumbleProtobufWire.appendStringField(2, value: "Mumble", to: &payload)
        MumbleProtobufWire.appendStringField(3, value: "macOS", to: &payload)
        MumbleProtobufWire.appendStringField(
            4,
            value: ProcessInfo.processInfo.operatingSystemVersionString,
            to: &payload
        )
        MumbleProtobufWire.appendVarintField(5, value: versionV2, to: &payload)
        return payload
    }

    static func authenticatePacket(username: String, password: String?) -> Data {
        var payload = Data()
        MumbleProtobufWire.appendStringField(1, value: username, to: &payload)
        MumbleProtobufWire.appendStringField(2, value: password ?? "", to: &payload)
        MumbleProtobufWire.appendBoolField(5, value: true, to: &payload)
        return payload
    }

    static func pingPacket(timestamp: UInt64) -> Data {
        var payload = Data()
        MumbleProtobufWire.appendVarintField(1, value: timestamp, to: &payload)
        return payload
    }
}

enum MumbleSessionMessageDecoder {
    static func decodeReject(from data: Data) -> MumbleRejectMessage? {
        let payload = data[...]
        var index = payload.startIndex
        var type: MumbleRejectType?
        var reason = "Server rejected the connection."

        while index < payload.endIndex {
            guard let key = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                return nil
            }

            let fieldNumber = key >> 3
            let wireType = key & 0x07

            switch (fieldNumber, wireType) {
            case (1, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                type = MumbleRejectType(rawValue: value)
            case (2, 2):
                guard let value = MumbleProtobufWire.decodeLengthDelimited(from: payload, index: &index) else {
                    return nil
                }

                reason = String(decoding: value, as: UTF8.self)
            default:
                guard MumbleProtobufWire.skipField(wireType: wireType, payload: payload, index: &index) else {
                    return nil
                }
            }
        }

        return MumbleRejectMessage(type: type, reason: reason)
    }

    static func decodeServerSync(from data: Data) -> MumbleServerSyncMessage? {
        let payload = data[...]
        var index = payload.startIndex
        var currentSessionID: UInt32?
        var welcomeText: String?

        while index < payload.endIndex {
            guard let key = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                return nil
            }

            let fieldNumber = key >> 3
            let wireType = key & 0x07

            switch (fieldNumber, wireType) {
            case (1, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                currentSessionID = UInt32(exactly: value)
            case (3, 2):
                guard let value = MumbleProtobufWire.decodeLengthDelimited(from: payload, index: &index) else {
                    return nil
                }

                welcomeText = String(decoding: value, as: UTF8.self)
            default:
                guard MumbleProtobufWire.skipField(wireType: wireType, payload: payload, index: &index) else {
                    return nil
                }
            }
        }

        return MumbleServerSyncMessage(currentSessionID: currentSessionID, welcomeText: welcomeText)
    }

    static func decodeChannelRemove(from data: Data) -> UInt32? {
        let payload = data[...]
        var index = payload.startIndex

        while index < payload.endIndex {
            guard let key = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                return nil
            }

            let fieldNumber = key >> 3
            let wireType = key & 0x07

            switch (fieldNumber, wireType) {
            case (1, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                return UInt32(exactly: value)
            default:
                guard MumbleProtobufWire.skipField(wireType: wireType, payload: payload, index: &index) else {
                    return nil
                }
            }
        }

        return nil
    }

    static func decodeChannelState(from data: Data) -> MumbleChannelStateMessage? {
        let payload = data[...]
        var index = payload.startIndex

        var channelID: UInt32?
        var parentID: UInt32?
        var hasParent = false
        var name: String?
        var position: Int?

        while index < payload.endIndex {
            guard let key = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                return nil
            }

            let fieldNumber = key >> 3
            let wireType = key & 0x07

            switch (fieldNumber, wireType) {
            case (1, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                channelID = UInt32(exactly: value)
            case (2, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                hasParent = true
                parentID = UInt32(exactly: value)
            case (3, 2):
                guard let value = MumbleProtobufWire.decodeLengthDelimited(from: payload, index: &index) else {
                    return nil
                }

                name = String(decoding: value, as: UTF8.self)
            case (9, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                position = MumbleProtobufWire.decodeInt32(value)
            default:
                guard MumbleProtobufWire.skipField(wireType: wireType, payload: payload, index: &index) else {
                    return nil
                }
            }
        }

        guard let channelID else {
            return nil
        }

        return MumbleChannelStateMessage(
            channelID: channelID,
            hasParent: hasParent,
            parentID: parentID,
            name: name,
            position: position
        )
    }

    static func decodeUserRemove(from data: Data) -> UInt32? {
        let payload = data[...]
        var index = payload.startIndex

        while index < payload.endIndex {
            guard let key = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                return nil
            }

            let fieldNumber = key >> 3
            let wireType = key & 0x07

            switch (fieldNumber, wireType) {
            case (1, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                return UInt32(exactly: value)
            default:
                guard MumbleProtobufWire.skipField(wireType: wireType, payload: payload, index: &index) else {
                    return nil
                }
            }
        }

        return nil
    }

    static func decodeUserState(from data: Data) -> MumbleUserStateMessage? {
        let payload = data[...]
        var index = payload.startIndex

        var sessionID: UInt32?
        var name: String?
        var registeredUserID: UInt32?
        var channelID: UInt32?
        var isServerMuted: Bool?
        var isServerDeafened: Bool?
        var isSuppressed: Bool?
        var isSelfMuted: Bool?
        var isSelfDeafened: Bool?

        while index < payload.endIndex {
            guard let key = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                return nil
            }

            let fieldNumber = key >> 3
            let wireType = key & 0x07

            switch (fieldNumber, wireType) {
            case (1, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                sessionID = UInt32(exactly: value)
            case (3, 2):
                guard let value = MumbleProtobufWire.decodeLengthDelimited(from: payload, index: &index) else {
                    return nil
                }

                name = String(decoding: value, as: UTF8.self)
            case (4, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                registeredUserID = UInt32(exactly: value)
            case (5, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                channelID = UInt32(exactly: value)
            case (6, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                isServerMuted = value != 0
            case (7, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                isServerDeafened = value != 0
            case (8, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                isSuppressed = value != 0
            case (9, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                isSelfMuted = value != 0
            case (10, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                isSelfDeafened = value != 0
            default:
                guard MumbleProtobufWire.skipField(wireType: wireType, payload: payload, index: &index) else {
                    return nil
                }
            }
        }

        guard let sessionID else {
            return nil
        }

        return MumbleUserStateMessage(
            sessionID: sessionID,
            name: name,
            registeredUserID: registeredUserID,
            channelID: channelID,
            isServerMuted: isServerMuted,
            isServerDeafened: isServerDeafened,
            isSuppressed: isSuppressed,
            isSelfMuted: isSelfMuted,
            isSelfDeafened: isSelfDeafened
        )
    }
}

private final class MumbleChannelListClient {
    private let target: MumbleConnectionTarget
    private let logger: AppLogger
    private let onEvent: @Sendable (MumbleChannelListEvent) -> Void
    private let connection: NWConnection
    private let queue: DispatchQueue

    private var receiveBuffer = Data()
    private var channels: [UInt32: MumbleChannel] = [:]
    private var users: [UInt32: MumbleUser] = [:]
    private var pingTimer: DispatchSourceTimer?
    private var isUserInitiatedCancellation = false
    private var hasFinished = false

    init(
        target: MumbleConnectionTarget,
        logger: AppLogger,
        onEvent: @escaping @Sendable (MumbleChannelListEvent) -> Void
    ) {
        self.target = target
        self.logger = logger
        self.onEvent = onEvent
        queue = DispatchQueue(label: "dev.kiwiapps.Mumble.protocol.channel-list.\(UUID().uuidString)")

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()

                if SecTrustEvaluateWithError(secTrust, nil) {
                    complete(true)
                    return
                }

                complete(true)
            },
            queue
        )

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true

        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true

        connection = NWConnection(
            host: NWEndpoint.Host(target.host),
            port: NWEndpoint.Port(rawValue: UInt16(target.port)) ?? 64738,
            using: parameters
        )
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleState(state)
        }

        connection.start(queue: queue)
    }

    func cancel(isUserInitiated: Bool) {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            if isUserInitiated {
                isUserInitiatedCancellation = true
            }

            stopPingLoop()
            connection.cancel()
        }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            logger.info("TCP session ready for \(target.endpointDescription)")
            emit(.log("Secure connection established to \(target.endpointDescription)."))
            sendInitialHandshake()
            startPingLoop()
            receiveNextChunk()
        case .failed(let error):
            finish(with: .failed("Failed to connect to \(target.endpointDescription): \(error.localizedDescription)", nil))
        case .cancelled:
            stopPingLoop()

            guard !hasFinished else {
                return
            }

            hasFinished = true

            if !isUserInitiatedCancellation {
                emit(.disconnected("Disconnected from \(target.label)."))
            }
        default:
            break
        }
    }

    private func sendInitialHandshake() {
        let username = target.username.isEmpty ? "Mumble User" : target.username
        sendMessage(type: .version, payload: MumbleSessionPayloads.versionPacket())
        sendMessage(
            type: .authenticate,
            payload: MumbleSessionPayloads.authenticatePacket(
                username: username,
                password: target.password
            )
        )
        logger.info("Sent authenticate request for \(username) to \(target.endpointDescription)")
    }

    private func startPingLoop() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(15), repeating: .seconds(15))
        timer.setEventHandler { [weak self] in
            self?.sendPing()
        }
        timer.resume()
        pingTimer = timer
    }

    private func stopPingLoop() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func sendPing() {
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000)
        sendMessage(type: .ping, payload: MumbleSessionPayloads.pingPacket(timestamp: timestamp))
    }

    private func sendMessage(type: MumbleTCPMessageType, payload: Data) {
        var packet = Data(count: 6)
        packet[0] = UInt8((type.rawValue >> 8) & 0xFF)
        packet[1] = UInt8(type.rawValue & 0xFF)

        let payloadLength = UInt32(payload.count)
        packet[2] = UInt8((payloadLength >> 24) & 0xFF)
        packet[3] = UInt8((payloadLength >> 16) & 0xFF)
        packet[4] = UInt8((payloadLength >> 8) & 0xFF)
        packet[5] = UInt8(payloadLength & 0xFF)
        packet.append(payload)

        connection.send(content: packet, completion: .contentProcessed { [logger, target] error in
            if let error {
                logger.error("Failed to send TCP message to \(target.endpointDescription): \(error.localizedDescription)")
            }
        })
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let data, !data.isEmpty {
                receiveBuffer.append(data)
                processBufferedMessages()
            }

            if let error {
                finish(with: .failed("Connection to \(target.endpointDescription) failed: \(error.localizedDescription)", nil))
                return
            }

            if isComplete {
                finish(with: .disconnected("Disconnected from \(target.label)."))
                return
            }

            receiveNextChunk()
        }
    }

    private func processBufferedMessages() {
        while receiveBuffer.count >= 6 {
            let typeRawValue = UInt16(receiveBuffer[0]) << 8 | UInt16(receiveBuffer[1])
            let payloadLength =
                UInt32(receiveBuffer[2]) << 24 |
                UInt32(receiveBuffer[3]) << 16 |
                UInt32(receiveBuffer[4]) << 8 |
                UInt32(receiveBuffer[5])

            let frameLength = Int(payloadLength) + 6
            guard receiveBuffer.count >= frameLength else {
                return
            }

            let payload = receiveBuffer.subdata(in: 6..<frameLength)
            receiveBuffer.removeSubrange(0..<frameLength)

            guard let type = MumbleTCPMessageType(rawValue: typeRawValue) else {
                continue
            }

            handleMessage(type: type, payload: payload)
        }
    }

    private func handleMessage(type: MumbleTCPMessageType, payload: Data) {
        switch type {
        case .reject:
            let rejectMessage = MumbleSessionMessageDecoder.decodeReject(from: payload)
            let reason = rejectMessage?.reason ?? "Server rejected the connection."
            finish(with: .failed(reason, rejectMessage?.type))
        case .serverSync:
            guard let serverSync = MumbleSessionMessageDecoder.decodeServerSync(from: payload) else {
                return
            }

            emit(.synchronized(welcomeText: serverSync.welcomeText, currentSessionID: serverSync.currentSessionID))
        case .channelState:
            guard let channelState = MumbleSessionMessageDecoder.decodeChannelState(from: payload) else {
                return
            }

            applyChannelState(channelState)
        case .channelRemove:
            guard let channelID = MumbleSessionMessageDecoder.decodeChannelRemove(from: payload) else {
                return
            }

            removeChannelTree(withID: channelID)
            emitChannelSnapshot()
        case .userState:
            guard let userState = MumbleSessionMessageDecoder.decodeUserState(from: payload) else {
                return
            }

            applyUserState(userState)
        case .userRemove:
            guard let sessionID = MumbleSessionMessageDecoder.decodeUserRemove(from: payload) else {
                return
            }

            users.removeValue(forKey: sessionID)
            emitUserSnapshot()
        default:
            break
        }
    }

    private func applyChannelState(_ message: MumbleChannelStateMessage) {
        var channel = channels[message.channelID] ?? MumbleChannel(
            id: message.channelID,
            name: "Channel \(message.channelID)",
            parentID: nil,
            position: 0
        )

        if message.hasParent {
            channel.parentID = message.parentID
        }

        if let name = message.name, !name.isEmpty {
            channel.name = name
        }

        if let position = message.position {
            channel.position = position
        }

        channels[message.channelID] = channel
        emitChannelSnapshot()
    }

    private func applyUserState(_ message: MumbleUserStateMessage) {
        var user = users[message.sessionID] ?? MumbleUser(
            id: message.sessionID,
            name: "User \(message.sessionID)",
            channelID: nil,
            registeredUserID: nil,
            isServerMuted: false,
            isServerDeafened: false,
            isSuppressed: false,
            isSelfMuted: false,
            isSelfDeafened: false
        )

        if let name = message.name, !name.isEmpty {
            user.name = name
        }

        if let registeredUserID = message.registeredUserID {
            user.registeredUserID = registeredUserID
        }

        if let channelID = message.channelID {
            user.channelID = channelID
        }

        if let isServerMuted = message.isServerMuted {
            user.isServerMuted = isServerMuted
        }

        if let isServerDeafened = message.isServerDeafened {
            user.isServerDeafened = isServerDeafened
        }

        if let isSuppressed = message.isSuppressed {
            user.isSuppressed = isSuppressed
        }

        if let isSelfMuted = message.isSelfMuted {
            user.isSelfMuted = isSelfMuted
        }

        if let isSelfDeafened = message.isSelfDeafened {
            user.isSelfDeafened = isSelfDeafened
        }

        users[message.sessionID] = user
        emitUserSnapshot()
    }

    private func removeChannelTree(withID channelID: UInt32) {
        channels.removeValue(forKey: channelID)

        let childIDs = channels.values
            .filter { $0.parentID == channelID }
            .map(\.id)

        for childID in childIDs {
            removeChannelTree(withID: childID)
        }
    }

    private func emitChannelSnapshot() {
        let snapshot = channels.values.sorted {
            if $0.position == $1.position {
                let comparison = $0.name.localizedStandardCompare($1.name)

                if comparison == .orderedSame {
                    return $0.id < $1.id
                }

                return comparison == .orderedAscending
            }

            return $0.position < $1.position
        }

        emit(.channelsUpdated(snapshot))
    }

    private func emitUserSnapshot() {
        let snapshot = users.values.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)

            if comparison == .orderedSame {
                return $0.id < $1.id
            }

            return comparison == .orderedAscending
        }

        emit(.usersUpdated(snapshot))
    }

    private func finish(with event: MumbleChannelListEvent) {
        guard !hasFinished else {
            return
        }

        hasFinished = true
        stopPingLoop()
        emit(event)
        connection.cancel()
    }

    private func emit(_ event: MumbleChannelListEvent) {
        onEvent(event)
    }
}
