import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A value inside a document: a scalar, a nested document, or an array.
///
/// Richer than `BASICDataValue` because a document store nests — which is how
/// DB8 embeds a referenced class and how §7.3 stores a payload `ENUM`.
public indirect enum BASICDocumentValue: Equatable, Sendable {
    /// A single value.
    case scalar(BASICDataValue)
    /// A nested document.
    case document(BASICDocument)
    /// An ordered list.
    case array([BASICDocumentValue])

    /// The scalar, when this is one.
    public var scalarValue: BASICDataValue? {
        if case .scalar(let value) = self { return value }
        return nil
    }
}

/// An ordered set of named values: one record in a document store.
///
/// Ordered because round-tripping a document that reorders its fields makes
/// every diff and every test unreadable, and because a generated document
/// should read in the order the class declares.
public struct BASICDocument: Equatable, Sendable {
    private var keys: [String] = []
    private var values: [String: BASICDocumentValue] = [:]

    /// The key a payload `ENUM` keeps its case under (§7.3).
    ///
    /// Not invented here: `BASICEnumDefinition.tagKey` already chose it,
    /// because `$` cannot begin a BASIC field name so it can never collide.
    public static let caseKey = "$CASE"

    /// Creates an empty document.
    public init() {}

    /// Creates a document from ordered pairs. A repeated key keeps its first position.
    public init(_ pairs: [(String, BASICDocumentValue)]) {
        for (key, value) in pairs {
            self[key] = value
        }
    }

    /// The field names, in insertion order.
    public var fieldNames: [String] { keys }

    /// Whether the document has no fields.
    public var isEmpty: Bool { keys.isEmpty }

    /// Reads or writes a field. Assigning nil removes it.
    public subscript(key: String) -> BASICDocumentValue? {
        get { values[key] }
        set {
            if let newValue {
                if values[key] == nil { keys.append(key) }
                values[key] = newValue
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    /// Reads a scalar field, when it is one.
    public func scalar(_ key: String) -> BASICDataValue? {
        self[key]?.scalarValue
    }

    /// Sets a scalar field.
    public mutating func setScalar(_ key: String, _ value: BASICDataValue) {
        self[key] = .scalar(value)
    }

    /// The pairs, in insertion order.
    public var pairs: [(key: String, value: BASICDocumentValue)] {
        keys.compactMap { key in values[key].map { (key: key, value: $0) } }
    }
}
