import Carbon.HIToolbox
import AppKit
import CoreGraphics
import Testing
@testable import Mumble

struct MumbleHotkeyTests {
    @Test
    func keyboardHotkeyRoundTripsWithModifiers() {
        let hotkey = MumbleHotkey(
            trigger: .keyboard(keyCode: UInt16(kVK_ANSI_P)),
            modifiers: [.control],
            displayLabel: "P"
        )

        let parsedHotkey = MumbleHotkey.parse(hotkey.storageString)

        #expect(parsedHotkey == hotkey)
        #expect(parsedHotkey?.displayName == "Ctrl+P")
    }

    @Test
    func mouseHotkeyRoundTrips() {
        let hotkey = MumbleHotkey(
            trigger: .mouse(buttonNumber: 3),
            modifiers: [],
            displayLabel: "Mouse4"
        )

        let parsedHotkey = MumbleHotkey.parse(hotkey.storageString)

        #expect(parsedHotkey == hotkey)
        #expect(parsedHotkey?.displayName == "Mouse4")
    }

    @Test
    func functionKeyDisplayNameIncludesModifiers() {
        let hotkey = MumbleHotkey(
            trigger: .keyboard(keyCode: UInt16(kVK_F13)),
            modifiers: [.shift, .command],
            displayLabel: "F13"
        )

        #expect(hotkey.displayName == "Shift+Cmd+F13")
    }

    @Test
    func legacyCharacterHotkeyStillParses() {
        let hotkey = MumbleHotkey.parse("#")

        #expect(hotkey?.displayName == "#")
        #expect(hotkey?.storageString == "legacy:Iw==")
    }

    @Test
    func inputEventMapsNSEventKeyboardPress() throws {
        let nsEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: true,
            keyCode: UInt16(kVK_ANSI_P)
        ))

        let inputEvent = try #require(MumbleInputEvent(event: nsEvent))

        #expect(inputEvent.kind == .keyDown)
        #expect(inputEvent.keyCode == UInt16(kVK_ANSI_P))
        #expect(inputEvent.modifiers == [.control])
        #expect(inputEvent.characters == "p")
        #expect(inputEvent.isRepeat)
    }

    @Test
    func inputEventMapsCGEventMouseButton() throws {
        let cgEvent = try #require(CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .center
        ))
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        cgEvent.flags = [.maskControl, .maskAlternate]

        let inputEvent = try #require(MumbleInputEvent(cgEvent: cgEvent, type: .otherMouseDown))

        #expect(inputEvent.kind == .otherMouseDown)
        #expect(inputEvent.mouseButtonNumber == 3)
        #expect(inputEvent.modifiers == [.control, .option])
    }

    @Test
    func keyboardHotkeyMatchesPressReleaseAndIgnoresRepeatsInController() {
        let hotkey = MumbleHotkey(
            trigger: .keyboard(keyCode: UInt16(kVK_ANSI_P)),
            modifiers: [.control],
            displayLabel: "P"
        )
        var controller = MumblePushToTalkInputController()
        _ = controller.updateHotkeys(local: hotkey, linkedChannels: nil)

        let press = MumbleInputEvent(kind: .keyDown, keyCode: UInt16(kVK_ANSI_P), modifiers: [.control])
        let repeatPress = MumbleInputEvent(
            kind: .keyDown,
            keyCode: UInt16(kVK_ANSI_P),
            modifiers: [.control],
            isRepeat: true
        )
        let release = MumbleInputEvent(kind: .keyUp, keyCode: UInt16(kVK_ANSI_P), modifiers: [.control])

        #expect(controller.handle(press).action == .start(.localChannel))
        #expect(controller.handle(repeatPress).action == .none)
        #expect(controller.handle(release).action == .stop)
    }

    @Test
    func mouseHotkeyMatchesPressReleaseInController() {
        let hotkey = MumbleHotkey(trigger: .mouse(buttonNumber: 3), modifiers: [], displayLabel: "Mouse4")
        var controller = MumblePushToTalkInputController()
        _ = controller.updateHotkeys(local: hotkey, linkedChannels: nil)

        #expect(controller.handle(MumbleInputEvent(kind: .otherMouseDown, mouseButtonNumber: 3)).action == .start(.localChannel))
        #expect(controller.handle(MumbleInputEvent(kind: .otherMouseUp, mouseButtonNumber: 3)).action == .stop)
    }

    @Test
    func releasingRequiredModifierStopsPushToTalk() {
        let hotkey = MumbleHotkey(
            trigger: .keyboard(keyCode: UInt16(kVK_ANSI_P)),
            modifiers: [.control],
            displayLabel: "P"
        )
        var controller = MumblePushToTalkInputController()
        _ = controller.updateHotkeys(local: hotkey, linkedChannels: nil)

        _ = controller.handle(MumbleInputEvent(kind: .keyDown, keyCode: UInt16(kVK_ANSI_P), modifiers: [.control]))

        #expect(controller.handle(MumbleInputEvent(kind: .flagsChanged, modifiers: [])).action == .stop)
    }

    @Test
    func linkedChannelHotkeyTakesPriorityOverLocalHotkey() {
        let sharedHotkey = MumbleHotkey(
            trigger: .keyboard(keyCode: UInt16(kVK_ANSI_P)),
            modifiers: [],
            displayLabel: "P"
        )
        var controller = MumblePushToTalkInputController()
        _ = controller.updateHotkeys(local: sharedHotkey, linkedChannels: sharedHotkey)

        let result = controller.handle(MumbleInputEvent(kind: .keyDown, keyCode: UInt16(kVK_ANSI_P)))

        #expect(result.action == .start(.linkedChannels))
    }

    @Test
    func legacyCharacterHotkeyMatchesInputEventCharacters() {
        let hotkey = MumbleHotkey.parse("#")
        let press = MumbleInputEvent(kind: .keyDown, characters: "#")
        let release = MumbleInputEvent(kind: .keyUp, characters: "#")

        #expect(hotkey?.matchesPress(event: press) == true)
        #expect(hotkey?.matchesRelease(event: release) == true)
    }
}
