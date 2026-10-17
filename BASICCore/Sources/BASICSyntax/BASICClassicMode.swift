//
//  BASICClassicMode.swift
//  BASICSyntax
//
//  OPTION CLASSIC — reading a 1970s listing as it was written.
//

import Foundation

/// Whether a program asked to be read the way Microsoft 8K BASIC read one.
///
/// Every other `OPTION` is a statement the engine *executes*: by the time it
/// runs, the program has long been lexed and parsed. This one cannot work that
/// way, because what it changes is the lexing and the parsing themselves —
/// `FOR I=1TO3` has to become four tokens before any statement runs.
///
/// So it is found by looking at the source first. That is why this is a scan
/// over text rather than a case in the interpreter: the option has to be known
/// before the first token exists.
public enum BASICClassicMode {

    /// Whether `OPTION CLASSIC` appears in a program's source.
    ///
    /// Deliberately cheap and deliberately dumb: it reads lines, skips a line
    /// number and a leading `REM`-free prefix, and looks for the two words. It
    /// does not parse, because parsing is the thing it is deciding how to do.
    ///
    /// A line whose *first statement* is `OPTION CLASSIC` counts. The words
    /// inside a string literal or a comment do not, which is what keeps a demo
    /// that merely writes *about* the option from turning it on.
    public static func isRequested(in source: String) -> Bool {
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if isRequest(on: String(line)) { return true }
        }
        return false
    }

    /// Whether one line is the request.
    static func isRequest(on line: String) -> Bool {
        var text = Substring(line)

        // A classic listing numbers its lines; a modern one does not.
        text = text.drop { $0 == " " || $0 == "\t" }
        text = text.drop { $0.isNumber }
        text = text.drop { $0 == " " || $0 == "\t" }

        // `'` and `REM` start a comment, and a comment is not a request.
        guard !text.hasPrefix("'") else { return false }

        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard words.count >= 2 else { return false }
        return words[0].uppercased() == "OPTION" && words[1].uppercased() == "CLASSIC"
    }

    /// The keywords a 1970s listing crunches against a preceding digit.
    ///
    /// `FOR I=1TO3`, `IF C1>=1ANDC1<9`, `FOR J=1 TO 22STEP3` — the spaces were
    /// squeezed out to fit 72 columns. Only these, and only after a digit:
    /// `GOTO` and `RESTORE` both contain `TO` and are never preceded by one.
    static let crunchable = ["THEN", "STEP", "AND", "ELSE", "TO", "OR"]
}
