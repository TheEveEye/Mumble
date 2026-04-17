import Foundation

enum MumblePushToTalkMode: String, CaseIterable, Sendable {
    case localChannel
    case linkedChannels

    var targetOrContext: UInt32 {
        switch self {
        case .localChannel:
            return 0
        case .linkedChannels:
            return 1
        }
    }

    var talkState: MumbleUserTalkState {
        switch self {
        case .localChannel:
            return .talking
        case .linkedChannels:
            return .shouting
        }
    }
}
