import AppKit
import Foundation

/// Modifier keys for a shortcut. Display order is Control, Option, Shift, Command.
public struct ShortcutModifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let shift = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)

    public var names: [String] {
        var out: [String] = []
        if contains(.control) { out.append("control") }
        if contains(.option) { out.append("option") }
        if contains(.shift) { out.append("shift") }
        if contains(.command) { out.append("command") }
        return out
    }

    public static func fromNames(_ names: [String]) -> ShortcutModifiers {
        var result: ShortcutModifiers = []
        for name in names {
            switch name.lowercased() {
            case "control", "ctrl": result.insert(.control)
            case "option", "opt", "alt": result.insert(.option)
            case "shift": result.insert(.shift)
            case "command", "cmd": result.insert(.command)
            default: break
            }
        }
        return result
    }

    public var eventModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.command) { flags.insert(.command) }
        return flags
    }

    public static func from(eventFlags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        var result: ShortcutModifiers = []
        if eventFlags.contains(.control) { result.insert(.control) }
        if eventFlags.contains(.option) { result.insert(.option) }
        if eventFlags.contains(.shift) { result.insert(.shift) }
        if eventFlags.contains(.command) { result.insert(.command) }
        return result
    }

    /// Carbon modifier bits for RegisterEventHotKey.
    public var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if contains(.command) { value |= 0x0100 } // cmdKey
        if contains(.shift) { value |= 0x0200 } // shiftKey
        if contains(.option) { value |= 0x0800 } // optionKey
        if contains(.control) { value |= 0x1000 } // controlKey
        return value
    }
}

/// One keyboard shortcut: a key plus modifiers.
/// `key` is the AppKit key-equivalent string (single character or a special token
/// such as "space", "tab", "return", "escape", "left", "f12").
public struct KeyboardShortcut: Hashable, Sendable, Codable, CustomStringConvertible {
    public var key: String
    public var modifiers: ShortcutModifiers

