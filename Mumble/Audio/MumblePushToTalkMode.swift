import Foundation

enum MumblePushToTalkMode: String, CaseIterable, Sendable {
    case localChannel
    case linkedChannels

    var targetOrContext: UInt32 {
        switch self {
        case .localChannel:
            return MumbleSessionPayloads.localChannelVoiceTargetID
        case .linkedChannels:
            return MumbleSessionPayloads.linkedChannelVoiceTargetID
        }
    }

    var talkState: MumbleUserTalkState {
        switch self {
        case .localChannel:
            return .whispering
        case .linkedChannels:
            return .shouting
        }
    }
}
