import Foundation

/// The dialects this build of `basicc` knows, by identifier.
///
/// The registry is populated by the driver at startup with the dialect
/// frameworks it links; the kit itself registers nothing. Lookup is by the
/// `--dialect` name, case-insensitively, and the default dialect is the one
/// whose identity says so.
public struct DialectRegistry: Sendable {
    /// Error raised when `--dialect` names something this build does not have.
    public struct UnknownDialect: Error, CustomStringConvertible {
        /// The name that was asked for.
        public let requested: String
        /// The names that would have worked.
        public let available: [String]

        public var description: String {
            "unknown dialect '\(requested)' — available: \(available.joined(separator: ", "))"
        }
    }

    private let dialects: [any DialectCompiler]

    /// Creates a registry over the given dialects.
    ///
    /// - Precondition: exactly one dialect's identity has `isDefault == true`.
    public init(_ dialects: [any DialectCompiler]) {
        let defaults = dialects.filter { type(of: $0).identity.isDefault }
        precondition(defaults.count == 1, "exactly one dialect must be the default; found \(defaults.count)")
        self.dialects = dialects
    }

    /// Every registered identity, default first, then alphabetical.
    public var identities: [DialectIdentity] {
        dialects.map { type(of: $0).identity }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.identifier < rhs.identifier
            }
    }

    /// The dialect used when `--dialect` is not given.
    public var defaultDialect: any DialectCompiler {
        dialects.first { type(of: $0).identity.isDefault }!
    }

    /// Resolves a `--dialect` name, or the default when `name` is nil.
    public func dialect(named name: String?) throws -> any DialectCompiler {
        guard let name else { return defaultDialect }
        let wanted = name.lowercased()
        if let match = dialects.first(where: { type(of: $0).identity.identifier == wanted }) {
            return match
        }
        throw UnknownDialect(requested: name, available: identities.map(\.identifier))
    }
}
