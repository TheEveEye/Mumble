import Foundation

struct MumblePushToTalkInputResult: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case none
        case start(MumblePushToTalkMode)
        case stop
    }

    let action: Action
    let shouldConsumeLocalEvent: Bool

    static let none = MumblePushToTalkInputResult(action: .none, shouldConsumeLocalEvent: false)
}

struct MumblePushToTalkInputController: Equatable, Sendable {
    private(set) var activeMode: MumblePushToTalkMode?
    private(set) var activeHotkey: MumbleHotkey?

    var localHotkey: MumbleHotkey?
    var linkedChannelsHotkey: MumbleHotkey?

    mutating func updateHotkeys(local: MumbleHotkey?, linkedChannels: MumbleHotkey?) -> MumblePushToTalkInputResult {
        localHotkey = local
        linkedChannelsHotkey = linkedChannels

        guard
            let activeHotkey,
            activeHotkey != localHotkey,
            activeHotkey != linkedChannelsHotkey
        else {
            return .none
        }

        return reset()
    }

    mutating func handle(_ event: MumbleInputEvent) -> MumblePushToTalkInputResult {
        if event.kind == .flagsChanged {
            guard
                let activeHotkey,
                activeHotkey.modifiersStillPressed(in: event.modifiers) == false
            else {
                return .none
            }

            self.activeHotkey = nil
            activeMode = nil
            return MumblePushToTalkInputResult(action: .stop, shouldConsumeLocalEvent: true)
        }

        if let (mode, hotkey) = binding(for: event), isPressEvent(event) {
            if event.kind == .keyDown && event.isRepeat {
                return MumblePushToTalkInputResult(action: .none, shouldConsumeLocalEvent: true)
            }

            guard activeMode != mode || activeHotkey != hotkey else {
                return MumblePushToTalkInputResult(action: .none, shouldConsumeLocalEvent: true)
            }

            activeMode = mode
            activeHotkey = hotkey
            return MumblePushToTalkInputResult(action: .start(mode), shouldConsumeLocalEvent: true)
        }

        guard let activeHotkey, activeHotkey.matchesRelease(event: event) else {
            return .none
        }

        self.activeHotkey = nil
        activeMode = nil

        switch event.kind {
        case .keyUp, .otherMouseUp:
            return MumblePushToTalkInputResult(action: .stop, shouldConsumeLocalEvent: true)
        default:
            return .none
        }
    }

    mutating func reset() -> MumblePushToTalkInputResult {
        guard activeHotkey != nil || activeMode != nil else {
            return .none
        }

        activeHotkey = nil
        activeMode = nil
        return MumblePushToTalkInputResult(action: .stop, shouldConsumeLocalEvent: false)
    }

    private func binding(for event: MumbleInputEvent) -> (MumblePushToTalkMode, MumbleHotkey)? {
        if let linkedChannelsHotkey, linkedChannelsHotkey.matchesPress(event: event) {
            return (.linkedChannels, linkedChannelsHotkey)
        }

        if let localHotkey, localHotkey.matchesPress(event: event) {
            return (.localChannel, localHotkey)
        }

        return nil
    }

    private func isPressEvent(_ event: MumbleInputEvent) -> Bool {
        event.kind == .keyDown || event.kind == .otherMouseDown
    }
}
