import Testing
@testable import Mumble

struct MumblePushToTalkModeTests {
    @Test
    func localChannelModeUsesWhisperTargetAndTalkState() {
        #expect(MumblePushToTalkMode.localChannel.targetOrContext == MumbleSessionPayloads.localChannelVoiceTargetID)

        guard case .whispering = MumblePushToTalkMode.localChannel.talkState else {
            Issue.record("Expected local-channel push-to-talk to display as whispering")
            return
        }
    }

    @Test
    func linkedChannelModeUsesShoutTargetAndTalkState() {
        #expect(MumblePushToTalkMode.linkedChannels.targetOrContext == MumbleSessionPayloads.linkedChannelVoiceTargetID)

        guard case .shouting = MumblePushToTalkMode.linkedChannels.talkState else {
            Issue.record("Expected linked-channel push-to-talk to display as shouting")
            return
        }
    }
}
