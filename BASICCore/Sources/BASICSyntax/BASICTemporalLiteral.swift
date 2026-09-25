//
//  BASICTemporalLiteral.swift
//  BASICSyntax
//
//  Reading `#2026-09-25#`, `#14:30:00#` and `#2026-09-25 14:30:00#` (DB19).
//

import Foundation

/// The text forms of `DATE`, `TIME` and `DATETIME`.
///
/// In the syntax module because the *lexer* needs them: `#` has marked a file
/// number since the 1970s, so the only safe way to tell `#2026-09-25#` from
/// `PRINT #1` is to try reading one. Checking by parsing rather than by pattern
/// also means the lexer and the evaluator can never disagree about what a
/// literal is — there is one reader, and both call it.
public enum BASICTemporalLiteral {

    /// ISO-8601 `yyyy-MM-dd`.
    public static func date(_ text: String) -> BASICDataDate? {
        BASICDataDate(iso8601: text.trimmingCharacters(in: .whitespaces))
    }

    /// `HH:mm`, `HH:mm:ss`, or `HH:mm:ss.fff`.
    public static func time(_ text: String) -> BASICDataTime? {
        let body = text.trimmingCharacters(in: .whitespaces)
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        guard parts.count == 3 else {
            return BASICDataTime(hour: hour, minute: minute, second: 0)
        }
        let secondParts = parts[2].split(separator: ".", omittingEmptySubsequences: false)
        guard secondParts.count <= 2, let second = Int(secondParts[0]),
              (0...59).contains(second) else { return nil }
        var nanosecond = 0
        if secondParts.count == 2 {
            let digits = secondParts[1].prefix(9)
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
                  let fraction = Int(digits) else { return nil }
            var scaled = fraction
            for _ in 0..<(9 - digits.count) { scaled *= 10 }
            nanosecond = scaled
        }
        return BASICDataTime(hour: hour, minute: minute, second: second, nanosecond: nanosecond)
    }

    /// Both halves, separated by a space or a `T`.
    ///
    /// A person writes `2026-09-25 14:30:00` and a machine wrote
    /// `2026-09-25T14:30:00`; they mean the same instant, so both read.
    public static func timestamp(_ text: String) -> BASICDataTimestamp? {
        let body = text.trimmingCharacters(in: .whitespaces)
        let separator: Character = body.contains("T") ? "T" : " "
        let halves = body.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: true)
        guard halves.count == 2,
              let date = date(String(halves[0])),
              let time = time(String(halves[1])) else { return nil }
        return BASICDataTimestamp(date: date, time: time)
    }

    /// Whether text between two `#`s is any of the three.
    ///
    /// The lexer's question, and the reason this is not a regular expression:
    /// "is it a literal" and "what is it" have to have the same answer.
    public static func isLiteral(_ text: String) -> Bool {
        let body = text.trimmingCharacters(in: .whitespaces)
        return date(body) != nil || time(body) != nil || timestamp(body) != nil
    }
}
