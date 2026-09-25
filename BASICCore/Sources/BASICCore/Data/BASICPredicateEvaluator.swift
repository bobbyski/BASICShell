import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Evaluates a `BASICQueryPredicate` in memory.
///
/// One evaluator serves both reference providers: the SQL one parses a `WHERE`
/// clause into the same tree the document one is handed directly, so the
/// matching semantics cannot drift between them.
public enum BASICPredicateEvaluator {
    /// Evaluates against a field lookup. A field the lookup does not know is `null`.
    ///
    /// Follows SQL: a comparison involving `NULL` is unknown, and `WHERE`
    /// keeps only rows that are true — so unknown filters the row out. That is
    /// also what a document store does with an absent field, so the two agree
    /// without either being special-cased.
    public static func matches(
        _ predicate: BASICQueryPredicate,
        _ lookup: (String) -> BASICDataValue?
    ) -> Bool {
        switch predicate {
        case .all:
            return true
        case .compare(let field, let op, let operand):
            return compare(lookup(field) ?? .null, op, operand)
        case .and(let children):
            return children.allSatisfy { matches($0, lookup) }
        case .or(let children):
            return children.contains { matches($0, lookup) }
        case .not(let child):
            return !matches(child, lookup)
        }
    }

    private static func compare(
        _ value: BASICDataValue,
        _ op: BASICPredicateOperator,
        _ operand: BASICPredicateOperand
    ) -> Bool {
        switch op {
        case .in:
            guard case .list(let candidates) = operand else { return false }
            return candidates.contains { equal(value, $0) }
        case .between:
            guard case .range(let low, let high) = operand,
                  let lowOrder = order(value, low), let highOrder = order(value, high) else {
                return false
            }
            return lowOrder >= 0 && highOrder <= 0
        default:
            guard case .value(let other) = operand else { return false }
            return compare(value, op, other)
        }
    }

    private static func compare(
        _ value: BASICDataValue,
        _ op: BASICPredicateOperator,
        _ other: BASICDataValue
    ) -> Bool {
        switch op {
        case .equal:
            // Comparing against the *literal* null is a nullity test, which is
            // what NSPredicate's `x == nil` means and what SQL spells IS NULL.
            // A null encountered in the *data* still fails every comparison.
            if other.isNull { return value.isNull }
            return equal(value, other)
        case .notEqual:
            if other.isNull { return !value.isNull }
            // SQL: NULL != anything is unknown, not true.
            if value.isNull { return false }
            return !equal(value, other)
        case .lessThan:
            return order(value, other).map { $0 < 0 } ?? false
        case .lessThanOrEqual:
            return order(value, other).map { $0 <= 0 } ?? false
        case .greaterThan:
            return order(value, other).map { $0 > 0 } ?? false
        case .greaterThanOrEqual:
            return order(value, other).map { $0 >= 0 } ?? false
        case .beginsWith:
            return text(value).map { left in text(other).map(left.hasPrefix) ?? false } ?? false
        case .endsWith:
            return text(value).map { left in text(other).map(left.hasSuffix) ?? false } ?? false
        case .contains:
            return text(value).map { left in text(other).map(left.contains) ?? false } ?? false
        case .like:
            guard let left = text(value), let pattern = text(other) else { return false }
            return matchesLike(left, pattern)
        case .matches:
            guard let left = text(value), let pattern = text(other),
                  let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(left.startIndex..<left.endIndex, in: left)
            return regex.firstMatch(in: left, range: range) != nil
        case .in, .between:
            return false
        }
    }

    /// Value equality, with numeric kinds comparing across representations.
    public static func equal(_ left: BASICDataValue, _ right: BASICDataValue) -> Bool {
        if left.isNull || right.isNull { return false }
        if let order = order(left, right) { return order == 0 }
        return left == right
    }

    /// Orders two values, or nil when they are not comparable.
    public static func order(_ left: BASICDataValue, _ right: BASICDataValue) -> Int? {
        if left.isNull || right.isNull { return nil }
        if let a = decimal(left), let b = decimal(right) {
            return a < b ? -1 : (a > b ? 1 : 0)
        }
        if let a = text(left), let b = text(right) {
            return a < b ? -1 : (a > b ? 1 : 0)
        }
        if case .blob(let a) = left, case .blob(let b) = right {
            if a == b { return 0 }
            return a.lexicographicallyPrecedes(b) ? -1 : 1
        }
        return nil
    }

    /// The value as an exact decimal, when it is a number or a boolean.
    private static func decimal(_ value: BASICDataValue) -> Decimal? {
        switch value {
        case .integer(let number): return Decimal(number)
        case .double(let number): return Decimal(number)
        case .decimal(let number): return number
        case .boolean(let flag): return flag ? 1 : 0
        default: return nil
        }
    }

    /// The value as text, with the three date kinds rendering ISO-8601 so they
    /// order chronologically — which is why dates survive as strings at all.
    private static func text(_ value: BASICDataValue) -> String? {
        switch value {
        case .text(let string): return string
        case .date(let date): return date.description
        case .time(let time): return time.description
        case .timestamp(let stamp): return stamp.description
        default: return nil
        }
    }

    /// SQL `LIKE`: `%` is any run, `_` is one character.
    static func matchesLike(_ text: String, _ pattern: String) -> Bool {
        let subject = Array(text)
        let template = Array(pattern)
        var cache: [[Bool?]] = Array(
            repeating: Array(repeating: nil, count: template.count + 1),
            count: subject.count + 1
        )

        func walk(_ s: Int, _ p: Int) -> Bool {
            if let cached = cache[s][p] { return cached }
            let result: Bool
            if p == template.count {
                result = s == subject.count
            } else if template[p] == "%" {
                result = walk(s, p + 1) || (s < subject.count && walk(s + 1, p))
            } else if s < subject.count && (template[p] == "_" || template[p] == subject[s]) {
                result = walk(s + 1, p + 1)
            } else {
                result = false
            }
            cache[s][p] = result
            return result
        }

        return walk(0, 0)
    }
}
