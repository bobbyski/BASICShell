import Foundation

/// The answers Sema needs from a dialect while it is still dialect-agnostic.
///
/// The front end (lex → parse → sema → BIR) is shared. Where its behavior
/// legitimately depends on the dialect, it asks this profile instead of
/// branching on a dialect name — so the traditional dialect never accretes
/// `if swift` checks, and a new dialect is a new profile, not a new set of
/// branches.
///
/// ```text
///   source ─► Parser ─► Sema ──asks──► SemanticProfile ◄── owned by the dialect
///                         │
///                         ▼
///                        BIR ─────────► DialectCompiler.lower(_:)
/// ```
public struct SemanticProfile: Sendable {
    /// How strings are represented at rest, which decides what the string
    /// intrinsics may assume.
    public enum StringRepresentation: Sendable {
        /// An exact-byte runtime string: `CHR$(0)` is a legal character and
        /// legacy binary file I/O round-trips. The traditional dialect.
        case exactBytes

        /// `Swift.String` at rest; the BASIC illusion (1-based indexing,
        /// `MID$`) is built on access. The Swift dialect.
        case swiftString
    }

    /// The string representation this dialect compiles to.
    public let strings: StringRepresentation

    /// Whether `IMPORT "Name"` may name a Swift framework (as opposed to a
    /// `.bas` file or directory). Only the Swift dialect says yes.
    public let importsSwiftFrameworks: Bool

    /// Creates a semantic profile.
    public init(strings: StringRepresentation, importsSwiftFrameworks: Bool) {
        self.strings = strings
        self.importsSwiftFrameworks = importsSwiftFrameworks
    }
}
