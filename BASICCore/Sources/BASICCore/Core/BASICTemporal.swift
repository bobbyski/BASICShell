//
//  BASICTemporal.swift
//  BASICCore
//
//  Reading DATE, TIME, DATETIME and DECIMAL from what a program has (DB19).
//

import Foundation

/// How the four DB19 types are read from other values.
///
/// One set of rules, used by assignment, by `CDATE`/`CTIME`/`CDATETIME`/`CDEC`,
/// and by the literal parser — so a value that assigns is a value that converts,
/// and the three cannot drift.
///
/// Text converts, because that is how these arrive from a file, a database or an
/// `INPUT`. A `DOUBLE` does **not** convert to a `DECIMAL` implicitly: going
/// through binary floating point is the loss the type exists to prevent
/// (`0.1` as a `Double` is not one tenth), so a program that means it says
/// `CDEC("0.1")`.
enum BASICTemporal {

    /// ISO-8601 `yyyy-MM-dd`, or a datetime's date part.
    static func date(from value: BASICValue) -> BASICDataDate? {
        switch value {
        case .date(let date): return date
        case .datetime(let stamp): return stamp.date
        case .string(let text): return BASICTemporalLiteral.date(text.description)
        default: return nil
        }
    }

    /// `HH:mm[:ss[.fff]]`, or a datetime's time part.
    static func time(from value: BASICValue) -> BASICDataTime? {
        switch value {
        case .time(let time): return time
        case .datetime(let stamp): return stamp.time
        case .string(let text): return BASICTemporalLiteral.time(text.description)
        default: return nil
        }
    }

    /// Both. A bare date reads as midnight, and a bare time has no date to take.
    static func timestamp(from value: BASICValue) -> BASICDataTimestamp? {
        switch value {
        case .datetime(let stamp): return stamp
        case .date(let date): return BASICDataTimestamp(date: date, time: BASICDataTime(hour: 0, minute: 0, second: 0))
        case .string(let text): return BASICTemporalLiteral.timestamp(text.description)
        default: return nil
        }
    }

    /// An exact decimal. A whole `DOUBLE` converts — an integer count is exact
    /// either way — and a fractional one does not, because that is precisely
    /// where the loss would be.
    static func decimal(from value: BASICValue) -> Decimal? {
        switch value {
        case .decimal(let decimal): return decimal
        case .string(let text): return BASICDecimal.value(from: text.description)
        case .boolean(let flag): return flag ? 1 : 0
        case .number(let number):
            guard number.rounded() == number, abs(number) < 1e15 else { return nil }
            return Decimal(Int64(number))
        default: return nil
        }
    }

}

extension BASICTemporal {
    /// What is written between `#`s: a date, a time, or both.
    ///
    /// The shape decides which, as §4.2 settled — one delimiter, three types,
    /// and nothing for a reader to remember beyond "it looks like a date".
    static func literal(_ text: String) -> BASICValue? {
        let body = text.trimmingCharacters(in: .whitespaces)
        if body.contains(" ") || body.contains("T"), let stamp = BASICTemporalLiteral.timestamp(body) {
            return .datetime(stamp)
        }
        if let date = BASICTemporalLiteral.date(body) { return .date(date) }
        if let time = BASICTemporalLiteral.time(body) { return .time(time) }
        return nil
    }
}
