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
    var linkedChannelIDs: [UInt32]

    var isLinked: Bool {
        linkedChannelIDs.isEmpty == false
    }
}

extension Dictionary where Key == UInt32, Value == MumbleChannel {
    func linkedClosure(startingAt channelID: UInt32?) -> Set<UInt32> {
        guard let channelID, self[channelID] != nil else {
            return []
        }

        var seen: Set<UInt32> = [channelID]
        var stack: [UInt32] = [channelID]

        while let currentChannelID = stack.popLast() {
            guard let channel = self[currentChannelID] else {
                continue
            }

            for linkedChannelID in channel.linkedChannelIDs where seen.insert(linkedChannelID).inserted {
                stack.append(linkedChannelID)
            }
        }

        return seen
    }
}

struct MumbleUser: Identifiable, Equatable, Hashable, Sendable {
    let id: UInt32
    var name: String
    var channelID: UInt32?
    var listeningChannelIDs: [UInt32]
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

enum MumbleUserTalkState: Equatable, Hashable, Sendable {
    case passive
    case talking
    case shouting
    case whispering
    case channelListening
}

enum MumbleChannelListEvent: Sendable {
    case log(String)
    case certificateTrustRequired(MumbleCertificateTrustChallenge)
    case reconnecting(reason: String, attempt: Int, maximumAttempts: Int, delay: TimeInterval)
    case synchronized(welcomeText: String?, currentSessionID: UInt32?)
    case channelsUpdated([MumbleChannel])
    case usersUpdated([MumbleUser])
    case talkStateChanged(sessionID: UInt32, talkState: MumbleUserTalkState)
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
    private let audioPlayback: MumbleAudioPlaybackController

    init(
        logger: AppLogger,
        trustedCertificateStore: TrustedCertificateStore,
        audioPlayback: MumbleAudioPlaybackController
    ) {
        self.logger = logger
        self.trustedCertificateStore = trustedCertificateStore
        self.audioPlayback = audioPlayback
    }

