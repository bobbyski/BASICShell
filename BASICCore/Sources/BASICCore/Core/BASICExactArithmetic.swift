//
//  BASICExactArithmetic.swift
//  BASICCore
//
//  Arithmetic and comparison for DECIMAL, DATE, TIME and DATETIME (DB19).
//

import Foundation

/// What `+`, `<` and the rest mean for the four types DB19 added.
///
/// Consulted *before* the ordinary numeric path, which is the whole point: that
/// path converts to `Double`, and a `DECIMAL` that went through a `Double` has
/// already lost the exactness it exists for. A pair this does not recognize
/// answers nil and the ordinary rules apply, so nothing existing changes.
enum BASICExactArithmetic {

    /// The result, or nil when neither side is one of these types.
    static func apply(
        _ operation: BinaryOperation,
        _ left: BASICValue,
        _ right: BASICValue
    ) throws -> BASICValue? {
        if isDecimal(left) || isDecimal(right) {
            return try decimal(operation, left, right)
        }
        if isTemporal(left) || isTemporal(right) {
            return try temporal(operation, left, right)
        }
        return nil
    }

    private static func isDecimal(_ value: BASICValue) -> Bool {
        if case .decimal = value { return true }
        return false
    }

    private static func isTemporal(_ value: BASICValue) -> Bool {
        switch value {
        case .date, .time, .datetime: return true
        default: return false
        }
    }

    // MARK: - DECIMAL

    private static func decimal(
        _ operation: BinaryOperation,
        _ left: BASICValue,
        _ right: BASICValue
    ) throws -> BASICValue {
        // A whole number joins in exactly; anything else is refused by name
        // rather than being rounded into the answer.
        guard let a = BASICTemporal.decimal(from: left), let b = BASICTemporal.decimal(from: right) else {
            throw BASICError.type(message: "A DECIMAL can only be combined with a DECIMAL or a whole number")
        }
        switch operation {
        case .add: return .decimal(a + b)
        case .subtract: return .decimal(a - b)
        case .multiply: return .decimal(a * b)
        case .divide:
            guard b != 0 else { throw BASICError.runtime("Division by zero") }
            return .decimal(a / b)
        case .equal: return .number(a == b ? 1 : 0)
        case .notEqual: return .number(a != b ? 1 : 0)
        case .less: return .number(a < b ? 1 : 0)
        case .lessEqual: return .number(a <= b ? 1 : 0)
        case .greater: return .number(a > b ? 1 : 0)
        case .greaterEqual: return .number(a >= b ? 1 : 0)
        case .and: return .number(a != 0 && b != 0 ? 1 : 0)
        case .or: return .number(a != 0 || b != 0 ? 1 : 0)
        case .xor: return .number((a != 0) != (b != 0) ? 1 : 0)
        case .eqv: return .number((a != 0) == (b != 0) ? 1 : 0)
        case .imp: return .number(a == 0 || b != 0 ? 1 : 0)
        }
    }

    // MARK: - DATE, TIME, DATETIME

    /// Comparison only.
    ///
    /// Date arithmetic — "thirty days from now" — needs a unit to be meaningful,
    /// and guessing one is how a language ends up with `date + 1` meaning a day
    /// in one place and a second in another. Refused by name until DB19's
    /// successor settles `DATEADD`; comparison needs no unit and is what a
    /// program reaches for first.
    private static func temporal(
        _ operation: BinaryOperation,
        _ left: BASICValue,
        _ right: BASICValue
    ) throws -> BASICValue {
        guard let a = sortKey(left), let b = sortKey(right), a[0] == b[0] else {
            throw BASICError.type(message: "A DATE, TIME or DATETIME can only be compared with one of the same kind")
        }
        let order = compare(a, b)
        switch operation {
        case .equal: return .number(order == 0 ? 1 : 0)
        case .notEqual: return .number(order != 0 ? 1 : 0)
        case .less: return .number(order < 0 ? 1 : 0)
        case .lessEqual: return .number(order <= 0 ? 1 : 0)
        case .greater: return .number(order > 0 ? 1 : 0)
        case .greaterEqual: return .number(order >= 0 ? 1 : 0)
        case .add, .subtract, .multiply, .divide:
            throw BASICError.type(
                message: "Arithmetic on a DATE, TIME or DATETIME needs a unit; compare them, or convert with CDATE"
            )
        case .and, .or, .xor, .eqv, .imp:
            throw BASICError.type(message: "A DATE, TIME or DATETIME is not a condition")
        }
    }

    /// -1, 0 or 1, comparing component by component.
    private static func compare(_ left: [Int], _ right: [Int]) -> Int {
        for (a, b) in zip(left, right) where a != b { return a < b ? -1 : 1 }
        return 0
    }

    /// A comparable key: the kind, then its components in order.
    ///
    /// Components rather than text, because text would compare
    /// `#14:30:00.5#` and `#14:30:00.50#` as different when they are the same
    /// instant — and the fraction is trimmed of trailing zeros when it prints.
    ///
    /// The kind leads, so two of the same sort compare and two of different
    /// sorts never do: a `DATE` and a `TIME` have no order between them, and
    /// inventing one (midnight, say) would have `#2026-09-25# < #14:30:00#`
    /// answer something rather than say it is not a question.
    private static func sortKey(_ value: BASICValue) -> [Int]? {
        switch value {
        case .date(let date):
            return [0, date.year, date.month, date.day]
        case .time(let time):
            return [1, time.hour, time.minute, time.second, time.nanosecond]
        case .datetime(let stamp):
            return [2, stamp.date.year, stamp.date.month, stamp.date.day,
                    stamp.time.hour, stamp.time.minute, stamp.time.second, stamp.time.nanosecond]
        default:
            return nil
        }
    }
}
