import Foundation

/// One dialect's identity, as data.
///
/// This is what `--dialect` matches and what the IDEs show in a picker. The
/// identity is deliberately separate from the ``DialectCompiler`` that owns
/// the behavior, so a tool can list dialects without loading a back end.
public struct DialectIdentity: Sendable, Hashable {
    /// The name `--dialect` matches, lowercase: `"traditional"`, `"swift"`.
    public let identifier: String

    /// The name a picker shows: `"Traditional"`, `"Swift"`.
    public let displayName: String

    /// One sentence for the picker's subtitle.
    public let summary: String

    /// Whether this is the dialect used when none is named. Exactly one
    /// registered dialect is the default, and it is `traditional` — permanently
    /// (decision D9 in BASIC_COMPILER.md).
    public let isDefault: Bool

    /// Creates a dialect identity.
    public init(identifier: String, displayName: String, summary: String, isDefault: Bool) {
        self.identifier = identifier
        self.displayName = displayName
        self.summary = summary
        self.isDefault = isDefault
    }
}
