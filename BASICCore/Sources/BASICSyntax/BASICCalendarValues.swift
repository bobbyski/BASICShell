//
//  BASICCalendarValues.swift
//  BASICSyntax
//
//  DATE, TIME and DATETIME as values (DB19).
//

import Foundation

// These began at the provider boundary, where a database's date had to cross
// into BASIC before the language had one. DB19 gave the language the types, so
// they moved here -- one representation, not two, and the lexer can read a
// `#...#` literal with the same code the ORM stores.

public struct BASICDataDate: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// Proleptic Gregorian year.
    public let year: Int
    /// Month, 1 through 12.
    public let month: Int
    /// Day of month, 1 through 31.
    public let day: Int

    /// Creates a calendar date from its parts.
    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// ISO-8601 `yyyy-MM-dd`.
    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Parses ISO-8601 `yyyy-MM-dd`, returning nil when the text is not one.
    public init?(iso8601 text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        self.init(year: year, month: month, day: day)
    }
}

/// A wall-clock time with no date, as SQL's `TIME` means it.
public struct BASICDataTime: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// Hour, 0 through 23.
    public let hour: Int
    /// Minute, 0 through 59.
    public let minute: Int
    /// Second, 0 through 59.
    public let second: Int
    /// Fractional second in nanoseconds, 0 through 999_999_999.
    public let nanosecond: Int

    /// Creates a wall-clock time from its parts.
    public init(hour: Int, minute: Int, second: Int, nanosecond: Int = 0) {
        self.hour = hour
        self.minute = minute
        self.second = second
        self.nanosecond = nanosecond
    }

    /// ISO-8601 `HH:mm:ss`, with `.SSSSSSSSS` only when there is a fraction.
    public var description: String {
        let base = String(format: "%02d:%02d:%02d", hour, minute, second)
        guard nanosecond > 0 else { return base }
        let fraction = String(format: "%09d", nanosecond)
            .reversed().drop { $0 == "0" }.reversed()
        return base + "." + String(fraction)
    }

    /// Parses ISO-8601 `HH:mm:ss[.fraction]`, returning nil when the text is not one.
    public init?(iso8601 text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        let secondParts = parts[2].split(separator: ".", omittingEmptySubsequences: false)
        guard let second = Int(secondParts[0]) else { return nil }
        var nanosecond = 0
        if secondParts.count == 2 {
            let digits = String(secondParts[1].prefix(9)).padding(toLength: 9, withPad: "0", startingAt: 0)
            guard let parsed = Int(digits) else { return nil }
            nanosecond = parsed
        }
        guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        self.init(hour: hour, minute: minute, second: second, nanosecond: nanosecond)
    }
}

/// A date and time, with an optional UTC offset.
///
/// The offset is optional because SQL's `TIMESTAMP` usually has none: a column
/// says *when* in local terms and leaves the zone to the application. Keeping
/// it optional lets a provider that does carry one round-trip it instead of
/// inventing a zone on read.
public struct BASICDataTimestamp: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The calendar date part.
    public let date: BASICDataDate
    /// The wall-clock time part.
    public let time: BASICDataTime
    /// Minutes east of UTC, when the source carried one.
    public let utcOffsetMinutes: Int?

    /// Creates a timestamp from its parts.
    public init(date: BASICDataDate, time: BASICDataTime, utcOffsetMinutes: Int? = nil) {
        self.date = date
        self.time = time
        self.utcOffsetMinutes = utcOffsetMinutes
    }

    /// ISO-8601, with `Z` or `±HH:mm` only when an offset is carried.
    public var description: String {
        var text = "\(date)T\(time)"
        guard let utcOffsetMinutes else { return text }
        if utcOffsetMinutes == 0 {
            text += "Z"
        } else {
            let sign = utcOffsetMinutes < 0 ? "-" : "+"
            let magnitude = abs(utcOffsetMinutes)
            text += String(format: "%@%02d:%02d", sign, magnitude / 60, magnitude % 60)
        }
        return text
    }

    /// Parses ISO-8601, accepting a `T` or a space between the date and time.
    public init?(iso8601 text: String) {
        var body = text
        var offset: Int?
        if body.hasSuffix("Z") {
            offset = 0
            body.removeLast()
        } else if let signIndex = body.lastIndex(where: { $0 == "+" || $0 == "-" }),
                  signIndex > body.startIndex,
                  body.distance(from: signIndex, to: body.endIndex) == 6 {
            let zone = body[body.index(after: signIndex)...].split(separator: ":")
            guard zone.count == 2, let hours = Int(zone[0]), let minutes = Int(zone[1]) else { return nil }
            let magnitude = hours * 60 + minutes
            offset = body[signIndex] == "-" ? -magnitude : magnitude
            body = String(body[body.startIndex..<signIndex])
        }
        let separator: Character = body.contains("T") ? "T" : " "
        let halves = body.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2,
              let date = BASICDataDate(iso8601: String(halves[0])),
              let time = BASICDataTime(iso8601: String(halves[1])) else {
            return nil
        }
        self.init(date: date, time: time, utcOffsetMinutes: offset)
    }
}

/// One value crossing the boundary between BASIC and a database provider.
///
/// Deliberately its own type rather than `BASICValue`. A database needs `NULL`
/// distinct from "unset", plus blobs, exact decimals and three shapes of date —
/// none of which the language's value type carries (`VARIABLES.md` on `NULL`).
/// Keeping them separate stops a database concern leaking into the language,
/// and lets providers be built before D0.7 lands the matching BASIC types.
