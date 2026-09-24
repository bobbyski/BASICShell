import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What went wrong at the database boundary.
public enum BASICDataError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The provider cannot exist on this platform (DB17).
    case unavailable(provider: String, reason: String)
    /// No registered provider recognizes the connection string.
    case noProviderFor(url: String)
    /// The connection string is malformed.
    case badConnectionString(String)
    /// The provider is not connected, or has been closed.
    case notConnected
    /// The provider refused an operation it cannot perform.
    case unsupported(String)
    /// An operator the provider cannot honor, refused when the predicate was built.
    case unsupportedOperator(BASICPredicateOperator, provider: String)
    /// A name that is not a legal identifier, refused before it reaches SQL (DB15).
    case invalidIdentifier(String, reason: String)
    /// A schema change that could lose data, refused by name (D7).
    case destructiveChangeRefused([String])
    /// The named table or collection is not there.
    case noSuchTable(String)
    /// The named column or field is not there.
    case noSuchColumn(String, table: String)
    /// A value did not fit the column it was read into.
    case typeMismatch(column: String, expected: String, found: String)
    /// The underlying driver said no.
    case driver(String)

    public var description: String {
        switch self {
        case .unavailable(let provider, let reason):
            return "\(provider) is not available on this platform: \(reason)"
        case .noProviderFor(let url):
            return "No database provider recognizes \(url)"
        case .badConnectionString(let detail):
            return "Bad connection string: \(detail)"
        case .notConnected:
            return "The database is not open"
        case .unsupported(let detail):
            return "Unsupported: \(detail)"
        case .unsupportedOperator(let op, let provider):
            return "\(provider) cannot honor the \(op.rawValue) operator"
        case .invalidIdentifier(let name, let reason):
            return "\(name) is not a usable database name: \(reason)"
        case .destructiveChangeRefused(let changes):
            return "Refused changes that could lose data: \(changes.joined(separator: ", "))"
        case .noSuchTable(let name):
            return "No table named \(name)"
        case .noSuchColumn(let column, let table):
            return "\(table) has no column named \(column)"
        case .typeMismatch(let column, let expected, let found):
            return "\(column) holds \(found) where \(expected) was expected"
        case .driver(let message):
            return message
        }
    }
}

/// What a provider can actually do.
///
/// Read, never assumed. SQLite has no real `ALTER COLUMN`; Mongo has no
/// transactions without a replica set; an ODBC connection's answer depends on
/// the driver behind it rather than on ODBC. So this is an instance property:
/// a meta-provider like ODBC resolves it per connection (§5.2).
public struct BASICDataCapabilities: Equatable, Sendable {
    /// Whether `begin`/`commit`/`rollback` do anything (DB14).
    public var supportsTransactions: Bool
    /// Whether a column's type or nullability can be changed in place.
    public var supportsAlterColumn: Bool
    /// Whether the provider can create indexes.
    public var supportsIndexes: Bool
    /// Whether an insert can report a generated key.
    public var reportsGeneratedKeys: Bool
    /// The predicate operators this provider lowers (§7.1).
    public var operators: Set<BASICPredicateOperator>
    /// The narrowest integer type the dialect has for a boolean (DB24), for diagnostics.
    public var booleanSpelling: String

    /// Creates a capability set.
    public init(
        supportsTransactions: Bool = false,
        supportsAlterColumn: Bool = false,
        supportsIndexes: Bool = true,
        reportsGeneratedKeys: Bool = false,
        operators: Set<BASICPredicateOperator> = Set(BASICPredicateOperator.allCases),
        booleanSpelling: String = "INTEGER"
    ) {
        self.supportsTransactions = supportsTransactions
        self.supportsAlterColumn = supportsAlterColumn
        self.supportsIndexes = supportsIndexes
        self.reportsGeneratedKeys = reportsGeneratedKeys
        self.operators = operators
        self.booleanSpelling = booleanSpelling
    }
}

/// Lifecycle and identity, shared by every database provider.
///
/// The two protocols below split relational from document. This one exists so
/// opening, closing and capability reporting are written once.
public protocol BASICDataProvider: AnyObject, Sendable {
    /// A short name for diagnostics: `SQLite`, `MongoDB`, `ODBC`.
    static var providerName: String { get }

    /// Whether this provider can exist on the platform this build targets (DB17).
    ///
    /// A *match*, not a constant scheme, because ODBC is a meta-provider
    /// fronting many databases and answers to `jdbc:` as well as its own forms
    /// (§5.4).
    static func handles(_ url: String) -> Bool

    /// Whether the provider is usable here at all.
    static var isAvailableOnThisPlatform: Bool { get }

    /// Why not, in one sentence, when it is not.
    static var unavailableMessage: String { get }

    /// What this connection can do. Resolved per connection, not per type.
    var capabilities: BASICDataCapabilities { get }

    /// Whether the provider is currently open.
    var isOpen: Bool { get }

    /// Opens a connection.
    func open(_ url: String) async throws

    /// Closes it. Safe to call when already closed.
    func close() async

