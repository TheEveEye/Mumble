import Foundation

enum MumblePushToTalkMode: String, CaseIterable, Sendable {
    case localChannel
    case linkedChannels

    var targetOrContext: UInt32 {
        switch self {
        case .localChannel:
            return MumbleSessionPayloads.localChannelVoiceTargetID
        case .linkedChannels:
            return 0
        }
    }

    var talkState: MumbleUserTalkState {
        switch self {
        case .localChannel:
            return .talking
        case .linkedChannels:
            return .talking
        }
    }
}
