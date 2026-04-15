import Foundation
import Network
import Security
import CryptoKit

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

struct MumbleChannel: Identifiable, Equatable, Hashable, Sendable {
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
    case certificateTrustRequired(MumbleCertificateTrustChallenge)
    case reconnecting(reason: String, attempt: Int, maximumAttempts: Int, delay: TimeInterval)
    case synchronized(welcomeText: String?, currentSessionID: UInt32?)
    case channelsUpdated([MumbleChannel])
    case usersUpdated([MumbleUser])
    case failed(String, MumbleRejectType?)
    case disconnected(String?)
}

struct MumbleCertificateTrustChallenge: Identifiable, Equatable, Sendable {
    let id: UUID
    let serverID: UUID
    let serverLabel: String
    let host: String
    let port: Int
    let commonName: String
    let subjectSummary: String
    let fingerprintSHA256: String
    let failureDescription: String

    var endpointDescription: String {
        port == 64738 ? host : "\(host):\(port)"
    }

    var formattedFingerprint: String {
        stride(from: 0, to: fingerprintSHA256.count, by: 2)
            .map { startIndex in
                let start = fingerprintSHA256.index(fingerprintSHA256.startIndex, offsetBy: startIndex)
                let end = fingerprintSHA256.index(start, offsetBy: min(2, fingerprintSHA256.distance(from: start, to: fingerprintSHA256.endIndex)), limitedBy: fingerprintSHA256.endIndex) ?? fingerprintSHA256.endIndex
                return String(fingerprintSHA256[start..<end]).uppercased()
            }
            .joined(separator: ":")
    }
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
    private let userMove: (UInt32, UInt32) -> Void
    private let trustDecision: (UUID, Bool, Bool) -> Void

    init(
        cancellation: @escaping () -> Void,
        userMove: @escaping (UInt32, UInt32) -> Void,
        trustDecision: @escaping (UUID, Bool, Bool) -> Void
    ) {
        self.cancellation = cancellation
        self.userMove = userMove
        self.trustDecision = trustDecision
    }

    func cancel() {
        cancellation()
    }

    func joinChannel(sessionID: UInt32, channelID: UInt32) {
        userMove(sessionID, channelID)
    }

    func resolveCertificateTrust(challengeID: UUID, accept: Bool, remember: Bool) {
        trustDecision(challengeID, accept, remember)
    }
}

struct MumbleChannelListService: Sendable {
    private let logger: AppLogger
    private let trustedCertificateStore: TrustedCertificateStore

    init(logger: AppLogger, trustedCertificateStore: TrustedCertificateStore) {
        self.logger = logger
        self.trustedCertificateStore = trustedCertificateStore
    }

