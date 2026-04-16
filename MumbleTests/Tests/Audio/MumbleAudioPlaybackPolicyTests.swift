import Foundation
import Testing
@testable import Mumble

struct MumbleAudioPlaybackPolicyTests {
    @Test
    func allowsRegularSpeechFromCurrentChannel() {
        let context = makeContext(
            activeChannelID: 10,
            senderChannelID: 10,
            linkedChannelIDs: []
        )
        let packet = makePacket(targetOrContext: 0)

        let rejection = MumbleAudioPlaybackPolicy.rejectionReason(
            for: packet,
            context: context,
            isOutputMuted: false
        )

        #expect(rejection == nil)
    }

    @Test
    func allowsRegularSpeechFromLinkedChannel() {
        let context = makeContext(
            activeChannelID: 10,
            senderChannelID: 20,
            linkedChannelIDs: [20]
        )
        let packet = makePacket(targetOrContext: 0)

        let rejection = MumbleAudioPlaybackPolicy.rejectionReason(
            for: packet,
            context: context,
            isOutputMuted: false
        )

        #expect(rejection == nil)
    }

    @Test
    func allowsShoutToCurrentChannelEvenWhenSenderIsElsewhere() {
        let context = makeContext(
            activeChannelID: 10,
            senderChannelID: 99,
            linkedChannelIDs: []
        )
        let packet = makePacket(targetOrContext: 1)

        let rejection = MumbleAudioPlaybackPolicy.rejectionReason(
            for: packet,
            context: context,
            isOutputMuted: false
        )

        #expect(rejection == nil)
    }

    @Test
    func allowsSpeechFromUnrelatedChannelWhenServerDeliversIt() {
        let context = makeContext(
            activeChannelID: 10,
            senderChannelID: 30,
            linkedChannelIDs: [20]
        )
        let packet = makePacket(targetOrContext: 0)

        let rejection = MumbleAudioPlaybackPolicy.rejectionReason(
            for: packet,
            context: context,
            isOutputMuted: false
        )

        #expect(rejection == nil)
    }

    @Test
    func rejectsPacketsWhenCurrentSessionIsMissing() {
        let context = MumbleAudioSessionContext(
            currentSessionID: nil,
            activeChannelID: 10,
            usersBySession: [:],
            channelsByID: [:]
        )

        let rejection = MumbleAudioPlaybackPolicy.rejectionReason(
            for: makePacket(targetOrContext: 0),
            context: context,
            isOutputMuted: false
        )

        #expect(rejection == .missingCurrentSession)
    }

    @Test
    func rejectsPacketsWhenOutputIsMuted() {
        let context = makeContext(
            activeChannelID: 10,
            senderChannelID: 10,
            linkedChannelIDs: []
        )

        let rejection = MumbleAudioPlaybackPolicy.rejectionReason(
            for: makePacket(targetOrContext: 0),
            context: context,
            isOutputMuted: true
        )

        #expect(rejection == .outputMuted)
    }

    private func makeContext(
        activeChannelID: UInt32,
        senderChannelID: UInt32,
        linkedChannelIDs: [UInt32]
    ) -> MumbleAudioSessionContext {
        let activeChannel = MumbleChannel(
            id: activeChannelID,
            name: "Current",
            parentID: nil,
            position: 0,
            linkedChannelIDs: linkedChannelIDs
        )
        let senderChannel = MumbleChannel(
            id: senderChannelID,
            name: "Sender",
            parentID: nil,
            position: 1,
            linkedChannelIDs: []
        )
        let currentUser = MumbleUser(
            id: 1,
            name: "Current User",
            channelID: activeChannelID,
            listeningChannelIDs: [],
            registeredUserID: 1,
            isServerMuted: false,
            isServerDeafened: false,
            isSuppressed: false,
            isSelfMuted: false,
            isSelfDeafened: false
        )
        let senderUser = MumbleUser(
            id: 2,
            name: "Sender",
            channelID: senderChannelID,
            listeningChannelIDs: [],
            registeredUserID: 2,
            isServerMuted: false,
            isServerDeafened: false,
            isSuppressed: false,
            isSelfMuted: false,
            isSelfDeafened: false
        )

        var usersBySession: [UInt32: MumbleUser] = [
            currentUser.id: currentUser,
            senderUser.id: senderUser,
        ]
        usersBySession[currentUser.id] = currentUser
        usersBySession[senderUser.id] = senderUser

        var channelsByID: [UInt32: MumbleChannel] = [
            activeChannel.id: activeChannel
        ]
        channelsByID[senderChannel.id] = senderChannel

        return MumbleAudioSessionContext(
            currentSessionID: currentUser.id,
            activeChannelID: activeChannelID,
            usersBySession: usersBySession,
            channelsByID: channelsByID
        )
    }

    private func makePacket(targetOrContext: UInt32) -> MumbleVoicePacket {
        MumbleVoicePacket(
            senderSession: 2,
            frameNumber: 42,
            payload: Data([0x01, 0x02]),
            isTerminator: false,
            targetOrContext: targetOrContext,
            volumeAdjustment: 1.0
        )
    }
}