    public init(key: String, modifiers: ShortcutModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public static func cmd(_ key: String) -> KeyboardShortcut { KeyboardShortcut(key: key, modifiers: [.command]) }
    public static func cmdShift(_ key: String) -> KeyboardShortcut { KeyboardShortcut(key: key, modifiers: [.command, .shift]) }
    public static func cmdOpt(_ key: String) -> KeyboardShortcut { KeyboardShortcut(key: key, modifiers: [.command, .option]) }
    public static func ctrl(_ key: String) -> KeyboardShortcut { KeyboardShortcut(key: key, modifiers: [.control]) }
    public static func ctrlShift(_ key: String) -> KeyboardShortcut { KeyboardShortcut(key: key, modifiers: [.control, .shift]) }

    /// Short display such as `Cmd+Shift+T`. Used in docs and dump output.
    /// Doc order matches `docs/re/menus-and-hotkeys.md`: Cmd, Ctrl, Opt, Shift.
    public var display: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("Cmd") }
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Opt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        parts.append(Self.displayKey(key))
        return parts.joined(separator: "+")
    }

    /// Symbol display such as `⇧⌘T` (macOS order Control, Option, Shift, Command).
    public var symbolDisplay: String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        value += Self.displayKey(key)
        return value
    }

    public var description: String { display }

    public static func displayKey(_ key: String) -> String {
        switch key {
        case " ": return "Space"
        case "\t": return "Tab"
        case "\r", "\n": return "Return"
        case "\u{1B}", "escape", "esc": return "Esc"
        case "\u{F702}": return "Left"
        case "\u{F703}": return "Right"
        case "\u{F700}": return "Up"
        case "\u{F701}": return "Down"
        default:
            if key.count == 1 { return key.uppercased() }
            // Capitalize tokens such as "space", "f12".
            if key.hasPrefix("f"), key.dropFirst().allSatisfy(\.isNumber) { return key.uppercased() }
            return key.prefix(1).uppercased() + key.dropFirst()
        }
    }

    /// AppKit key-equivalent string for NSMenuItem.
    public var keyEquivalent: String {
        switch key {
        case "space": return " "
        case "tab": return "\t"
        case "return": return "\r"
        case "escape", "esc": return "\u{1B}"
        case "left": return "\u{F702}"
        case "right": return "\u{F703}"
        case "up": return "\u{F700}"
        case "down": return "\u{F701}"
        case "delete": return "\u{7F}"
        default:
            if key.hasPrefix("f"),let number=Int(key.dropFirst()),(1...35).contains(number),let scalar=UnicodeScalar(0xF704+number-1) {return String(scalar)}
            // AppKit matches the shifted letter's case even when Shift is
            // also present in keyEquivalentModifierMask (for example Redo).
            if key.count == 1 { return modifiers.contains(.shift) ? key.uppercased() : key.lowercased() }
            return key
        }
    }

    public var keyEquivalentModifierMask: NSEvent.ModifierFlags { modifiers.eventModifierFlags }

    /// Virtual key code for Carbon RegisterEventHotKey. Nil when the key has no code here.
    public var carbonKeyCode: UInt32? { Self.carbonKeyCodes[key.lowercased()] }

    public static let carbonKeyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, "n": 45, "m": 46, ",": 43, ".": 47, "/": 44, ";": 41, "'": 39, "\\": 42, "`": 50, "return": 36, "tab": 48,
        "space": 49, "delete": 51, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    /// Shifted glyphs of the US layout and their base keys. One convention everywhere: a shortcut
    /// names the base key and carries Shift in `modifiers` (Cmd+Shift+2, not Cmd+"@"), as macOS
    /// menus display it ("⇧⌘2"). Used for events whose layout lookup fails and for stored data.
    public static let shiftedBaseKeys: [String: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// The base-key form: a shifted glyph with Shift becomes its base key ("@" + Shift → "2" + Shift).
    public var normalized: KeyboardShortcut {
        guard modifiers.contains(.shift), let base = Self.shiftedBaseKeys[key] else { return self }
        return KeyboardShortcut(key: base, modifiers: modifiers)
    }

    /// Builds a shortcut from an NSEvent, for routing and recording. Returns nil for bare modifier presses.
    public static func from(event: NSEvent) -> KeyboardShortcut? {
        guard event.type == .keyDown else { return nil }
        let mods = ShortcutModifiers.from(eventFlags: event.modifierFlags)
        var raw = event.charactersIgnoringModifiers ?? ""
        // AppKit keeps Shift in charactersIgnoringModifiers (Shift+2 gives "@"). Ask the keyboard
        // layout for the unshifted key so the shortcut names the base key, with Shift in `mods`.
        // Letters keep their Command-layout character and only fold case below.
        if mods.contains(.shift), !raw.contains(where: \.isLetter), let base = event.characters(byApplyingModifiers: []), base.count == 1,
           !base.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            raw = base
        }
        var key = raw
        switch event.keyCode {
        case 49: key = "space"
        case 48: key = "tab"
        case 36: key = "return"
        case 53: key = "escape"
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        case 111: key = "f12"
        default:
            if raw.count == 1, let scalar = raw.unicodeScalars.first {
                switch scalar.value {
                case 0xF702: key = "left"
                case 0xF703: key = "right"
                case 0xF700: key = "up"
                case 0xF701: key = "down"
                case 0xF704...0xF726: key = "f\(scalar.value - 0xF704 + 1)"
                default: key = raw.lowercased()
                }
            } else if raw.isEmpty {
                return nil
            } else {
                key = raw.lowercased()
            }
        }
        // Shift+letter: keep the base letter; shift lives in modifiers.
        if key.count == 1 { key = key.lowercased() }
        return KeyboardShortcut(key: key, modifiers: mods).normalized
    }

    // Codable through key + modifier names so override files stay readable.
    private enum CodingKeys: String, CodingKey { case key, modifiers }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        let names = try container.decodeIfPresent([String].self, forKey: .modifiers) ?? []
        modifiers = ShortcutModifiers.fromNames(names)
        // Recordings saved before the base-key convention hold the shifted glyph ("@" + Shift).
        key = normalized.key
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(modifiers.names, forKey: .modifiers)
    }
}
