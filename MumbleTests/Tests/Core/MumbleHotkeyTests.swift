import Carbon.HIToolbox
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
}
