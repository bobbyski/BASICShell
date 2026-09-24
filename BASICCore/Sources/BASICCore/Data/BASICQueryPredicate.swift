import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A comparison a predicate can make.
///
/// The vocabulary is `NSPredicate`'s, because §7.1 takes Apple's predicate
/// whole rather than borrowing its shape: `NSPredicate` was designed as a
/// store-neutral query abstraction, which is this plan's exact problem.
public enum BASICPredicateOperator: String, Equatable, Hashable, Sendable, CaseIterable {
    case equal = "=="
    case notEqual = "!="
    case lessThan = "<"
    case lessThanOrEqual = "<="
    case greaterThan = ">"
    case greaterThanOrEqual = ">="
    case `in` = "IN"
    case between = "BETWEEN"
    case beginsWith = "BEGINSWITH"
    case endsWith = "ENDSWITH"
    case contains = "CONTAINS"
    case like = "LIKE"
    case matches = "MATCHES"
}

/// The right-hand side of a comparison.
public enum BASICPredicateOperand: Equatable, Hashable, Sendable {
    /// A single value.
    case value(BASICDataValue)
    /// A list, for `IN`.
    case list([BASICDataValue])
    /// A pair, for `BETWEEN`.
    case range(BASICDataValue, BASICDataValue)
}

/// A query predicate: a parsed tree, never a string.
///
/// One type serves both protocols. The SQL side lowers it to a `WHERE` clause
/// plus bound parameters; the document side lowers it to that store's filter.
/// Keeping it a tree rather than text is what makes DB15 hold — no value ever
/// reaches a statement as text — and what lets each provider lower it once
/// instead of re-parsing.
public indirect enum BASICQueryPredicate: Equatable, Hashable, Sendable {
    /// Matches everything.
    case all
    /// Compares a field against an operand.
    case compare(field: String, op: BASICPredicateOperator, operand: BASICPredicateOperand)
    /// True when every child is true. Empty means true.
    case and([BASICQueryPredicate])
    /// True when any child is true. Empty means false.
    case or([BASICQueryPredicate])
    /// Inverts its child.
    case not(BASICQueryPredicate)

    /// Compares a field against a single value.
    public static func compare(_ field: String, _ op: BASICPredicateOperator, _ value: BASICDataValue) -> BASICQueryPredicate {
        .compare(field: field, op: op, operand: .value(value))
    }

    /// Combines with another predicate, flattening nested `and`s.
    public func and(_ other: BASICQueryPredicate) -> BASICQueryPredicate {
        switch (self, other) {
        case (.all, _): return other
        case (_, .all): return self
        case (.and(let left), .and(let right)): return .and(left + right)
        case (.and(let left), _): return .and(left + [other])
        case (_, .and(let right)): return .and([self] + right)
        default: return .and([self, other])
        }
    }

    /// Combines with another predicate, flattening nested `or`s.
    public func or(_ other: BASICQueryPredicate) -> BASICQueryPredicate {
        switch (self, other) {
        case (.or(let left), .or(let right)): return .or(left + right)
        case (.or(let left), _): return .or(left + [other])
        case (_, .or(let right)): return .or([self] + right)
        default: return .or([self, other])
        }
    }

    /// Every field name the predicate mentions, in first-seen order.
    ///
    /// The mapper uses this to translate class field names to column names,
    /// and to refuse a predicate naming a field that is not persisted.
    public var referencedFields: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        func walk(_ node: BASICQueryPredicate) {
            switch node {
            case .all:
                break
            case .compare(let field, _, _):
                let key = field.uppercased()
                if seen.insert(key).inserted { ordered.append(field) }
            case .and(let children), .or(let children):
                children.forEach(walk)
            case .not(let child):
                walk(child)
            }
        }
        walk(self)
        return ordered
    }

    /// Every operator the predicate uses.
    ///
    /// A provider checks this against its own `capabilities` so an operator it
    /// cannot honor is an error when the predicate is *built*, naming the
    /// operator — never a runtime surprise on one store and not another (§7.1).
    public var usedOperators: Set<BASICPredicateOperator> {
        switch self {
        case .all:
            return []
        case .compare(_, let op, _):
            return [op]
        case .and(let children), .or(let children):
            return children.reduce(into: Set<BASICPredicateOperator>()) { $0.formUnion($1.usedOperators) }
        case .not(let child):
            return child.usedOperators
        }
    }

    /// Rewrites every field name, for mapping BASIC field names to columns.
    public func renamingFields(_ rename: (String) throws -> String) rethrows -> BASICQueryPredicate {
        switch self {
        case .all:
            return .all
        case .compare(let field, let op, let operand):
            return .compare(field: try rename(field), op: op, operand: operand)
        case .and(let children):
            return .and(try children.map { try $0.renamingFields(rename) })
        case .or(let children):
            return .or(try children.map { try $0.renamingFields(rename) })
        case .not(let child):
            return .not(try child.renamingFields(rename))
        }
    }
}