    func connect(
        to target: MumbleConnectionTarget,
        onEvent: @escaping @Sendable (MumbleChannelListEvent) -> Void
    ) -> MumbleChannelListConnectionHandle {
        let client = MumbleChannelListClient(
            target: target,
            logger: logger,
            trustedCertificateStore: trustedCertificateStore,
            onEvent: onEvent
        )
        client.start()

        return MumbleChannelListConnectionHandle(
            cancellation: {
                client.cancel(isUserInitiated: true)
            },
            userMove: { sessionID, channelID in
                client.moveUser(sessionID: sessionID, to: channelID)
            },
            trustDecision: { challengeID, accept, remember in
                client.resolveCertificateTrust(
                    challengeID: challengeID,
                    accept: accept,
                    remember: remember
                )
            }
        )
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

struct MumblePermissionDeniedMessage {
    let reason: String?
}

enum MumbleReconnectPolicy {
    static let maximumAttempts = 5

    static func delay(forAttempt attempt: Int) -> TimeInterval {
        let normalizedAttempt = max(attempt, 1)
        return min(pow(2.0, Double(normalizedAttempt - 1)), 15)
    }
}

enum MumbleSessionPayloads {
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

    static func joinChannelPacket(sessionID: UInt32, channelID: UInt32) -> Data {
        var payload = Data()
        MumbleProtobufWire.appendVarintField(1, value: UInt64(sessionID), to: &payload)
        MumbleProtobufWire.appendVarintField(5, value: UInt64(channelID), to: &payload)
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

    static func decodePermissionDenied(from data: Data) -> MumblePermissionDeniedMessage? {
        let payload = data[...]
        var index = payload.startIndex
        var reason: String?

        while index < payload.endIndex {
            guard let key = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                return nil
            }

            let fieldNumber = key >> 3
            let wireType = key & 0x07

            switch (fieldNumber, wireType) {
            case (4, 2):
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

        return MumblePermissionDeniedMessage(reason: reason)
    }
}

private final class MumbleChannelListClient {
    private struct CertificateMetadata {
        let commonName: String
        let subjectSummary: String
        let fingerprintSHA256: String
    }

    private struct PendingCertificateTrustChallenge {
        let challenge: MumbleCertificateTrustChallenge
        let completion: (Bool) -> Void
    }

    private let target: MumbleConnectionTarget
    private let logger: AppLogger
    private let trustedCertificateStore: TrustedCertificateStore
    private let onEvent: @Sendable (MumbleChannelListEvent) -> Void
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var connectionGeneration = 0

    private var receiveBuffer = Data()
    private var channels: [UInt32: MumbleChannel] = [:]
    private var users: [UInt32: MumbleUser] = [:]
    private var currentSessionID: UInt32?
    private var pingTimer: DispatchSourceTimer?
    private var reconnectTimer: DispatchSourceTimer?
    private var isUserInitiatedCancellation = false
    private var hasFinished = false
    private var reconnectAttempt = 0
    private var hasSynchronized = false
    private var pendingCertificateTrustChallenge: PendingCertificateTrustChallenge?
    private var temporarilyTrustedCertificateFingerprintSHA256: String?

    init(
        target: MumbleConnectionTarget,
        logger: AppLogger,
        trustedCertificateStore: TrustedCertificateStore,
        onEvent: @escaping @Sendable (MumbleChannelListEvent) -> Void
    ) {
        self.target = target
        self.logger = logger
        self.trustedCertificateStore = trustedCertificateStore
        self.onEvent = onEvent
        queue = DispatchQueue(label: "dev.kiwiapps.Mumble.protocol.channel-list.\(UUID().uuidString)")
    }

    func start() {
        queue.async { [weak self] in
            self?.startConnectionAttempt()
        }
    }

    func cancel(isUserInitiated: Bool) {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            if isUserInitiated {
                isUserInitiatedCancellation = true
            }

            hasFinished = true
            pendingCertificateTrustChallenge = nil
            stopPingLoop()
            stopReconnectLoop()
            teardownCurrentConnection()
        }
    }

    func moveUser(sessionID: UInt32, to channelID: UInt32) {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            guard currentSessionID != nil else {
                logger.error("Ignoring move request before synchronization for \(target.endpointDescription)")
                return
            }

            sendMessage(
                type: .userState,
                payload: MumbleSessionPayloads.joinChannelPacket(
                    sessionID: sessionID,
                    channelID: channelID
                )
            )
        }
    }

    func resolveCertificateTrust(challengeID: UUID, accept: Bool, remember: Bool) {
        queue.async { [weak self] in
            guard
                let self,
                let pendingChallenge = pendingCertificateTrustChallenge,
                pendingChallenge.challenge.id == challengeID
            else {
                return
            }

            pendingCertificateTrustChallenge = nil

            if accept {
                temporarilyTrustedCertificateFingerprintSHA256 = pendingChallenge.challenge.fingerprintSHA256

                if remember {
                    let challenge = pendingChallenge.challenge
                    let completion = pendingChallenge.completion
                    Task {
                        do {
                            try await self.trustedCertificateStore.trustCertificate(
                                host: challenge.host,
                                port: challenge.port,
                                fingerprintSHA256: challenge.fingerprintSHA256,
                                commonName: challenge.commonName,
                                subjectSummary: challenge.subjectSummary
                            )
                        } catch {
                            self.logger.error("Failed to persist trusted certificate: \(error.localizedDescription)")
                        }

                        completion(true)
                    }
                } else {
                    pendingChallenge.completion(true)
                }
            } else {
                pendingChallenge.completion(false)
                finish(with: .failed("Certificate trust denied for \(target.endpointDescription).", nil))
            }
        }
    }

    private func startConnectionAttempt() {
        guard !hasFinished else {
            return
        }

        stopReconnectLoop()
        stopPingLoop()
        pendingCertificateTrustChallenge = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        channels = [:]
        users = [:]
        currentSessionID = nil
        hasSynchronized = false

        let connection = makeConnection()
        self.connection = connection
        connectionGeneration += 1
        let generation = connectionGeneration

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleState(state, generation: generation)
        }

        connection.start(queue: queue)
    }

    private func makeConnection() -> NWConnection {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { [weak self] _, trust, complete in
                self?.evaluateServerTrust(trust, completion: complete)
            },
            queue
        )

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true

        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true

        return NWConnection(
            host: NWEndpoint.Host(target.host),
            port: NWEndpoint.Port(rawValue: UInt16(target.port)) ?? 64738,
            using: parameters
        )
    }

    private func handleState(_ state: NWConnection.State, generation: Int) {
        guard generation == connectionGeneration else {
            return
        }

        switch state {
        case .ready:
            logger.info("TCP session ready for \(target.endpointDescription)")
            emit(.log("Secure connection established to \(target.endpointDescription)."))
            sendInitialHandshake()
            startPingLoop()
            receiveNextChunk(generation: generation)
        case .failed(let error):
            handleTransportInterruption(
                reason: "Failed to connect to \(target.endpointDescription): \(error.localizedDescription)",
                generation: generation
            )
        case .cancelled:
            stopPingLoop()

            guard generation == connectionGeneration, !hasFinished else {
                return
            }

            if !isUserInitiatedCancellation {
                handleTransportInterruption(
                    reason: "Disconnected from \(target.label).",
                    generation: generation
                )
            }
        default:
            break
        }
    }

