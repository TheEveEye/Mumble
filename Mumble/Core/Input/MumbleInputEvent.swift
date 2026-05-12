import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct MumbleInputEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case keyDown
        case keyUp
        case flagsChanged
        case otherMouseDown
        case otherMouseUp
    }

    let kind: Kind
    let keyCode: UInt16?
    let mouseButtonNumber: Int?
    let modifiers: MumbleHotkey.Modifiers
    let characters: String?
    let charactersIgnoringModifiers: String?
    let isRepeat: Bool

    init(
        kind: Kind,
        keyCode: UInt16? = nil,
        mouseButtonNumber: Int? = nil,
        modifiers: MumbleHotkey.Modifiers = [],
        characters: String? = nil,
        charactersIgnoringModifiers: String? = nil,
        isRepeat: Bool = false
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.mouseButtonNumber = mouseButtonNumber
        self.modifiers = modifiers
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.isRepeat = isRepeat
    }

    init?(event: NSEvent) {
        let modifiers = MumbleHotkey.Modifiers(nseventFlags: event.modifierFlags)

        switch event.type {
        case .keyDown:
            self.init(
                kind: .keyDown,
                keyCode: event.keyCode,
                modifiers: modifiers,
                characters: event.characters,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                isRepeat: event.isARepeat
            )
        case .keyUp:
            self.init(
                kind: .keyUp,
                keyCode: event.keyCode,
                modifiers: modifiers,
                characters: event.characters,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            )
        case .flagsChanged:
            self.init(kind: .flagsChanged, keyCode: event.keyCode, modifiers: modifiers)
        case .otherMouseDown:
            self.init(kind: .otherMouseDown, mouseButtonNumber: Int(event.buttonNumber), modifiers: modifiers)
        case .otherMouseUp:
            self.init(kind: .otherMouseUp, mouseButtonNumber: Int(event.buttonNumber), modifiers: modifiers)
        case .systemDefined:
            guard let keyboardEvent = Self.systemDefinedKeyboardEvent(from: event) else {
                return nil
            }

            self.init(
                kind: keyboardEvent.isKeyDown ? .keyDown : .keyUp,
                keyCode: keyboardEvent.keyCode,
                modifiers: modifiers,
                charactersIgnoringModifiers: MumbleHotkey.keyboardDisplayLabel(keyCode: keyboardEvent.keyCode)
            )
        default:
            return nil
        }
    }

    init?(cgEvent: CGEvent, type: CGEventType) {
        let modifiers = MumbleHotkey.Modifiers(cgEventFlags: cgEvent.flags)

        switch type {
        case .keyDown:
            let keyCode = UInt16(cgEvent.getIntegerValueField(.keyboardEventKeycode))
            self.init(
                kind: .keyDown,
                keyCode: keyCode,
                modifiers: modifiers,
                characters: Self.characters(for: keyCode, flags: cgEvent.flags),
                charactersIgnoringModifiers: Self.characters(for: keyCode, flags: []),
                isRepeat: cgEvent.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
        case .keyUp:
            let keyCode = UInt16(cgEvent.getIntegerValueField(.keyboardEventKeycode))
            self.init(
                kind: .keyUp,
                keyCode: keyCode,
                modifiers: modifiers,
                characters: Self.characters(for: keyCode, flags: cgEvent.flags),
                charactersIgnoringModifiers: Self.characters(for: keyCode, flags: [])
            )
        case .flagsChanged:
            self.init(
                kind: .flagsChanged,
                keyCode: UInt16(cgEvent.getIntegerValueField(.keyboardEventKeycode)),
                modifiers: modifiers
            )
        case .otherMouseDown:
            self.init(
                kind: .otherMouseDown,
                mouseButtonNumber: Int(cgEvent.getIntegerValueField(.mouseEventButtonNumber)),
                modifiers: modifiers
            )
        case .otherMouseUp:
            self.init(
                kind: .otherMouseUp,
                mouseButtonNumber: Int(cgEvent.getIntegerValueField(.mouseEventButtonNumber)),
                modifiers: modifiers
            )
        default:
            return nil
        }
    }

    private static func systemDefinedKeyboardEvent(from event: NSEvent) -> (keyCode: UInt16, isKeyDown: Bool)? {
        let supportedSubtypes: Set<Int16> = [8, 14]
        guard supportedSubtypes.contains(event.subtype.rawValue) else {
            return nil
        }

        let data1 = UInt32(bitPattern: Int32(event.data1))
        let keyCode = UInt16((data1 & 0xFFFF0000) >> 16)
        let lowWord = UInt16(data1 & 0x0000FFFF)
        let stateFromHighByte = UInt8((lowWord & 0xFF00) >> 8)
        let stateFromLowByte = UInt8(lowWord & 0x00FF)
        let state: UInt8

        if stateFromHighByte == 0xA || stateFromHighByte == 0xB {
            state = stateFromHighByte
        } else {
            state = stateFromLowByte
        }

        switch state {
        case 0xA:
            return (keyCode, true)
        case 0xB:
            return (keyCode, false)
        default:
            return nil
        }
    }

    private static func characters(for keyCode: UInt16, flags: CGEventFlags) -> String? {
        guard
            let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }

        let keyboardLayout = unsafeBitCast(layoutData, to: CFData.self)
        let keyboardLayoutPointer = CFDataGetBytePtr(keyboardLayout).withMemoryRebound(
            to: UCKeyboardLayout.self,
            capacity: 1
        ) { $0 }

        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        let modifierKeyState = UInt32(flags.carbonModifierState >> 8) & 0xFF
        let status = UCKeyTranslate(
            keyboardLayoutPointer,
            keyCode,
            UInt16(kUCKeyActionDown),
            modifierKeyState,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else {
            return nil
        }

        return String(utf16CodeUnits: chars, count: length)
    }
}

extension MumbleHotkey.Modifiers {
    init(nseventFlags: NSEvent.ModifierFlags) {
        let normalizedFlags = nseventFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Self = []

        if normalizedFlags.contains(.control) {
            modifiers.insert(.control)
        }
        if normalizedFlags.contains(.option) {
            modifiers.insert(.option)
        }
        if normalizedFlags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if normalizedFlags.contains(.command) {
            modifiers.insert(.command)
        }

        self = modifiers
    }

    init(cgEventFlags: CGEventFlags) {
        var modifiers: Self = []

        if cgEventFlags.contains(.maskControl) {
            modifiers.insert(.control)
        }
        if cgEventFlags.contains(.maskAlternate) {
            modifiers.insert(.option)
        }
        if cgEventFlags.contains(.maskShift) {
            modifiers.insert(.shift)
        }
        if cgEventFlags.contains(.maskCommand) {
            modifiers.insert(.command)
        }

        self = modifiers
    }
}

private extension CGEventFlags {
    var carbonModifierState: Int {
        var modifierState = 0

        if contains(.maskShift) {
            modifierState |= shiftKey
        }
        if contains(.maskControl) {
            modifierState |= controlKey
        }
        if contains(.maskAlternate) {
            modifierState |= optionKey
        }
        if contains(.maskCommand) {
            modifierState |= cmdKey
        }

        return modifierState
    }
}
