//
//  ProgramOutline.swift
//  BASICStudio
//
//  The functions and classes in a program, for the editor's ribbon to list
//  and jump to. No UI framework here; EditorRibbonAUI draws it.
//

import Foundation

/// The declarations in a BASIC program, in the order they are written: its
/// FUNCTIONs, and its CLASSes, INTERFACEs, TYPEs and RECORDs with the
/// functions inside them, and the MARK comments that group them.
///
/// ```text
///   ' MARK: - Drawing                ─────────────
///                                    Drawing               line 10
///   FUNCTION Main() AS VOID          Main                  line 12
///   CLASS Report                     Report                line 40
///       FUNCTION Title() AS STRING     Report.Title        line 43
///   END CLASS
///   DEF FNArea(r) = PI * r * r       FNArea                line 60
/// ```
///
/// A MARK comment names a group, as Xcode's `// MARK:` does. A `-` before
/// the name draws a line above it in the jump list, a `-` after it a line
/// below, and `' MARK: -` alone is just a line.
///
/// It reads lines, not a parse, so a program halfway through being typed,
/// with a syntax error in it, still has an outline: the jump list is most
/// useful exactly then.
struct ProgramOutline: Equatable {
    enum Kind: Equatable {
        case function
        case `class`
        case interface
        case type
        /// A `' MARK:` comment: a group's name.
        case mark
    }

    struct Entry: Equatable {
        let kind: Kind
        /// As declared: `Main`, `Num$`, `FNArea`.
        let name: String
        /// The class, interface or type it is declared in, if any.
        let container: String?
        /// 1-based, as the editor counts.
        let line: Int
        /// The line its END is on, or the last line of the program when it
        /// has none yet; a one-line DEF FN and a MARK end where they start.
        let endLine: Int
        /// A MARK's `-` before its name: a line above it in the list.
        var separatorBefore = false
        /// A MARK's `-` after its name: a line below it.
        var separatorAfter = false

        /// How the jump list names it: `Report.Title` inside a class.
        var title: String {
            container.map { "\($0).\(name)" } ?? name
        }
    }

    let entries: [Entry]

    init(_ text: String) {
        entries = Self.scan(text)
    }

    /// The innermost declaration `line` is in: a method before its class.
    /// A MARK holds nothing.
    func entry(containing line: Int) -> Entry? {
        entries
            .filter { $0.kind != .mark && $0.line <= line && line <= $0.endLine }
            .max { $0.line < $1.line }
    }

    // MARK: - Reading the lines

    private struct Open {
        var kind: Kind
        var name: String
        var container: String?
        var line: Int
        /// Where in `found` its entry goes, once its END is seen.
        var index: Int
    }

    private static func scan(_ text: String) -> [Entry] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var found: [Entry?] = []
        var open: [Open] = []

        func close(_ kind: Kind, at line: Int) {
            guard let at = open.lastIndex(where: { $0.kind == kind }) else { return }
            // Anything opened inside it and never closed ends with it.
            for item in open[at...].reversed() {
                found[item.index] = Entry(kind: item.kind, name: item.name, container: item.container, line: item.line, endLine: line)
            }
            open.removeSubrange(at...)
        }

