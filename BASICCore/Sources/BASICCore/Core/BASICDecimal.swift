//
//  BASICDecimal.swift
//  BASICCore
//
//  The exact decimal the language gained with DB19.
//

import Foundation

/// Reading and printing `DECIMAL`.
///
/// `Foundation.Decimal` is the representation — 38 digits of significand, of
/// which VB's `Decimal` guarantees 28, which is what §4.2 settled on and what
/// the SQL side expects. The point is that it is *not* a `Double`: money in
/// binary floating point is a correctness bug rather than a fidelity loss, and
/// every path here is written so no `Double` ever sees the value.
enum BASICDecimal {

    /// VB's `Decimal` precision, and SQL's expectation.
    static let significantDigits = 28

    /// Reads a decimal from its text, or nil when the text is not one.
    ///
    /// Parsed from the string rather than through `Double`, because going
    /// through a `Double` is exactly the loss this type exists to avoid:
    /// `Decimal(0.1)` is not one tenth, and `Decimal(string: "0.1")` is.
    static func value(from text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // `Decimal(string:)` accepts trailing garbage ("12abc" reads as 12), so
        // the shape is checked first: an optional sign, digits, and at most one
        // point with digits on at least one side.
        var body = Substring(trimmed)
        if body.first == "+" || body.first == "-" { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, !body.isEmpty else { return nil }
        guard parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        guard parts.contains(where: { !$0.isEmpty }) else { return nil }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// How a decimal prints: as written, with no exponent and no trailing zeros
    /// invented.
    static func text(_ value: Decimal) -> String {
        var value = value
        return NSDecimalString(&value, Locale(identifier: "en_US_POSIX"))
    }

    /// The nearest `Double`, for the places a number is genuinely wanted.
    ///
    /// Named rather than implicit, so every lossy step is a step someone wrote.
    static func approximateDouble(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}
