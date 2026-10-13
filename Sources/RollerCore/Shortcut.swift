import Foundation

/// A keyboard shortcut: a macOS virtual key code plus modifiers. Key codes
/// are physical key positions, so a binding keeps working when the keyboard
/// layout changes; the settings UI shows the layout's own character.
public struct Shortcut: Hashable, Codable, Comparable {
    public struct Modifiers: OptionSet, Hashable, Codable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static func < (a: Shortcut, b: Shortcut) -> Bool {
        (a.modifiers.rawValue, a.keyCode) < (b.modifiers.rawValue, b.keyCode)
    }

    /// Parses strings such as `ctrl+alt+h`, `ctrl+alt+shift+leftbracket` or
    /// `⌃⌥←`.
    public init?(string: String) {
        var s = string.trimmingCharacters(in: .whitespaces).lowercased()
        var mods: Modifiers = []
        // Symbolic modifiers written without separators.
        let symbols: [(Character, Modifiers)] = [("⌃", .control), ("⌥", .option), ("⇧", .shift), ("⌘", .command)]
        while let first = s.first, let m = symbols.first(where: { $0.0 == first }) {
            mods.insert(m.1)
            s.removeFirst()
            if s.first == "+" { s.removeFirst() }
        }
        var parts = s.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // A trailing "+" key (e.g. "ctrl++") is not supported; "plus" is.
        guard let keyName = parts.popLast(), !keyName.isEmpty else { return nil }
        for p in parts {
            switch p.trimmingCharacters(in: .whitespaces) {
            case "ctrl", "control", "⌃": mods.insert(.control)
            case "alt", "opt", "option", "⌥": mods.insert(.option)
            case "shift", "⇧": mods.insert(.shift)
            case "cmd", "command", "super", "⌘": mods.insert(.command)
            default: return nil
            }
        }
        guard let code = KeyCodes.code(forName: keyName.trimmingCharacters(in: .whitespaces)) else { return nil }
        self.keyCode = code
        self.modifiers = mods
    }

    /// Config-file form, e.g. `ctrl+alt+shift+h`.
    public var string: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(KeyCodes.name(forCode: keyCode))
        return parts.joined(separator: "+")
    }

    /// Modifier symbols in Apple's order: ⌃⌥⇧⌘.
    public var modifierSymbols: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s
    }
}

/// macOS virtual key codes (kVK_*) and their config names.
public enum KeyCodes {
    static let table: [(String, UInt32)] = [
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
        ("c", 8), ("v", 9), ("section", 10), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15),
        ("y", 16), ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22),
        ("5", 23), ("equal", 24), ("9", 25), ("7", 26), ("minus", 27), ("8", 28), ("0", 29),
        ("rightbracket", 30), ("o", 31), ("u", 32), ("leftbracket", 33), ("i", 34), ("p", 35),
        ("return", 36), ("l", 37), ("j", 38), ("quote", 39), ("k", 40), ("semicolon", 41),
        ("backslash", 42), ("comma", 43), ("slash", 44), ("n", 45), ("m", 46), ("period", 47),
        ("tab", 48), ("space", 49), ("grave", 50), ("delete", 51), ("escape", 53),
        ("f17", 64), ("keypad_decimal", 65), ("keypad_multiply", 67), ("keypad_plus", 69),
        ("keypad_clear", 71), ("keypad_divide", 75), ("keypad_enter", 76), ("keypad_minus", 78),
        ("f18", 79), ("f19", 80), ("keypad_equals", 81), ("keypad_0", 82), ("keypad_1", 83),
        ("keypad_2", 84), ("keypad_3", 85), ("keypad_4", 86), ("keypad_5", 87), ("keypad_6", 88),
        ("keypad_7", 89), ("f20", 90), ("keypad_8", 91), ("keypad_9", 92),
        ("f5", 96), ("f6", 97), ("f7", 98), ("f3", 99), ("f8", 100), ("f9", 101), ("f11", 103),
        ("f13", 105), ("f16", 106), ("f14", 107), ("f10", 109), ("f12", 111), ("f15", 113),
        ("help", 114), ("home", 115), ("pageup", 116), ("forwarddelete", 117), ("f4", 118),
        ("end", 119), ("f2", 120), ("pagedown", 121), ("f1", 122),
        ("left", 123), ("right", 124), ("down", 125), ("up", 126),
    ]

    static let aliases: [String: String] = [
        "=": "equal", "-": "minus", "[": "leftbracket", "]": "rightbracket", "'": "quote",
        ";": "semicolon", "\\": "backslash", ",": "comma", "/": "slash", ".": "period",
        "`": "grave", "enter": "return", "esc": "escape", "backspace": "delete",
        "←": "left", "→": "right", "↑": "up", "↓": "down", "plus": "equal",
        "bracketleft": "leftbracket", "bracketright": "rightbracket",
        "leftarrow": "left", "rightarrow": "right", "uparrow": "up", "downarrow": "down",
    ]

    public static func code(forName name: String) -> UInt32? {
        let n = aliases[name] ?? name
        if let hit = table.first(where: { $0.0 == n }) { return hit.1 }
        if n.hasPrefix("kc:"), let v = UInt32(n.dropFirst(3)) { return v }
        return nil
    }

    public static func name(forCode code: UInt32) -> String {
        table.first(where: { $0.1 == code })?.0 ?? "kc:\(code)"
    }

    /// A fallback label for keys whose character isn't layout dependent.
    public static func symbol(forCode code: UInt32) -> String? {
        switch code {
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "⎋"
        case 117: return "⌦"
        case 115: return "↖"
        case 119: return "↘"
        case 116: return "⇞"
        case 121: return "⇟"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default: return nil
        }
    }
}
