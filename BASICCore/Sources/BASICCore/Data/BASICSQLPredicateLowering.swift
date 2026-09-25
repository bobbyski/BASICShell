import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A `WHERE` clause and the values to bind to it.
struct BASICSQLWhereClause: Equatable {
    /// The clause, without the `WHERE` keyword. Empty when it matches everything.
    let sql: String
    /// The values, in placeholder order. Never interpolated (DB15).
    let parameters: [BASICDataValue]
}

/// Lowers a `BASICQueryPredicate` to SQL.
///
/// Every value becomes a `?` and a bound parameter — the predicate tree is
/// what makes that guaranteed rather than careful, because a value has nowhere
/// else to go. Field names come from the mapper, so they are column names that
/// were validated at mapping time; they are quoted here as the second half of
/// the same defense.
enum BASICSQLPredicateLowering {

    static func lower(
        _ predicate: BASICQueryPredicate,
        quote: (String) -> String,
        supported: Set<BASICPredicateOperator>
    ) throws -> BASICSQLWhereClause {
        for op in predicate.usedOperators where !supported.contains(op) {
            throw BASICDataError.unsupportedOperator(op, provider: "this provider")
        }
        var parameters: [BASICDataValue] = []
        let sql = try clause(predicate, quote: quote, parameters: &parameters)
        return BASICSQLWhereClause(sql: sql, parameters: parameters)
    }

    private static func clause(
        _ predicate: BASICQueryPredicate,
        quote: (String) -> String,
        parameters: inout [BASICDataValue]
    ) throws -> String {
        switch predicate {
        case .all:
            return ""
        case .and(let children):
            let parts = try children.map { try clause($0, quote: quote, parameters: &parameters) }
                .filter { !$0.isEmpty }
            if parts.isEmpty { return "" }
            return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " AND ") + ")"
        case .or(let children):
            let parts = try children.map { try clause($0, quote: quote, parameters: &parameters) }
            // An empty OR matches nothing, which is not the same as matching
            // everything -- so it cannot collapse to "".
            if parts.isEmpty { return "1 = 0" }
            if parts.contains(where: \.isEmpty) { return "" }
            return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " OR ") + ")"
        case .not(let child):
            let inner = try clause(child, quote: quote, parameters: &parameters)
            return inner.isEmpty ? "1 = 0" : "NOT (\(inner))"
        case .compare(let field, let op, let operand):
            return try comparison(field: quote(field), op: op, operand: operand, parameters: &parameters)
        }
    }

    private static func comparison(
        field: String,
        op: BASICPredicateOperator,
        operand: BASICPredicateOperand,
        parameters: inout [BASICDataValue]
    ) throws -> String {
        func bind(_ value: BASICDataValue) -> String {
            parameters.append(value)
            return "?"
        }

        switch (op, operand) {
        case (.equal, .value(let value)) where value.isNull:
            // Comparing against the literal null is a nullity test, which is
            // what NSPredicate's `x == nil` means.
            return "\(field) IS NULL"
        case (.notEqual, .value(let value)) where value.isNull:
            return "\(field) IS NOT NULL"

        case (.equal, .value(let value)):
            return "\(field) = \(bind(value))"
        case (.notEqual, .value(let value)):
            return "\(field) <> \(bind(value))"
        case (.lessThan, .value(let value)):
            return "\(field) < \(bind(value))"
        case (.lessThanOrEqual, .value(let value)):
            return "\(field) <= \(bind(value))"
        case (.greaterThan, .value(let value)):
            return "\(field) > \(bind(value))"
        case (.greaterThanOrEqual, .value(let value)):
            return "\(field) >= \(bind(value))"
        case (.like, .value(let value)):
            return "\(field) LIKE \(bind(value))"

        case (.beginsWith, .value(let value)):
            return "\(field) LIKE \(bind(.text(escapedForLike(value) + "%"))) ESCAPE '\\'"
        case (.endsWith, .value(let value)):
            return "\(field) LIKE \(bind(.text("%" + escapedForLike(value)))) ESCAPE '\\'"
        case (.contains, .value(let value)):
            return "\(field) LIKE \(bind(.text("%" + escapedForLike(value) + "%"))) ESCAPE '\\'"

        case (.in, .list(let values)):
            guard !values.isEmpty else { return "1 = 0" }
            return "\(field) IN (\(values.map { bind($0) }.joined(separator: ", ")))"
        case (.between, .range(let low, let high)):
            return "\(field) BETWEEN \(bind(low)) AND \(bind(high))"

        case (.matches, _):
            throw BASICDataError.unsupportedOperator(.matches, provider: "SQL")
        default:
            throw BASICDataError.unsupported("\(op.rawValue) does not take that kind of operand")
        }
    }

    /// Escapes a value being spliced into a `LIKE` pattern.
    ///
    /// `BEGINSWITH "50%"` has to find names starting with the three characters
    /// `5`, `0`, `%` -- not names starting with `50` and then anything. Without
    /// this the wildcard in the *data* becomes a wildcard in the *pattern*,
    /// which is a quiet wrong answer rather than an error.
    static func escapedForLike(_ value: BASICDataValue) -> String {
        let text: String
        switch value {
        case .text(let string): text = string
        case .integer(let number): text = "\(number)"
        case .double(let number): text = "\(number)"
        case .decimal(let number): text = "\(number)"
        case .boolean(let flag): text = flag ? "1" : "0"
        case .date(let date): text = date.description
        case .time(let time): text = time.description
        case .timestamp(let stamp): text = stamp.description
        case .blob, .null: text = ""
        }
        return text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
