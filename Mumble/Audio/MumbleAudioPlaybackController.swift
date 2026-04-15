import Foundation
import AVFoundation

actor MumbleAudioPlaybackController {
    private enum PlaybackRejectionReason: String {
        case outputMuted = "output muted"
        case missingCurrentSession = "missing current session"
        case missingActiveChannel = "missing active channel"
        case missingSenderChannel = "missing sender channel"
        case differentChannel = "sender is in a different channel"
    }

    private struct SessionContext {
        let currentSessionID: UInt32?
        let activeChannelID: UInt32?
        let usersBySession: [UInt32: MumbleUser]
    }

    private let logger: AppLogger
    private let engine = AVAudioEngine()
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    private var decoders: [UInt32: MumbleOpusDecoder] = [:]
    private var playerNodes: [UInt32: AVAudioPlayerNode] = [:]
    private var context = SessionContext(currentSessionID: nil, activeChannelID: nil, usersBySession: [:])
    private var hasStartedEngine = false
    private var outputVolume: Float = 1.0
    private var isOutputMuted = false
    private var receivedVoicePacketCount = 0
    private var rejectedVoicePacketCount = 0
    private var scheduledBufferCount = 0

    init(logger: AppLogger) {
        self.logger = logger
    }

    func updatePreferences(outputVolume: Double, isOutputMuted: Bool) {
        self.outputVolume = Float(min(max(outputVolume, 0), 2))
        self.isOutputMuted = isOutputMuted
        engine.mainMixerNode.outputVolume = isOutputMuted ? 0 : self.outputVolume
        logger.info(
            "Audio playback preferences updated: muted=\(isOutputMuted), volume=\(String(format: "%.2f", self.outputVolume))"
        )
    }

    func updateSession(users: [MumbleUser], currentSessionID: UInt32?) {
        let usersBySession = Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0) })
        let activeChannelID = currentSessionID.flatMap { usersBySession[$0]?.channelID }

        context = SessionContext(
            currentSessionID: currentSessionID,
            activeChannelID: activeChannelID,
            usersBySession: usersBySession
        )

        let activeSessions = Set(users.map(\.id))
        let removableSessions = Set(playerNodes.keys).subtracting(activeSessions)
        for sessionID in removableSessions {
            removePlaybackResources(for: sessionID)
        }

        logger.debug(
            "Audio session updated: currentSessionID=\(currentSessionID.map(String.init) ?? "nil"), " +
            "activeChannelID=\(activeChannelID.map(String.init) ?? "nil"), users=\(users.count)"
        )
    }

    func handleVoicePacket(_ packet: MumbleVoicePacket) {
        receivedVoicePacketCount += 1
        if shouldLog(packetIndex: receivedVoicePacketCount) {
            logger.info(
                "Received voice packet #\(receivedVoicePacketCount) from session \(packet.senderSession), " +
                "frame=\(packet.frameNumber), payloadBytes=\(packet.payload.count)"
            )
        }

        guard shouldPlay(packet) else {
            return
        }

        do {
            try startEngineIfNeeded()
            let decoder = try decoder(for: packet.senderSession)

            guard let buffer = try decoder.decode(packet: packet.payload) else {
                logger.error("Opus decoder returned no PCM buffer for session \(packet.senderSession).")
                return
            }

            if packet.volumeAdjustment != 1.0 {
                scale(buffer: buffer, by: packet.volumeAdjustment)
            }

            let playerNode = playerNode(for: packet.senderSession)
            playerNode.scheduleBuffer(buffer)
            scheduledBufferCount += 1
            if shouldLog(packetIndex: scheduledBufferCount) {
                logger.info(
                    "Scheduled audio buffer #\(scheduledBufferCount) for session \(packet.senderSession), " +
                    "frames=\(buffer.frameLength), sampleRate=\(Int(buffer.format.sampleRate))"
                )
            }

            if !playerNode.isPlaying {
                playerNode.play()
                logger.info("Started playback node for session \(packet.senderSession).")
            }
        } catch {
            logger.error("Audio playback failed for session \(packet.senderSession): \(error.localizedDescription)")
        }
    }

    func stop() {
        for sessionID in Array(playerNodes.keys) {
            removePlaybackResources(for: sessionID)
        }

        if engine.isRunning {
            engine.stop()
        }

        hasStartedEngine = false
        context = SessionContext(currentSessionID: nil, activeChannelID: nil, usersBySession: [:])
        logger.info("Audio playback stopped and session state cleared.")
    }

    private func shouldPlay(_ packet: MumbleVoicePacket) -> Bool {
        if isOutputMuted {
            logRejectedPacket(reason: .outputMuted, packet: packet)
            return false
        }

        guard let currentSessionID = context.currentSessionID, currentSessionID != 0 else {
            logRejectedPacket(reason: .missingCurrentSession, packet: packet)
            return false
        }

        guard let activeChannelID = context.activeChannelID else {
            logRejectedPacket(reason: .missingActiveChannel, packet: packet)
            return false
        }

        guard let senderChannelID = context.usersBySession[packet.senderSession]?.channelID else {
            logRejectedPacket(reason: .missingSenderChannel, packet: packet)
            return false
        }

        guard senderChannelID == activeChannelID else {
            logRejectedPacket(reason: .differentChannel, packet: packet)
            return false
        }

        return true
    }

    private func startEngineIfNeeded() throws {
        guard !hasStartedEngine else {
            return
        }

        engine.mainMixerNode.outputVolume = isOutputMuted ? 0 : outputVolume
        try engine.start()
        hasStartedEngine = true
        logger.info("Audio engine started for receive-only playback.")
    }

    private func decoder(for sessionID: UInt32) throws -> MumbleOpusDecoder {
        if let decoder = decoders[sessionID] {
            return decoder
        }

        guard let decoder = MumbleOpusDecoder() else {
            throw MumbleAudioPlaybackError.decoderUnavailable
        }

        decoders[sessionID] = decoder
        return decoder
    }

    private func playerNode(for sessionID: UInt32) -> AVAudioPlayerNode {
        if let existingNode = playerNodes[sessionID] {
            return existingNode
        }

        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: outputFormat)
        playerNodes[sessionID] = node
        logger.debug("Created playback node for session \(sessionID).")
        return node
    }

    private func removePlaybackResources(for sessionID: UInt32) {
        if let playerNode = playerNodes.removeValue(forKey: sessionID) {
            playerNode.stop()
            engine.disconnectNodeOutput(playerNode)
            engine.detach(playerNode)
        }

        decoders.removeValue(forKey: sessionID)
    }

    private func logRejectedPacket(reason: PlaybackRejectionReason, packet: MumbleVoicePacket) {
        rejectedVoicePacketCount += 1
        guard shouldLog(packetIndex: rejectedVoicePacketCount) else {
            return
        }

        logger.info(
            "Rejected voice packet #\(rejectedVoicePacketCount) from session \(packet.senderSession): \(reason.rawValue). " +
            "currentSessionID=\(context.currentSessionID.map(String.init) ?? "nil"), " +
            "activeChannelID=\(context.activeChannelID.map(String.init) ?? "nil"), " +
            "senderChannelID=\(context.usersBySession[packet.senderSession]?.channelID.map(String.init) ?? "nil")"
        )
    }

    private func shouldLog(packetIndex: Int) -> Bool {
        packetIndex <= 5 || packetIndex % 50 == 0
    }

    private func scale(buffer: AVAudioPCMBuffer, by factor: Float) {
        guard let channelData = buffer.floatChannelData else {
            return
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        for channelIndex in 0..<channelCount {
            let samples = channelData[channelIndex]
            for frameIndex in 0..<frameCount {
                samples[frameIndex] *= factor
            }
        }
    }
}

enum MumbleAudioPlaybackError: Error {
    case decoderUnavailable
}
