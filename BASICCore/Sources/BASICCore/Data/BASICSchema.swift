import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A column's *logical* type. The provider chooses the dialect's spelling.
///
/// This is why `apply(_:)` takes structured changes rather than SQL text: the
/// mapper says `boolean` and each provider writes `TINYINT`, `SMALLINT`,
/// `NUMBER(1)` or `INTEGER` (DB24). A provider handed `"… INTEGER"` would have
/// to un-say it to narrow it.
public enum BASICColumnType: Equatable, Hashable, Sendable {
    /// A whole number, up to 64 bits signed.
    case integer
    /// A binary floating-point number.
    case double
    /// An exact decimal. Scale is digits after the point.
    case decimal(precision: Int, scale: Int)
    /// Unicode text. `NVARCHAR`/`NTEXT` by default (DB20).
    case text(maximumLength: Int?)
    /// Bytes, uninterpreted.
    case blob
    /// True or false, stored as the dialect's narrowest integer (DB24).
    case boolean
    /// A calendar date.
    case date
    /// A wall-clock time.
    case time
    /// A date and time.
    case timestamp
}

/// One column of a table.
public struct BASICColumnSchema: Equatable, Hashable, Sendable {
    /// The column name as the database holds it.
    public let name: String
    /// The logical type.
    public let type: BASICColumnType
    /// Whether the column accepts `NULL`.
    public let isNullable: Bool
    /// Whether the column is part of the primary key (`DATABASE KEY`, DB4).
    public let isPrimaryKey: Bool
    /// Whether the database fills this in on insert.
    public let isGenerated: Bool
    /// Names the enum whose case names this column holds, when it holds one (§7.3).
    public let enumeratedNames: [String]?

    /// Creates a column schema.
    public init(
        name: String,
        type: BASICColumnType,
        isNullable: Bool = true,
        isPrimaryKey: Bool = false,
        isGenerated: Bool = false,
        enumeratedNames: [String]? = nil
    ) {
        self.name = name
        self.type = type
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.isGenerated = isGenerated
        self.enumeratedNames = enumeratedNames
    }
}

/// One index over a table (`DATABASE INDEX` / `DATABASE UNIQUE`, DB9).
public struct BASICIndexSchema: Equatable, Hashable, Sendable {
    /// The index name.
    public let name: String
    /// The columns it covers, in order.
    public let columns: [String]
    /// Whether it rejects duplicates.
    public let isUnique: Bool

    /// Creates an index schema.
    public init(name: String, columns: [String], isUnique: Bool = false) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
    }
}

/// A table, as the database currently has it or as a class maps to it.
public struct BASICTableSchema: Equatable, Hashable, Sendable {
    /// The table name.
    public let name: String
    /// Its columns, in declaration order.
    public let columns: [BASICColumnSchema]
    /// Its indexes.
    public let indexes: [BASICIndexSchema]

    /// Creates a table schema.
    public init(name: String, columns: [BASICColumnSchema], indexes: [BASICIndexSchema] = []) {
        self.name = name
        self.columns = columns
        self.indexes = indexes
    }

    /// The primary-key columns, in declaration order.
    public var primaryKeyColumns: [BASICColumnSchema] {
        columns.filter(\.isPrimaryKey)
    }

    /// Looks a column up by name, case-insensitively.
    public func column(named name: String) -> BASICColumnSchema? {
        columns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// One change to a schema, as a value the provider spells for its own dialect.
public enum BASICSchemaChange: Equatable, Hashable, Sendable {
    /// Create a table that does not exist.
    case createTable(BASICTableSchema)
    /// Drop a table. Destructive: `EnsureSchema` never emits this (D7).
    case dropTable(name: String)
    /// Add a column to an existing table.
    case addColumn(table: String, column: BASICColumnSchema)
    /// Drop a column. Destructive.
    case dropColumn(table: String, column: String)
    /// Change a column's type or nullability. Destructive: may not be lossless.
    case alterColumn(table: String, column: BASICColumnSchema)
    /// Create an index.
    case createIndex(table: String, index: BASICIndexSchema)
    /// Drop an index.
    case dropIndex(table: String, name: String)

    /// Whether applying this could lose data.
    ///
    /// `EnsureSchema` applies the safe changes and refuses the rest by name
    /// (D7), so this is the property that decides which pile a change lands in.
    public var isDestructive: Bool {
        switch self {
        case .createTable, .addColumn, .createIndex, .dropIndex:
            return false
        case .dropTable, .dropColumn, .alterColumn:
            return true
        }
    }

    /// The table the change applies to.
    public var tableName: String {
        switch self {
        case .createTable(let schema): return schema.name
        case .dropTable(let name): return name
        case .addColumn(let table, _), .dropColumn(let table, _), .alterColumn(let table, _),
             .createIndex(let table, _), .dropIndex(let table, _):
            return table
        }
    }
}
