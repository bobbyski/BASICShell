import Foundation

/// A key the console turns into its own escape sequence rather than leaving to
/// SwiftTerm: the keys INKEY$ and a line input's exit keys care about.
enum ConsoleSpecialKey: Equatable {
    case up, down, right, left
    case home, end, insert, forwardDelete, pageUp, pageDown
    /// F1 to F22; F23 and above have no sequence.
    case function(Int)
    case returnKey
}

/// The modifiers that change a console key's sequence. Control is here only
/// for ^C and ^I, which the console handles itself; it never changes a
/// special key's sequence, on the Mac or on iOS.
struct ConsoleKeyModifiers: OptionSet, Equatable {
    let rawValue: Int
    static let shift = ConsoleKeyModifiers(rawValue: 1 << 0)
    static let option = ConsoleKeyModifiers(rawValue: 1 << 1)
    static let command = ConsoleKeyModifiers(rawValue: 1 << 2)
    static let control = ConsoleKeyModifiers(rawValue: 1 << 3)
}

/// One key press from a hardware keyboard, as the console needs to see it —
/// the same whether it came from AppKit's `NSEvent` or UIKit's `UIKey`, so a
/// BASIC program reads the same INKEY$ on a Mac and an iPad.
struct ConsoleKeyPress: Equatable {
    /// The key, when it is one the console encodes itself.
    var special: ConsoleSpecialKey?
    /// The characters with no modifiers applied, as the platform reports them.
    var charactersIgnoringModifiers: String
    var modifiers: ConsoleKeyModifiers

    /// ^C: stop a running program, where the program has not taken the key.
    var isInterrupt: Bool {
        modifiers.contains(.control) && charactersIgnoringModifiers.lowercased() == "c"
    }

    /// ^I: toggle the console's overwrite mode, outside INKEY$ capture.
    var isOverwriteToggle: Bool {
        modifiers.contains(.control) && charactersIgnoringModifiers.lowercased() == "i"
    }

    /// The sequence a program reads for this press, or nil when the press is
    /// ordinary typing that the terminal's own bytes already carry.
    ///
    /// Arrows and the editing keys are CSI sequences, F1–F4 SS3, the rest of
    /// the function keys `CSI n ~`, each with xterm's modifier parameter when
    /// a modifier is held. Shift+Return is `CSI ! M`, and Option (or
    /// Shift+Option) with a printable character is `CSI # c` (`CSI ! # c`) —
    /// keys an ordinary terminal byte stream cannot tell apart.
    var rawSequence: String? {
        let escape = "\u{1B}"

        if special == .returnKey {
            return modifiers.contains(.shift) ? "\(escape)[!M" : nil
        }

        let modifier = Self.modifierParameter(for: modifiers)

        guard let special else {
            return Self.modifiedPrintableCharacter(charactersIgnoringModifiers, modifier: modifier)
                .map { "\(escape)[\($0)" }
        }

        func csi(_ base: String, final: String) -> String {
            if let modifier {
                return "\(escape)[\(base);\(modifier)\(final)"
            }
            return "\(escape)[\(base)\(final)"
        }

        func csiFinal(_ final: String) -> String {
            if let modifier {
                return "\(escape)[1;\(modifier)\(final)"
            }
            return "\(escape)[\(final)"
        }

        func ss3OrCsi(_ final: String) -> String {
            if let modifier {
                return "\(escape)[1;\(modifier)\(final)"
            }
            return "\(escape)O\(final)"
        }

        switch special {
        case .up: return csiFinal("A")
        case .down: return csiFinal("B")
        case .right: return csiFinal("C")
        case .left: return csiFinal("D")
        case .home: return csiFinal("H")
        case .end: return csiFinal("F")
        case .insert: return csi("2", final: "~")
        case .forwardDelete: return csi("3", final: "~")
        case .pageUp: return csi("5", final: "~")
        case .pageDown: return csi("6", final: "~")
        case .function(1): return ss3OrCsi("P")
        case .function(2): return ss3OrCsi("Q")
        case .function(3): return ss3OrCsi("R")
        case .function(4): return ss3OrCsi("S")
        case .function(let number):
            guard let code = Self.functionKeyCodes[number] else { return nil }
            return csi(code, final: "~")
        case .returnKey:
            return nil
        }
    }

    /// F5 to F22 as `CSI n ~`: the numbers skip where the VT220's did.
    private static let functionKeyCodes: [Int: String] = [
        5: "15", 6: "17", 7: "18", 8: "19", 9: "20", 10: "21", 11: "23", 12: "24",
        13: "25", 14: "26", 15: "28", 16: "29", 17: "31", 18: "32", 19: "33", 20: "34",
        21: "35", 22: "36",
    ]

    /// xterm's modifier parameter for Shift, Option (Alt) and Command (Meta).
    static func modifierParameter(for modifiers: ConsoleKeyModifiers) -> Int? {
        switch (modifiers.contains(.shift), modifiers.contains(.option), modifiers.contains(.command)) {
        case (false, false, false): return nil
        case (true, false, false): return 2
        case (false, true, false): return 3
        case (true, true, false): return 4
        case (false, false, true): return 9
        case (true, false, true): return 10
        case (false, true, true): return 11
        case (true, true, true): return 12
        }
    }

    private static func modifiedPrintableCharacter(_ characters: String, modifier: Int?) -> String? {
        guard let modifier,
              characters.count == 1,
              let character = characters.first,
              character.unicodeScalars.allSatisfy({ (32...126).contains(Int($0.value)) })
        else {
            return nil
        }

        switch modifier {
        case 3: return "#\(character)"
        case 4: return "!#\(character)"
        default: return nil
        }
    }
}