    func connect(
        to target: MumbleConnectionTarget,
        onEvent: @escaping @Sendable (MumbleChannelListEvent) -> Void
    ) -> MumbleChannelListConnectionHandle {
        let client = MumbleChannelListClient(
            target: target,
            logger: logger,
            trustedCertificateStore: trustedCertificateStore,
            audioPlayback: audioPlayback,
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
    let links: [UInt32]?
    let linksAdded: [UInt32]
    let linksRemoved: [UInt32]
}

struct MumbleUserStateMessage {
    let sessionID: UInt32
    let name: String?
    let registeredUserID: UInt32?
    let channelID: UInt32?
    let listeningChannelIDsAdded: [UInt32]
    let listeningChannelIDsRemoved: [UInt32]
    let isServerMuted: Bool?
    let isServerDeafened: Bool?
    let isSuppressed: Bool?
    let isSelfMuted: Bool?
    let isSelfDeafened: Bool?
}

struct MumblePermissionDeniedMessage {
    let reason: String?
}

struct MumbleUserRemoveMessage {
    let sessionID: UInt32
    let actorSessionID: UInt32?
    let reason: String?
    let isBan: Bool
}

struct MumbleCryptSetupMessage {
    let key: Data?
    let clientNonce: Data?
    let serverNonce: Data?
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

    static func cryptSetupPacket(clientNonce: Data) -> Data {
        var payload = Data()
        MumbleProtobufWire.appendBytesField(2, value: clientNonce, to: &payload)
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
        var links: [UInt32] = []
        var sawLinks = false
        var linksAdded: [UInt32] = []
        var linksRemoved: [UInt32] = []

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
            case (4, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                sawLinks = true
                if let linkID = UInt32(exactly: value) {
                    links.append(linkID)
                }
            case (6, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                if let linkID = UInt32(exactly: value) {
                    linksAdded.append(linkID)
                }
            case (7, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                if let linkID = UInt32(exactly: value) {
                    linksRemoved.append(linkID)
                }
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
            position: position,
            links: sawLinks ? links : nil,
            linksAdded: linksAdded,
            linksRemoved: linksRemoved
        )
    }

    static func decodeUserRemove(from data: Data) -> MumbleUserRemoveMessage? {
        let payload = data[...]
        var index = payload.startIndex
        var sessionID: UInt32?
        var actorSessionID: UInt32?
        var reason: String?
        var isBan = false

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
            case (2, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                actorSessionID = UInt32(exactly: value)
            case (3, 2):
                guard let value = MumbleProtobufWire.decodeLengthDelimited(from: payload, index: &index) else {
                    return nil
                }

                reason = String(data: Data(value), encoding: .utf8)
            case (4, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                isBan = value != 0
            default:
                guard MumbleProtobufWire.skipField(wireType: wireType, payload: payload, index: &index) else {
                    return nil
                }
            }
        }

        guard let sessionID else {
            return nil
        }

        return MumbleUserRemoveMessage(
            sessionID: sessionID,
            actorSessionID: actorSessionID,
            reason: reason,
            isBan: isBan
        )
    }

    static func decodeUserState(from data: Data) -> MumbleUserStateMessage? {
        let payload = data[...]
        var index = payload.startIndex

        var sessionID: UInt32?
        var name: String?
        var registeredUserID: UInt32?
        var channelID: UInt32?
        var listeningChannelIDsAdded: [UInt32] = []
        var listeningChannelIDsRemoved: [UInt32] = []
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
            case (21, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                if let channelID = UInt32(exactly: value) {
                    listeningChannelIDsAdded.append(channelID)
                }
            case (22, 0):
                guard let value = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                    return nil
                }

                if let channelID = UInt32(exactly: value) {
                    listeningChannelIDsRemoved.append(channelID)
                }
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
            listeningChannelIDsAdded: listeningChannelIDsAdded,
            listeningChannelIDsRemoved: listeningChannelIDsRemoved,
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

    static func decodeCryptSetup(from data: Data) -> MumbleCryptSetupMessage? {
        let payload = data[...]
        var index = payload.startIndex

        var key: Data?
        var clientNonce: Data?
        var serverNonce: Data?

        while index < payload.endIndex {
            guard let rawKey = MumbleProtobufWire.decodeVarint(from: payload, index: &index) else {
                return nil
            }

            let fieldNumber = rawKey >> 3
            let wireType = rawKey & 0x07

            switch (fieldNumber, wireType) {
            case (1, 2):
                guard let value = MumbleProtobufWire.decodeLengthDelimited(from: payload, index: &index) else {
                    return nil
                }
                key = Data(value)
            case (2, 2):
                guard let value = MumbleProtobufWire.decodeLengthDelimited(from: payload, index: &index) else {
                    return nil
                }
                clientNonce = Data(value)
            case (3, 2):
                guard let value = MumbleProtobufWire.decodeLengthDelimited(from: payload, index: &index) else {
                    return nil
                }
                serverNonce = Data(value)
            default:
                guard MumbleProtobufWire.skipField(wireType: wireType, payload: payload, index: &index) else {
                    return nil
                }
            }
        }

        return MumbleCryptSetupMessage(
            key: key,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )
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
    private let audioPlayback: MumbleAudioPlaybackController
    private let onEvent: @Sendable (MumbleChannelListEvent) -> Void
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var udpConnection: NWConnection?
    private var connectionGeneration = 0

    private var receiveBuffer = Data()
    private var channels: [UInt32: MumbleChannel] = [:]
    private var users: [UInt32: MumbleUser] = [:]
    private var currentSessionID: UInt32?
    private var pingTimer: DispatchSourceTimer?
    private var udpPingTimer: DispatchSourceTimer?
    private var reconnectTimer: DispatchSourceTimer?
    private var isUserInitiatedCancellation = false
    private var hasFinished = false
    private var reconnectAttempt = 0
    private var hasSynchronized = false
    private var pendingCertificateTrustChallenge: PendingCertificateTrustChallenge?
    private var temporarilyTrustedCertificateFingerprintSHA256: String?
    private var cryptState = MumbleCryptState()
    private var receivedUDPDatagramCount = 0
    private var decryptedUDPDatagramCount = 0
    private var receivedVoicePacketCount = 0
    private var undecodedVoiceTransportCount = 0
    private var talkStateResetWorkItems: [UInt32: DispatchWorkItem] = [:]

    init(
        target: MumbleConnectionTarget,
        logger: AppLogger,
        trustedCertificateStore: TrustedCertificateStore,
        audioPlayback: MumbleAudioPlaybackController,
        onEvent: @escaping @Sendable (MumbleChannelListEvent) -> Void
    ) {
        self.target = target
        self.logger = logger
        self.trustedCertificateStore = trustedCertificateStore
        self.audioPlayback = audioPlayback
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
            cancelAllTalkStateResets()
            stopPingLoop()
            stopUDPPingLoop()
            stopReconnectLoop()
            teardownCurrentConnection()
            Task { await self.audioPlayback.stop() }
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
        stopUDPPingLoop()
        pendingCertificateTrustChallenge = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        channels = [:]
        users = [:]
        currentSessionID = nil
        hasSynchronized = false
        cryptState = MumbleCryptState()
        receivedUDPDatagramCount = 0
        decryptedUDPDatagramCount = 0
        receivedVoicePacketCount = 0
        undecodedVoiceTransportCount = 0
        Task { await self.audioPlayback.stop() }

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
            stopUDPPingLoop()

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

    private func startUDPPingLoop() {
        guard cryptState.isValid else {
            return
        }

        stopUDPPingLoop()
        sendUDPPing()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
        timer.setEventHandler { [weak self] in
            self?.sendUDPPing()
        }
        timer.resume()
        udpPingTimer = timer
    }

    private func stopUDPPingLoop() {
        udpPingTimer?.cancel()
        udpPingTimer = nil
    }

    private func sendUDPPing() {
        guard
            let encryptedPacket = cryptState.encrypt(
                MumbleProtobufPingPacket.makeExtendedPingRequest(
                    timestamp: UInt64(Date().timeIntervalSince1970 * 1_000)
                )
            )
        else {
            return
        }

        sendUDPMessage(encryptedPacket)
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

    private func ensureUDPTransport() {
        guard udpConnection == nil else {
            return
        }

        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        let udpConnection = NWConnection(
            host: NWEndpoint.Host(target.host),
            port: NWEndpoint.Port(rawValue: UInt16(target.port)) ?? 64738,
            using: parameters
        )
        self.udpConnection = udpConnection

        udpConnection.stateUpdateHandler = { [weak self] state in
            self?.handleUDPState(state)
        }
        udpConnection.start(queue: queue)
        receiveUDPMessage()
    }

    private func handleUDPState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            logger.info("UDP transport ready for \(target.endpointDescription)")
            startUDPPingLoop()
        case .failed(let error):
            logger.error("UDP transport failed for \(target.endpointDescription): \(error.localizedDescription)")
            stopUDPPingLoop()
        case .cancelled:
            stopUDPPingLoop()
        default:
            break
        }
    }

    private func sendUDPMessage(_ packet: Data) {
        ensureUDPTransport()
        udpConnection?.send(content: packet, completion: .contentProcessed { [logger, target] error in
            if let error {
                logger.error("Failed to send UDP packet to \(target.endpointDescription): \(error.localizedDescription)")
            }
        })
    }

    private func receiveUDPMessage() {
        udpConnection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else {
                return
            }

            if let data, !data.isEmpty {
                handleUDPDatagram(data)
            }

            if let error {
                logger.error("UDP receive failed for \(target.endpointDescription): \(error.localizedDescription)")
                return
            }

            guard udpConnection != nil else {
                return
            }

            receiveUDPMessage()
        }
    }

    private func handleUDPDatagram(_ encryptedPacket: Data) {
        receivedUDPDatagramCount += 1
        if shouldLogVoiceTransportEvent(number: receivedUDPDatagramCount) {
            logger.info(
                "Received UDP datagram #\(receivedUDPDatagramCount) from \(target.endpointDescription), " +
                "bytes=\(encryptedPacket.count), leadingByte=0x\(String(format: "%02X", encryptedPacket.first ?? 0))"
            )
        }

        guard let decryptedPayload = cryptState.decrypt(encryptedPacket) else {
            logger.error(
                "Failed to decrypt UDP datagram #\(receivedUDPDatagramCount) from \(target.endpointDescription). " +
                "good=\(cryptState.goodPackets) late=\(cryptState.latePackets) lost=\(cryptState.lostPackets)"
            )
            return
        }

        decryptedUDPDatagramCount += 1
        if shouldLogVoiceTransportEvent(number: decryptedUDPDatagramCount) {
            logger.info(
                "Decrypted UDP payload #\(decryptedUDPDatagramCount) from \(target.endpointDescription), " +
                "bytes=\(decryptedPayload.count), header=0x\(String(format: "%02X", decryptedPayload.first ?? 0))"
            )
        }

        handleVoiceTransportPacket(decryptedPayload, source: "UDP")
    }

    private func handleVoiceTransportPacket(_ payload: Data, source: String) {
        guard let packet = MumbleUDPVoicePacketDecoder.decode(payload) else {
            undecodedVoiceTransportCount += 1
            logger.error(
                "Unable to decode \(source) voice transport packet #\(undecodedVoiceTransportCount) from \(target.endpointDescription). " +
                "bytes=\(payload.count), header=0x\(String(format: "%02X", payload.first ?? 0))"
            )
            return
        }

        switch packet {
        case .ping:
            if shouldLogVoiceTransportEvent(number: decryptedUDPDatagramCount) {
                logger.debug("Received \(source) voice transport ping from \(target.endpointDescription).")
            }
        case .audio(let voicePacket):
            receivedVoicePacketCount += 1
            if shouldLogVoiceTransportEvent(number: receivedVoicePacketCount) {
                logger.info(
                    "Decoded \(source) audio packet #\(receivedVoicePacketCount) from session \(voicePacket.senderSession), " +
                    "frame=\(voicePacket.frameNumber), payloadBytes=\(voicePacket.payload.count)"
                )
            }
            Task { await self.audioPlayback.handleVoicePacket(voicePacket) }
            updateTalkState(from: voicePacket)
        }
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
        case .cryptSetup:
            guard let cryptSetup = MumbleSessionMessageDecoder.decodeCryptSetup(from: payload) else {
                return
            }

            handleCryptSetup(cryptSetup)
        case .serverSync:
            guard let serverSync = MumbleSessionMessageDecoder.decodeServerSync(from: payload) else {
                return
            }

            reconnectAttempt = 0
            hasSynchronized = true
            currentSessionID = serverSync.currentSessionID
            updateAudioSessionState()
            emit(.synchronized(welcomeText: serverSync.welcomeText, currentSessionID: serverSync.currentSessionID))
        case .udpTunnel:
            handleVoiceTransportPacket(payload, source: "TCP tunnel")
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
            guard let userRemove = MumbleSessionMessageDecoder.decodeUserRemove(from: payload) else {
                return
            }

            if userRemove.sessionID == currentSessionID {
                finish(with: .disconnected(describeCurrentUserRemoval(userRemove)))
                return
            }

            cancelTalkStateReset(for: userRemove.sessionID)
            users.removeValue(forKey: userRemove.sessionID)
            emit(.talkStateChanged(sessionID: userRemove.sessionID, talkState: .passive))
            emitUserSnapshot()
            updateAudioSessionState()
        default:
            break
        }
    }

    private func handleCryptSetup(_ message: MumbleCryptSetupMessage) {
        if let key = message.key, let clientNonce = message.clientNonce, let serverNonce = message.serverNonce {
            guard cryptState.setKey(key: key, clientNonce: clientNonce, serverNonce: serverNonce) else {
                emit(.log("Received invalid UDP crypt setup from \(target.endpointDescription)."))
                return
            }

            ensureUDPTransport()
            startUDPPingLoop()
            return
        }

        if let serverNonce = message.serverNonce {
            guard cryptState.setDecryptIV(serverNonce) else {
                emit(.log("Received invalid UDP server nonce from \(target.endpointDescription)."))
                return
            }

            ensureUDPTransport()
            startUDPPingLoop()
            return
        }

        guard cryptState.isValid else {
            return
        }

        sendMessage(
            type: .cryptSetup,
            payload: MumbleSessionPayloads.cryptSetupPacket(clientNonce: cryptState.currentEncryptIV())
        )
    }

    private func describeCurrentUserRemoval(_ message: MumbleUserRemoveMessage) -> String {
        let actorName = message.actorSessionID.flatMap { users[$0]?.name }
        let trimmedReason = message.reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasReason = trimmedReason?.isEmpty == false

        if message.isBan {
            if let actorName, hasReason {
                return "You were kicked and banned from the server by \(actorName): \(trimmedReason!)."
            }

            if let actorName {
                return "You were kicked and banned from the server by \(actorName)."
            }

            if hasReason {
                return "You were kicked and banned from the server: \(trimmedReason!)."
            }

            return "You were kicked and banned from the server."
        }

        if let actorName, hasReason {
            return "You were kicked from the server by \(actorName): \(trimmedReason!)."
        }

        if let actorName {
            return "You were kicked from the server by \(actorName)."
        }

        if hasReason {
            return "You were removed from the server: \(trimmedReason!)."
        }

        return "You were removed from the server."
    }

    private func applyChannelState(_ message: MumbleChannelStateMessage) {
        var channel = channels[message.channelID] ?? MumbleChannel(
            id: message.channelID,
            name: "Channel \(message.channelID)",
            parentID: nil,
            position: 0,
            linkedChannelIDs: []
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

        var linkedChannelIDs = Set(channel.linkedChannelIDs)

        if let links = message.links {
            linkedChannelIDs = Set(links)
        }

        if message.linksAdded.isEmpty == false {
            linkedChannelIDs.formUnion(message.linksAdded)
        }

        if message.linksRemoved.isEmpty == false {
            linkedChannelIDs.subtract(message.linksRemoved)
        }

        linkedChannelIDs.remove(message.channelID)
        channel.linkedChannelIDs = linkedChannelIDs.sorted()

        channels[message.channelID] = channel
        emitChannelSnapshot()
    }

    private func applyUserState(_ message: MumbleUserStateMessage) {
        var user = users[message.sessionID] ?? MumbleUser(
            id: message.sessionID,
            name: "User \(message.sessionID)",
            channelID: nil,
            listeningChannelIDs: [],
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

        if !message.listeningChannelIDsAdded.isEmpty || !message.listeningChannelIDsRemoved.isEmpty {
            var listeningChannelIDs = Set(user.listeningChannelIDs)
            listeningChannelIDs.formUnion(message.listeningChannelIDsAdded)
            listeningChannelIDs.subtract(message.listeningChannelIDsRemoved)

            if let channelID = user.channelID {
                listeningChannelIDs.remove(channelID)
            }

            user.listeningChannelIDs = listeningChannelIDs.sorted()
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
        updateAudioSessionState()
    }

    private func updateTalkState(from packet: MumbleVoicePacket) {
        guard users[packet.senderSession] != nil else {
            return
        }

        let talkState = talkState(for: packet)
        emit(.talkStateChanged(sessionID: packet.senderSession, talkState: talkState))

        scheduleTalkStateReset(for: packet.senderSession, isTerminator: packet.isTerminator)
    }

    private func talkState(for packet: MumbleVoicePacket) -> MumbleUserTalkState {
        switch packet.targetOrContext {
        case 1:
            return .shouting
        case 2:
            return .whispering
        case 3:
            return .channelListening
        default:
            return .talking
        }
    }

    private func scheduleTalkStateReset(for sessionID: UInt32, isTerminator: Bool) {
        cancelTalkStateReset(for: sessionID)

        let resetDelay: TimeInterval = isTerminator ? 0.15 : 0.35
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.users[sessionID] != nil else {
                return
            }

            self.emit(.talkStateChanged(sessionID: sessionID, talkState: .passive))
        }

        talkStateResetWorkItems[sessionID] = workItem
        queue.asyncAfter(deadline: .now() + resetDelay, execute: workItem)
    }

    private func cancelTalkStateReset(for sessionID: UInt32) {
        talkStateResetWorkItems.removeValue(forKey: sessionID)?.cancel()
    }

    private func cancelAllTalkStateResets() {
        for workItem in talkStateResetWorkItems.values {
            workItem.cancel()
        }

        talkStateResetWorkItems.removeAll()
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
        updateAudioSessionState()
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

    private func updateAudioSessionState() {
        let userSnapshot = users.values.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)

            if comparison == .orderedSame {
                return $0.id < $1.id
            }

            return comparison == .orderedAscending
        }
        let channelSnapshot = channels.values.sorted {
            if $0.position == $1.position {
                let comparison = $0.name.localizedStandardCompare($1.name)

                if comparison == .orderedSame {
                    return $0.id < $1.id
                }

                return comparison == .orderedAscending
            }

            return $0.position < $1.position
        }

        let currentSessionID = currentSessionID
        Task {
            await self.audioPlayback.updateSession(
                channels: channelSnapshot,
                users: userSnapshot,
                currentSessionID: currentSessionID
            )
        }
    }

    private func shouldLogVoiceTransportEvent(number: Int) -> Bool {
        number <= 5 || number % 50 == 0
    }

    private func finish(with event: MumbleChannelListEvent) {
        guard !hasFinished else {
            return
        }

        hasFinished = true
        pendingCertificateTrustChallenge = nil
        stopPingLoop()
        stopUDPPingLoop()
        stopReconnectLoop()
        emit(event)
        teardownCurrentConnection()
        Task { await self.audioPlayback.stop() }
    }

    private func handleTransportInterruption(reason: String, generation: Int) {
        guard generation == connectionGeneration, !hasFinished else {
            return
        }

        stopPingLoop()
        stopUDPPingLoop()
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
        udpConnection?.stateUpdateHandler = nil
        udpConnection?.cancel()
        udpConnection = nil
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
