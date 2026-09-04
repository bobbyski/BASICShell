import Foundation

/// BASIC-visible event selector registered with `ON <type> [subtype] CALL`.
public struct BASICEventSelector: Hashable, Sendable, CustomStringConvertible {
    /// Primary event type, normalized to uppercase.
    public let type: String
    /// Optional subtype, normalized to uppercase.
    public let subtype: String?

    /// Creates an event selector.
    public init(type: String, subtype: String? = nil) {
        self.type = type.uppercased()
        let trimmedSubtype = subtype?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subtype = trimmedSubtype?.isEmpty == false ? trimmedSubtype?.uppercased() : nil
    }

    /// Stable display name used by diagnostics and host bridges.
    public var description: String {
        [type, subtype].compactMap { $0 }.joined(separator: " ")
    }
}
