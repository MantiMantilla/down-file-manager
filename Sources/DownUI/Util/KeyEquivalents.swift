import AppKit
import DownCore

/// Converts between DownCore's `KeyCombo` and AppKit key equivalents / events.
enum KeyEquivalents {
    private static let named: [String: Int] = [
        "left": NSLeftArrowFunctionKey, "right": NSRightArrowFunctionKey,
        "up": NSUpArrowFunctionKey, "down": NSDownArrowFunctionKey,
        "home": NSHomeFunctionKey, "end": NSEndFunctionKey,
        "pageUp": NSPageUpFunctionKey, "pageDown": NSPageDownFunctionKey,
        "forwardDelete": NSDeleteFunctionKey,
        "f1": NSF1FunctionKey, "f2": NSF2FunctionKey, "f3": NSF3FunctionKey, "f4": NSF4FunctionKey,
        "f5": NSF5FunctionKey, "f6": NSF6FunctionKey, "f7": NSF7FunctionKey, "f8": NSF8FunctionKey,
        "f9": NSF9FunctionKey, "f10": NSF10FunctionKey, "f11": NSF11FunctionKey, "f12": NSF12FunctionKey,
    ]

    /// String for `NSMenuItem.keyEquivalent`.
    static func keyEquivalent(for combo: KeyCombo) -> String {
        if let code = named[combo.key], let scalar = UnicodeScalar(code) { return String(Character(scalar)) }
        switch combo.key {
        case "return": return "\r"
        case "delete": return String(Character(UnicodeScalar(NSBackspaceCharacter)!))
        case "tab": return "\t"
        case "escape": return "\u{1B}"
        case "space": return " "
        default: return combo.key
        }
    }

    static func modifierMask(for combo: KeyCombo) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if combo.modifiers.contains(.command) { flags.insert(.command) }
        if combo.modifiers.contains(.option) { flags.insert(.option) }
        if combo.modifiers.contains(.control) { flags.insert(.control) }
        if combo.modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }

    /// The combo an event represents (for keyDown dispatch in the file views).
    static func combo(for event: NSEvent) -> KeyCombo? {
        guard let chars = event.charactersIgnoringModifiers, let scalar = chars.unicodeScalars.first else { return nil }
        var mods: KeyModifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.shift) { mods.insert(.shift) }

        let value = Int(scalar.value)
        if let name = named.first(where: { $0.value == value })?.key { return KeyCombo(name, mods) }
        switch value {
        case 0x0D, 0x03: return KeyCombo("return", mods)
        case 0x7F, 0x08: return KeyCombo("delete", mods)
        case 0x09, 0x19: return KeyCombo("tab", mods)
        case 0x1B: return KeyCombo("escape", mods)
        case 0x20: return KeyCombo("space", mods)
        default:
            // With ⇧, charactersIgnoringModifiers keeps the shifted glyph ("N"); normalize to lowercase.
            return KeyCombo(chars.lowercased(), mods)
        }
    }
}
