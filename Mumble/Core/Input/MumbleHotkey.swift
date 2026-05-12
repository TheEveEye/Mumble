import AppKit
import Carbon.HIToolbox
import Foundation

struct MumbleHotkey: Equatable, Hashable, Sendable {
    enum Trigger: Equatable, Hashable, Sendable {
        case keyboard(keyCode: UInt16)
        case mouse(buttonNumber: Int)
        case legacyCharacter(String)
    }

    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: UInt8

        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)

        static let all: Modifiers = [.control, .option, .shift, .command]
    }

    let trigger: Trigger
    let modifiers: Modifiers
    let displayLabel: String

    var displayName: String {
        let prefixes: [(Modifiers, String)] = [
            (.control, "Ctrl"),
            (.option, "Alt"),
            (.shift, "Shift"),
            (.command, "Cmd"),
        ]

        let modifierText = prefixes
            .compactMap { modifiers.contains($0.0) ? $0.1 : nil }
            .joined(separator: "+")

        if modifierText.isEmpty {
            return displayLabel
        }

        return "\(modifierText)+\(displayLabel)"
    }

    var storageString: String {
        let encodedDisplayLabel = Self.encodeStorageComponent(displayLabel)

        switch trigger {
        case .keyboard(let keyCode):
            return "key:\(keyCode):\(modifiers.rawValue):\(encodedDisplayLabel)"
        case .mouse(let buttonNumber):
            return "mouse:\(buttonNumber):\(modifiers.rawValue):\(encodedDisplayLabel)"
        case .legacyCharacter:
            return "legacy:\(encodedDisplayLabel)"
        }
    }

    static func parse(_ value: String) -> MumbleHotkey? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return nil
        }

        if trimmedValue.hasPrefix("key:") {
            let parts = trimmedValue.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard
                parts.count == 4,
                let keyCode = UInt16(parts[1]),
                let rawModifiers = UInt8(parts[2])
            else {
                return nil
            }

            let displayLabel = decodeStorageComponent(String(parts[3])) ?? Self.keyboardDisplayLabel(keyCode: keyCode)
            return MumbleHotkey(
                trigger: .keyboard(keyCode: keyCode),
                modifiers: Modifiers(rawValue: rawModifiers),
                displayLabel: displayLabel
            )
        }

        if trimmedValue.hasPrefix("mouse:") {
            let parts = trimmedValue.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard
                parts.count == 4,
                let buttonNumber = Int(parts[1]),
                let rawModifiers = UInt8(parts[2])
            else {
                return nil
            }

            let defaultLabel = Self.mouseDisplayLabel(buttonNumber: buttonNumber)
            let displayLabel = decodeStorageComponent(String(parts[3])) ?? defaultLabel
            return MumbleHotkey(
                trigger: .mouse(buttonNumber: buttonNumber),
                modifiers: Modifiers(rawValue: rawModifiers),
                displayLabel: displayLabel
            )
        }

        if trimmedValue.hasPrefix("legacy:") {
            let encodedCharacter = String(trimmedValue.dropFirst("legacy:".count))
            guard let character = decodeStorageComponent(encodedCharacter), !character.isEmpty else {
                return nil
            }

            return MumbleHotkey(
                trigger: .legacyCharacter(character.lowercased()),
                modifiers: [],
                displayLabel: character
            )
        }

        guard let character = trimmedValue.first else {
            return nil
        }

        let label = String(character)
        return MumbleHotkey(
            trigger: .legacyCharacter(label.lowercased()),
            modifiers: [],
            displayLabel: label
        )
    }

    static func normalizedStorage(from value: String) -> String {
        parse(value)?.storageString ?? ""
    }

    static func recordingHotkey(from event: NSEvent) -> MumbleHotkey? {
        guard let inputEvent = MumbleInputEvent(event: event) else {
            return nil
        }

        return recordingHotkey(from: inputEvent)
    }

    static func recordingHotkey(from event: MumbleInputEvent) -> MumbleHotkey? {
        switch event.kind {
        case .keyDown:
            guard let keyCode = event.keyCode, !Self.isModifierOnlyKeyCode(keyCode) else {
                return nil
            }

            return MumbleHotkey(
                trigger: .keyboard(keyCode: keyCode),
                modifiers: event.modifiers,
                displayLabel: keyboardDisplayLabel(from: event)
            )
        case .otherMouseDown:
            guard let buttonNumber = event.mouseButtonNumber else {
                return nil
            }
            return MumbleHotkey(
                trigger: .mouse(buttonNumber: buttonNumber),
                modifiers: event.modifiers,
                displayLabel: mouseDisplayLabel(buttonNumber: buttonNumber)
            )
        default:
            return nil
        }
    }

    func matchesPress(event: NSEvent) -> Bool {
        guard let inputEvent = MumbleInputEvent(event: event) else {
            return false
        }

        return matchesPress(event: inputEvent)
    }

    func matchesPress(event: MumbleInputEvent) -> Bool {
        switch (trigger, event.kind) {
        case (.keyboard(let keyCode), .keyDown):
            guard let eventKeyCode = event.keyCode else {
                return false
            }

            return keyCode == eventKeyCode && modifiers == event.modifiers
        case (.mouse(let buttonNumber), .otherMouseDown):
            return buttonNumber == event.mouseButtonNumber && modifiers == event.modifiers
        case (.legacyCharacter(let character), .keyDown):
            guard event.modifiers.isEmpty else {
                return false
            }

            guard let typedCharacter = event.characters?.trimmingCharacters(in: .whitespacesAndNewlines).first else {
                return false
            }

            return String(typedCharacter).lowercased() == character
        default:
            return false
        }
    }

    func matchesRelease(event: NSEvent) -> Bool {
        guard let inputEvent = MumbleInputEvent(event: event) else {
            return false
        }

        return matchesRelease(event: inputEvent)
    }

    func matchesRelease(event: MumbleInputEvent) -> Bool {
        switch (trigger, event.kind) {
        case (.keyboard(let keyCode), .keyUp):
            guard let eventKeyCode = event.keyCode else {
                return false
            }

            return keyCode == eventKeyCode
        case (.mouse(let buttonNumber), .otherMouseUp):
            return buttonNumber == event.mouseButtonNumber
        case (.legacyCharacter(let character), .keyUp):
            guard let typedCharacter = event.characters?.trimmingCharacters(in: .whitespacesAndNewlines).first else {
                return false
            }

            return String(typedCharacter).lowercased() == character
        default:
            return false
        }
    }

    func modifiersStillPressed(in modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let currentModifiers = Modifiers(nseventFlags: modifierFlags)
        return modifiersStillPressed(in: currentModifiers)
    }

    func modifiersStillPressed(in currentModifiers: Modifiers) -> Bool {
        return currentModifiers.isSuperset(of: modifiers)
    }

    static func keyboardDisplayLabel(from event: NSEvent) -> String {
        if let specialLabel = specialKeyboardLabels[event.keyCode] {
            return specialLabel
        }

        if
            let characters = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines),
            !characters.isEmpty
        {
            return characters.uppercased()
        }

        return keyboardDisplayLabel(keyCode: event.keyCode)
    }

    static func keyboardDisplayLabel(from event: MumbleInputEvent) -> String {
        guard let keyCode = event.keyCode else {
            return "Key"
        }

        if let specialLabel = specialKeyboardLabels[keyCode] {
            return specialLabel
        }

        if let characters = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines),
           !characters.isEmpty
        {
            return characters.uppercased()
        }

        return keyboardDisplayLabel(keyCode: keyCode)
    }

    static func keyboardDisplayLabel(keyCode: UInt16) -> String {
        specialKeyboardLabels[keyCode] ?? "Key \(keyCode)"
    }

    static func mouseDisplayLabel(buttonNumber: Int) -> String {
        "Mouse\(buttonNumber + 1)"
    }

    private static func encodeStorageComponent(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private static func decodeStorageComponent(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private static func isModifierOnlyKeyCode(_ keyCode: UInt16) -> Bool {
        modifierOnlyKeyCodes.contains(keyCode)
    }

    private static let modifierOnlyKeyCodes: Set<UInt16> = [
        UInt16(kVK_Command),
        UInt16(kVK_RightCommand),
        UInt16(kVK_Shift),
        UInt16(kVK_RightShift),
        UInt16(kVK_Option),
        UInt16(kVK_RightOption),
        UInt16(kVK_Control),
        UInt16(kVK_RightControl),
        UInt16(kVK_CapsLock),
        UInt16(kVK_Function),
    ]

    private static let specialKeyboardLabels: [UInt16: String] = [
        UInt16(kVK_Return): "Return",
        UInt16(kVK_Tab): "Tab",
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Delete): "Backspace",
        UInt16(kVK_Escape): "Esc",
        UInt16(kVK_LeftArrow): "Left",
        UInt16(kVK_RightArrow): "Right",
        UInt16(kVK_UpArrow): "Up",
        UInt16(kVK_DownArrow): "Down",
        UInt16(kVK_ForwardDelete): "Delete",
        UInt16(kVK_Help): "Help",
        UInt16(kVK_Home): "Home",
        UInt16(kVK_End): "End",
        UInt16(kVK_PageUp): "Page Up",
        UInt16(kVK_PageDown): "Page Down",
        UInt16(kVK_F1): "F1",
        UInt16(kVK_F2): "F2",
        UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5",
        UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7",
        UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10",
        UInt16(kVK_F11): "F11",
        UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13",
        UInt16(kVK_F14): "F14",
        UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16",
        UInt16(kVK_F17): "F17",
        UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19",
        UInt16(kVK_F20): "F20",
    ]
}