    private func evaluateServerTrust(
        _ trust: sec_trust_t,
        completion: @escaping (Bool) -> Void
    ) {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, target.host as CFString))

        var trustError: CFError?
        if SecTrustEvaluateWithError(secTrust, &trustError) {
            completion(true)
            return
        }

        guard let certificateMetadata = Self.certificateMetadata(from: secTrust) else {
            completion(false)
            return
        }

        Task { [weak self] in
            guard let self else {
                completion(false)
                return
            }

            let failureDescription = (trustError as Error?)?.localizedDescription ?? "The certificate could not be verified by macOS."
            if temporarilyTrustedCertificateFingerprintSHA256 == certificateMetadata.fingerprintSHA256 {
                completion(true)
                return
            }

            let isAlreadyTrusted = (try? await trustedCertificateStore.isTrusted(
                host: target.host,
                port: target.port,
                fingerprintSHA256: certificateMetadata.fingerprintSHA256
            )) ?? false

            queue.async { [weak self] in
                guard let self else {
                    completion(false)
                    return
                }

                if isAlreadyTrusted {
                    completion(true)
                    return
                }

                let challenge = MumbleCertificateTrustChallenge(
                    id: UUID(),
                    serverID: target.serverID,
                    serverLabel: target.label,
                    host: target.host,
                    port: target.port,
                    commonName: certificateMetadata.commonName,
                    subjectSummary: certificateMetadata.subjectSummary,
                    fingerprintSHA256: certificateMetadata.fingerprintSHA256,
                    failureDescription: failureDescription
                )

                pendingCertificateTrustChallenge = PendingCertificateTrustChallenge(
                    challenge: challenge,
                    completion: completion
                )
                emit(.certificateTrustRequired(challenge))
            }
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
        stopPingLoop()
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
        guard let connection else {
            return
        }

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

    private func receiveNextChunk(generation: Int) {
        guard let connection else {
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            guard generation == connectionGeneration else {
                return
            }

            if let data, !data.isEmpty {
                receiveBuffer.append(data)
                processBufferedMessages()
            }

            if let error {
                handleTransportInterruption(
                    reason: "Connection to \(target.endpointDescription) failed: \(error.localizedDescription)",
                    generation: generation
                )
                return
            }

            if isComplete {
                handleTransportInterruption(
                    reason: "Disconnected from \(target.label).",
                    generation: generation
                )
                return
            }

            receiveNextChunk(generation: generation)
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

            reconnectAttempt = 0
            hasSynchronized = true
            currentSessionID = serverSync.currentSessionID
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
        case .permissionDenied:
            let permissionDenied = MumbleSessionMessageDecoder.decodePermissionDenied(from: payload)
            emit(.log(permissionDenied?.reason ?? "Permission denied."))
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
        pendingCertificateTrustChallenge = nil
        stopPingLoop()
        stopReconnectLoop()
        emit(event)
        teardownCurrentConnection()
    }

    private func handleTransportInterruption(reason: String, generation: Int) {
        guard generation == connectionGeneration, !hasFinished else {
            return
        }

        stopPingLoop()
        pendingCertificateTrustChallenge = nil
        teardownCurrentConnection()
        scheduleReconnect(after: reason)
    }

    private func scheduleReconnect(after reason: String) {
        guard !isUserInitiatedCancellation, !hasFinished else {
            return
        }

        let nextAttempt = reconnectAttempt + 1
        guard nextAttempt <= MumbleReconnectPolicy.maximumAttempts else {
            finish(
                with: .disconnected(
                    "Lost connection to \(target.label) after \(MumbleReconnectPolicy.maximumAttempts) reconnect attempts. Last error: \(reason)"
                )
            )
            return
        }

        reconnectAttempt = nextAttempt
        let delay = MumbleReconnectPolicy.delay(forAttempt: nextAttempt)
        users = [:]
        currentSessionID = nil
        emit(.usersUpdated([]))
        emit(
            .reconnecting(
                reason: reason,
                attempt: nextAttempt,
                maximumAttempts: MumbleReconnectPolicy.maximumAttempts,
                delay: delay
            )
        )

        stopReconnectLoop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(Int(delay * 1_000)))
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }

            self.reconnectTimer = nil
            self.startConnectionAttempt()
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func stopReconnectLoop() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    private func teardownCurrentConnection() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func emit(_ event: MumbleChannelListEvent) {
        onEvent(event)
    }

    private static func certificateMetadata(from trust: SecTrust) -> CertificateMetadata? {
        guard let certificate = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = certificate.first else {
            return nil
        }

        let certificateData = SecCertificateCopyData(certificate) as Data
        let fingerprintSHA256 = SHA256.hash(data: certificateData)
            .map { String(format: "%02x", $0) }
            .joined()

        var commonNameReference: CFString?
        SecCertificateCopyCommonName(certificate, &commonNameReference)

        return CertificateMetadata(
            commonName: commonNameReference as String? ?? "",
            subjectSummary: SecCertificateCopySubjectSummary(certificate) as String? ?? "",
            fingerprintSHA256: fingerprintSHA256
        )
    }
}