        for (offset, raw) in lines.enumerated() {
            let line = offset + 1
            if let mark = Self.mark(in: raw) {
                found.append(Entry(kind: .mark, name: mark.name, container: nil, line: line, endLine: line,
                                   separatorBefore: mark.before, separatorAfter: mark.after))
                continue
            }
            let words = Self.words(of: raw)
            guard let first = words.first else { continue }

            if first == "END", words.count > 1 {
                switch words[1] {
                case "FUNCTION": close(.function, at: line)
                case "CLASS": close(.class, at: line)
                case "INTERFACE": close(.interface, at: line)
                case "TYPE", "RECORD": close(.type, at: line)
                default: break
                }
                continue
            }

            guard let (kind, name) = declaration(in: words, raw: raw) else { continue }
            let container = open.last { $0.kind != .function }?.name
            // A function in an INTERFACE is a signature with no body: there
            // is nothing there to jump to.
            if kind == .function, open.last?.kind == .interface { continue }
            if kind == .function, name.uppercased().hasPrefix("FN"), words.first == "DEF" {
                found.append(Entry(kind: .function, name: name, container: container, line: line, endLine: line))
                continue
            }
            open.append(Open(kind: kind, name: name, container: kind == .function ? container : nil, line: line, index: found.count))
            found.append(nil)
        }
        // Whatever is still open runs to the end of the program.
        for item in open {
            found[item.index] = Entry(kind: item.kind, name: item.name, container: item.container, line: item.line, endLine: max(item.line, lines.count))
        }
        return found.compactMap { $0 }
    }

    /// The declaration a line opens, from its words: what kind, and the
    /// name as written in `raw`.
    private static func declaration(in words: [String], raw: Substring) -> (Kind, String)? {
        var rest = words[...]
        // PUBLIC OVERRIDES VIRTUAL ASYNC FUNCTION …: the modifiers say
        // nothing about where it is.
        while let word = rest.first, modifiers.contains(word) {
            rest = rest.dropFirst()
        }
        guard let keyword = rest.first else { return nil }
        let kind: Kind
        switch keyword {
        case "FUNCTION":
            // FUNCTION TYPE declares a function's shape, not a function.
            if rest.dropFirst().first == "TYPE" { return nil }
            kind = .function
        case "DEF":
            guard let next = rest.dropFirst().first, next.hasPrefix("FN") else { return nil }
            return name(after: "DEF", in: raw).map { (.function, $0) }
        case "CLASS": kind = .class
        case "INTERFACE": kind = .interface
        case "TYPE", "RECORD": kind = .type
        default: return nil
        }
        return name(after: keyword, in: raw).map { (kind, $0) }
    }

    private static let modifiers: Set<String> = ["PUBLIC", "PRIVATE", "PROTECTED", "OVERRIDES", "VIRTUAL", "ASYNC"]

    /// The identifier after `keyword` in `raw`, with its case and its `$`
    /// kept: `Num$` from `FUNCTION Num$(value AS INTEGER)`.
    private static func name(after keyword: String, in raw: Substring) -> String? {
        guard let range = raw.range(of: keyword, options: .caseInsensitive) else { return nil }
        let after = raw[range.upperBound...].drop { $0 == " " || $0 == "\t" }
        let name = after.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" || $0 == "%" || $0 == "!" || $0 == "#" || $0 == "&" }
        return name.isEmpty ? nil : String(name)
    }

    /// A `' MARK: - Name -` comment's name, and whether a `-` comes before
    /// it and after it. After any of BASIC's comments (`'`, `REM`, `//`, and
    /// `#` at the start of a line), in any case.
    private static func mark(in raw: Substring) -> (name: String, before: Bool, after: Bool)? {
        var text = raw.drop { $0 == " " || $0 == "\t" }
        let digits = text.prefix { $0.isNumber }
        text = text.dropFirst(digits.count).drop { $0 == " " || $0 == "\t" }
        if text.first == "'" || text.first == "#" {
            text = text.dropFirst()
        } else if text.hasPrefix("//") {
            text = text.dropFirst(2)
        } else if text.uppercased().hasPrefix("REM ") {
            text = text.dropFirst(4)
        } else {
            return nil
        }
        text = text.drop { $0 == " " || $0 == "\t" }
        guard text.uppercased().hasPrefix("MARK:") else { return nil }
        var rest = text.dropFirst("MARK:".count).trimmingCharacters(in: .whitespaces)[...]
        let before = rest.first == "-"
        if before {
            rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
        }
        let after = !rest.isEmpty && rest.last == "-"
        if after {
            rest = rest.dropLast()
        }
        return (rest.trimmingCharacters(in: .whitespaces), before, after)
    }

    /// The line's leading words, in capitals, without a line number in front
    /// or a comment after; none for a comment or a blank line.
    private static func words(of raw: Substring) -> [String] {
        var text = raw.drop { $0 == " " || $0 == "\t" }
        // A classic line number: `100 FUNCTION …`.
        let digits = text.prefix { $0.isNumber }
        if !digits.isEmpty {
            text = text.dropFirst(digits.count).drop { $0 == " " || $0 == "\t" }
        }
        if text.first == "'" || text.first == "#" || text.hasPrefix("//") { return [] }
        let upper = text.uppercased()
        if upper == "REM" || upper.hasPrefix("REM ") { return [] }
        return upper
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "(" || $0 == ":" || $0 == "'" })
            .prefix(4)
            .map(String.init)
    }
}
