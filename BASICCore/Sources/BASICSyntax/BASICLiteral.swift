import Foundation

/// A constant the parser can read straight off the source: a number or a
/// string.
///
/// This is the only value-shaped thing in the syntax module. `DATA` items,
/// field defaults, and metadata values are literals here; the interpreter
/// turns them into runtime values (`BASICValue`) when it builds definitions,
/// and the compiler turns them into constants.
public enum BASICLiteral: Equatable, Sendable {
    /// A numeric literal, already negated if it was written `-5`.
    case number(Double)

    /// A string literal, with escapes already resolved.
    case string(String)

    /// `TRUE` or `FALSE`.
    case boolean(Bool)

    /// `NULL`.
    case null

    /// `EMPTY` — a value that has never been set.
    case empty
}

/// Metadata attached to a `TYPE` or `CLASS` field, as literals.
public typealias BASICLiteralMetadata = [String: BASICLiteral]
