import Foundation

/// The names KEYDOWN knows keys by, and what each spelling of a key means.
///
/// A program can name a key the way it reads one: `KEYDOWN("LEFT")`,
/// `KEYDOWN("[K")` (what INKEY$ returns for it), `KEYDOWN(CHR$(0) + "K")`
/// under `OPTION IBM-KEYS`, or `KEYDOWN("A")` (either case). Every spelling
/// comes down to one canonical name, which is what hosts are asked about:
///
/// | Keys | Names |
/// |---|---|
/// | Arrows | `LEFT`, `RIGHT`, `UP`, `DOWN` |
/// | Editing | `SPACE`, `ENTER`, `TAB`, `ESCAPE`, `BACKSPACE`, `DELETE`, `INSERT` |
/// | Navigation | `HOME`, `END`, `PAGEUP`, `PAGEDOWN` |
/// | Modifiers | `SHIFT`, `CONTROL`, `OPTION`, `COMMAND` |
/// | Function keys | `F1` … `F24` |
/// | Letters, digits, punctuation | the character, letters in uppercase |
public enum BASICKeyName {
    /// The canonical name of `key`, or nil when it names no key.
    public static func canonical(_ key: String) -> String? {
        guard !key.isEmpty else { return nil }
        if key.count == 1 {
            return single(key)
        }
        // INKEY$'s own form, `[` + modifiers + code: `[K`, `[!M`, `[F5`.
        if key.first == "[" {
            return fromINKEY(String(key.dropFirst()).drop { "!$#".contains($0) })
        }
        // The IBM form, CHR$(0) + scan code.
        if key.unicodeScalars.first == "\u{0}", key.unicodeScalars.count == 2,
           let code = key.unicodeScalars.last?.value {
            return fromIBM(Int(code))
        }
        // A raw escape sequence, as a terminal sends an arrow.
        if key.first == "\u{1B}" {
            let normalized = BASICKeyNormalizer.normalize(key, encoding: .aibasic)
            return normalized == key ? nil : canonical(normalized)
        }
        return named(key)
    }

    private static func single(_ key: String) -> String? {
        switch key {
        case " ": return "SPACE"
        case "\r", "\n": return "ENTER"
        case "\t": return "TAB"
        case "\u{1B}": return "ESCAPE"
        case "\u{8}", "\u{7F}": return "BACKSPACE"
        default:
            guard let scalar = key.unicodeScalars.first, scalar.value >= 32 else { return nil }
            return key.uppercased()
        }
    }

    private static func fromINKEY(_ code: Substring) -> String? {
        if code.first == "F", let number = Int(code.dropFirst()), (1...24).contains(number) {
            return "F\(number)"
        }
        guard code.count == 1, let scalar = code.unicodeScalars.first else { return nil }
        if code == "T" { return "TAB" }
        return fromIBM(Int(scalar.value))
    }

    private static func fromIBM(_ code: Int) -> String? {
        switch code {
        case 71: return "HOME"
        case 72: return "UP"
        case 73: return "PAGEUP"
        case 75: return "LEFT"
        case 77: return "RIGHT"
        case 79: return "END"
        case 80: return "DOWN"
        case 81: return "PAGEDOWN"
        case 82: return "INSERT"
        case 83: return "DELETE"
        case 59...68: return "F\(code - 58)"
        case 133: return "F11"
        case 134: return "F12"
        default: return nil
        }
    }

    private static let names: [String: String] = [
        "LEFT": "LEFT", "RIGHT": "RIGHT", "UP": "UP", "DOWN": "DOWN",
        "SPACE": "SPACE", "ENTER": "ENTER", "RETURN": "ENTER", "TAB": "TAB",
        "ESC": "ESCAPE", "ESCAPE": "ESCAPE", "BACKSPACE": "BACKSPACE",
        "DELETE": "DELETE", "DEL": "DELETE", "INSERT": "INSERT",
        "HOME": "HOME", "END": "END", "PAGEUP": "PAGEUP", "PAGEDOWN": "PAGEDOWN",
        "SHIFT": "SHIFT", "CONTROL": "CONTROL", "CTRL": "CONTROL",
        "OPTION": "OPTION", "ALT": "OPTION", "COMMAND": "COMMAND", "CMD": "COMMAND",
    ]

    private static func named(_ key: String) -> String? {
        let word = key.uppercased().filter { $0 != " " && $0 != "_" && $0 != "-" }
        if let name = names[word] { return name }
        if word.first == "F", let number = Int(word.dropFirst()), (1...24).contains(number) {
            return "F\(number)"
        }
        return nil
    }
}

/// Host capability for KEYDOWN: whether a key is held right now.
///
/// A host that sees keys go down and come up (Studio's console, on the Mac
/// and on an iPad keyboard) answers from that. A terminal never sees a key
/// come up, so a terminal host does not adopt this, and KEYDOWN falls back on
/// ``BASICHeldKeyEstimate``.
public protocol BASICKeyStateHost: BASICHost {
    /// Whether the key with the canonical name `name` is held, or nil when
    /// this host cannot tell.
    func isKeyDown(_ name: String) -> Bool?
}

/// KEYDOWN's answer where the host cannot say: a key counts as held while
/// INKEY$ keeps seeing it.
///
/// A held key reaches a terminal as one press, a pause, then a stream of
/// repeats. So a key seen once counts as held for half a second, long enough
/// to bridge the pause before the repeats, and a key that is repeating
/// counts as held until its repeats have stopped for a moment. It lags a
/// release by that moment, and a single tap reads as a short hold; a host
/// that sees key-up does better.
public struct BASICHeldKeyEstimate: Sendable {
    /// How long one press counts as held: past a terminal's repeat delay.
    public static let pressWindow: TimeInterval = 0.5
    /// How long a repeating key counts as held after its last repeat.
    public static let repeatWindow: TimeInterval = 0.15

    private var lastSeen: [String: TimeInterval] = [:]
    private var repeating: Set<String> = []

    public init() {}

    /// Notes that INKEY$ returned `name` at `time`.
    public mutating func saw(_ name: String, at time: TimeInterval) {
        if let previous = lastSeen[name], time - previous <= Self.pressWindow {
            repeating.insert(name)
        } else {
            repeating.remove(name)
        }
        lastSeen[name] = time
    }

    /// Whether `name` counts as held at `time`.
    public func isDown(_ name: String, at time: TimeInterval) -> Bool {
        guard let seen = lastSeen[name] else { return false }
        let window = repeating.contains(name) ? Self.repeatWindow : Self.pressWindow
        return time - seen <= window
    }
}