    /// Whether the connection is still answering.
    func ping() async throws -> Bool
}

public extension BASICDataProvider {
    static var isAvailableOnThisPlatform: Bool { true }
    static var unavailableMessage: String { "" }

    /// Refuses at construction with a reason, rather than failing to link (DB17).
    static func requireAvailable() throws {
        guard isAvailableOnThisPlatform else {
            throw BASICDataError.unavailable(provider: providerName, reason: unavailableMessage)
        }
    }
}

/// One column of a result set.
public struct BASICResultColumn: Equatable, Sendable {
    /// The column name as the database reported it.
    public let name: String
    /// Its type, when the database reported one.
    public let type: BASICColumnType?

    /// Creates a result column.
    public init(name: String, type: BASICColumnType? = nil) {
        self.name = name
        self.type = type
    }
}

/// A live cursor over rows (DB22).
///
/// `next()` advances one row, so a million-row result costs one row of memory.
/// The connection stays busy until `close()`. A `BASICResultSet` outliving its
/// provider is an error: it is a cursor into a connection, not a copy.
public protocol BASICResultSet: AnyObject, Sendable {
    /// The columns, in selection order.
    var columns: [BASICResultColumn] { get }

    /// Advances to the next row. False when there are none left.
    func next() async throws -> Bool

    /// Reads the current row's value at a column index.
    func value(at index: Int) throws -> BASICDataValue

    /// Reads the current row's value by column name, case-insensitively.
    func value(named name: String) throws -> BASICDataValue

    /// Releases the cursor. Safe to call twice.
    func close() async
}

public extension BASICResultSet {
    /// Materializes the remaining rows and closes the cursor.
    ///
    /// For a program that wants to hold the results and free the connection, or
    /// run a second query while still reading the first (DB22).
    func toArray() async throws -> [[String: BASICDataValue]] {
        var rows: [[String: BASICDataValue]] = []
        while try await next() {
            var row: [String: BASICDataValue] = [:]
            for (index, column) in columns.enumerated() {
                row[column.name] = try value(at: index)
            }
            rows.append(row)
        }
        await close()
        return rows
    }
}

/// A statement compiled once and run many times (DB15).
///
/// Exposed rather than hidden: a program told to use it has a mechanical fix
/// when `security.sql_injection` fires, and the safe path is also the fast one.
public protocol BASICPreparedStatement: AnyObject, Sendable {
    /// The statement text, for diagnostics.
    var sql: String { get }

    /// Runs it, returning rows affected.
    func execute(_ parameters: [BASICDataValue]) async throws -> Int

    /// Runs it, returning a cursor.
    func query(_ parameters: [BASICDataValue]) async throws -> BASICResultSet

    /// Releases it.
    func close() async
}

/// A relational provider: SQLite, ODBC, and anything else that speaks SQL.
public protocol BASICSQLProvider: BASICDataProvider {
    /// Compiles a statement. Values are always bound, never interpolated (DB15).
    func prepare(_ sql: String) async throws -> BASICPreparedStatement

    /// Runs a statement once, returning rows affected.
    func execute(_ sql: String, _ parameters: [BASICDataValue]) async throws -> Int

    /// Runs a query once, returning a cursor.
    func query(_ sql: String, _ parameters: [BASICDataValue]) async throws -> BASICResultSet

    /// Quotes an identifier for this dialect: `"x"`, `` `x` ``, `[x]`.
    ///
    /// Placeholders bind values only, so a table or column name has to be
    /// interpolated — and in this plan those names are user input (DB15). This
    /// is the other half of that defense; validation is the first.
    func quoteIdentifier(_ name: String) -> String

    /// Begins a transaction, where the provider has them (DB14).
    func begin() async throws
    /// Commits one.
    func commit() async throws
    /// Rolls one back.
    func rollback() async throws

    /// The tables the database currently has.
    func tables() async throws -> [BASICTableSchema]

    /// Applies schema changes, each spelled by this provider for its dialect.
    func apply(_ changes: [BASICSchemaChange]) async throws
}

/// A document provider: MongoDB, and the in-memory reference store.
public protocol BASICDocumentProvider: BASICDataProvider {
    /// Inserts a document, returning the key the store assigned.
    func insert(collection: String, document: BASICDocument) async throws -> BASICDataValue

    /// Inserts or replaces the document with this key.
    func upsert(collection: String, key: BASICDataValue, document: BASICDocument) async throws

    /// Finds documents matching a *built* filter.
    ///
    /// Never a filter parsed from a program-supplied string: that is how
    /// operator injection gets in (`$gt`, `$ne`, `$where`) — DB15.
    func find(collection: String, filter: BASICQueryPredicate, limit: Int?) async throws -> [BASICDocument]

    /// Deletes matching documents, returning how many went.
    func delete(collection: String, filter: BASICQueryPredicate) async throws -> Int

    /// Ensures an index exists.
    func ensureIndex(collection: String, fields: [String], unique: Bool) async throws

    /// The collections the store currently has.
    func collections() async throws -> [String]
}
