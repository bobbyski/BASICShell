import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(SQLite3)
import SQLite3
#endif

/// The first real relational provider: SQLite, through the system library.
///
/// Deliberately first because it is cheap. `libsqlite3` ships with the SDK, so
/// this is a C shim with no SwiftPM dependency, no version pin, and nothing to
/// resolve — and it is the same shape ODBC will take at D10.
///
/// Connection strings: `sqlite://path`, `sqlite:path`, `:memory:`, or a bare
/// path.
public final class BASICSQLiteProvider: BASICSQLProvider, @unchecked Sendable {
    public static let providerName = "SQLite"

    public static func handles(_ url: String) -> Bool {
        let lowered = url.lowercased()
        if lowered.hasPrefix("sqlite:") || lowered.hasPrefix("file:") { return true }
        if lowered == ":memory:" { return true }
        return lowered.hasSuffix(".db") || lowered.hasSuffix(".sqlite") || lowered.hasSuffix(".sqlite3")
    }

    #if canImport(SQLite3)
    public static let isAvailableOnThisPlatform = true
    public static let unavailableMessage = ""
    #else
    public static let isAvailableOnThisPlatform = false
    public static let unavailableMessage =
        "SQLite is not available in this build: no SQLite3 module. Link a system libsqlite3."
    #endif

    private let lock = NSLock()
    #if canImport(SQLite3)
    private var handle: OpaquePointer?
    #endif

    /// Creates a closed provider.
    public init() {}

    #if canImport(SQLite3)
    deinit {
        // close() is async, so a provider that is simply dropped would leak
        // its sqlite3 handle. The C call is safe here and needs no lock: by
        // deinit nothing else can reach this object.
        if let handle { sqlite3_close(handle) }
    }
    #endif

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public var capabilities: BASICDataCapabilities {
        BASICDataCapabilities(
            supportsTransactions: true,
            // SQLite has no ALTER COLUMN. The table has to be rebuilt, which is
            // a destructive change D7 refuses rather than performing silently.
            supportsAlterColumn: false,
            supportsIndexes: true,
            reportsGeneratedKeys: true,
            // MATCHES wants a regex, and SQLite's REGEXP is an unregistered
            // hook by default. Refused when the predicate is built, rather
            // than failing at the wire (§7.1).
            operators: Set(BASICPredicateOperator.allCases).subtracting([.matches]),
            booleanSpelling: "INTEGER"
        )
    }

    // MARK: - Lifecycle

    #if canImport(SQLite3)

    public var isOpen: Bool { locked { handle != nil } }

    /// SQLite copies a bound string only when told to; the flag is not exposed
    /// to Swift, so it is spelled the way every Swift SQLite wrapper spells it.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public func open(_ url: String) async throws {
        try Self.requireAvailable()
        let path = Self.path(from: url)
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &opened, flags, nil) == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open \(path)"
            sqlite3_close(opened)
            throw BASICDataError.driver(message)
        }
        // Foreign keys are off by default in SQLite, which surprises everyone.
        sqlite3_exec(opened, "PRAGMA foreign_keys = ON", nil, nil, nil)
        locked { handle = opened }
    }

    public func close() async {
        let closing: OpaquePointer? = locked {
            defer { handle = nil }
            return handle
        }
        if let closing { sqlite3_close(closing) }
    }

    public func ping() async throws -> Bool {
        guard isOpen else { return false }
        _ = try await query("select 1", []).toArray()
        return true
    }

    /// Reads a path out of any of the accepted connection-string shapes.
    static func path(from url: String) -> String {
        if url.lowercased().hasPrefix("sqlite://") { return String(url.dropFirst("sqlite://".count)) }
        if url.lowercased().hasPrefix("sqlite:") { return String(url.dropFirst("sqlite:".count)) }
        return url
    }

    private func database() throws -> OpaquePointer {
        guard let handle = locked({ handle }) else { throw BASICDataError.notConnected }
        return handle
    }

    private func fail(_ database: OpaquePointer) -> BASICDataError {
        .driver(String(cString: sqlite3_errmsg(database)))
    }

    // MARK: - Statements

    public func quoteIdentifier(_ name: String) -> String {
        BASICSQLIdentifier.quotedDouble(name)
    }

    public func prepare(_ sql: String) async throws -> BASICPreparedStatement {
        let database = try database()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw fail(database)
        }
        return SQLitePreparedStatement(sql: sql, statement: statement, database: database)
    }

    public func execute(_ sql: String, _ parameters: [BASICDataValue]) async throws -> Int {
        let statement = try await prepare(sql)
        let affected = try await statement.execute(parameters)
        await statement.close()
        return affected
    }

    public func query(_ sql: String, _ parameters: [BASICDataValue]) async throws -> BASICResultSet {
        // The statement is not closed here on purpose: the cursor it returns
        // holds it, and releases it when the cursor goes.
        let statement = try await prepare(sql)
        return try await statement.query(parameters)
    }

    // MARK: - Transactions

    public func begin() async throws { _ = try await execute("BEGIN", []) }
    public func commit() async throws { _ = try await execute("COMMIT", []) }
    public func rollback() async throws { _ = try await execute("ROLLBACK", []) }

    // MARK: - Schema

    public func tables() async throws -> [BASICTableSchema] {
        let names = try await query(
            "select name from sqlite_master where type = 'table' and name not like 'sqlite_%' order by name",
            []
        ).toArray().compactMap { row -> String? in
            if case .text(let name)? = row["name"] { return name }
            return nil
        }

        var schemas: [BASICTableSchema] = []
        for name in names {
            let quoted = quoteIdentifier(name)
            let columns = try await query("PRAGMA table_info(\(quoted))", []).toArray().map { row -> BASICColumnSchema in
                let columnName = row["name"].flatMap { if case .text(let value) = $0 { return value } else { return nil } } ?? ""
                let declared = row["type"].flatMap { if case .text(let value) = $0 { return value } else { return nil } } ?? ""
                let notNull = (row["notnull"]?.booleanValue) ?? false
                let isKey = ((row["pk"].flatMap { if case .integer(let value) = $0 { return value } else { return nil } }) ?? 0) > 0
                return BASICColumnSchema(
                    name: columnName,
                    type: Self.columnType(declared: declared),
                    isNullable: !notNull,
                    isPrimaryKey: isKey,
                    // SQLite's generated key is a single INTEGER PRIMARY KEY,
                    // which aliases rowid. Anything else it will not fill in.
                    isGenerated: isKey && declared.uppercased().contains("INT")
                )
            }
            var indexes: [BASICIndexSchema] = []
            for row in try await query("PRAGMA index_list(\(quoted))", []).toArray() {
                guard case .text(let indexName)? = row["name"], !indexName.hasPrefix("sqlite_autoindex") else { continue }
                let unique = (row["unique"]?.booleanValue) ?? false
                let members = try await query("PRAGMA index_info(\(quoteIdentifier(indexName)))", [])
                    .toArray()
                    .compactMap { info -> String? in
                        if case .text(let member)? = info["name"] { return member }
                        return nil
                    }
                indexes.append(BASICIndexSchema(name: indexName, columns: members, isUnique: unique))
            }
            schemas.append(BASICTableSchema(name: name, columns: columns, indexes: indexes))
        }
        return schemas
    }

    public func apply(_ changes: [BASICSchemaChange]) async throws {
        for change in changes {
            for statement in try Self.statements(for: change, quote: quoteIdentifier) {
                _ = try await execute(statement, [])
            }
        }
    }

    #else

    public var isOpen: Bool { false }
    public func open(_ url: String) async throws { try Self.requireAvailable() }
    public func close() async {}
    public func ping() async throws -> Bool { false }
    public func quoteIdentifier(_ name: String) -> String { BASICSQLIdentifier.quotedDouble(name) }
    public func prepare(_ sql: String) async throws -> BASICPreparedStatement { try Self.requireAvailable(); throw BASICDataError.notConnected }
    public func execute(_ sql: String, _ parameters: [BASICDataValue]) async throws -> Int { try Self.requireAvailable(); throw BASICDataError.notConnected }
    public func query(_ sql: String, _ parameters: [BASICDataValue]) async throws -> BASICResultSet { try Self.requireAvailable(); throw BASICDataError.notConnected }
    public func begin() async throws { try Self.requireAvailable() }
    public func commit() async throws { try Self.requireAvailable() }
    public func rollback() async throws { try Self.requireAvailable() }
    public func tables() async throws -> [BASICTableSchema] { try Self.requireAvailable(); return [] }
    public func apply(_ changes: [BASICSchemaChange]) async throws { try Self.requireAvailable() }

    #endif

    // MARK: - Dialect

    /// SQLite's spelling for a logical column type.
    ///
    /// Two of these are decisions rather than lookups:
    ///
    /// - **`boolean` is `INTEGER`** (DB24), which is also SQLite's only option.
    /// - **`decimal` is `TEXT`.** SQLite's `NUMERIC` affinity converts a value
    ///   with a fraction to `REAL`, which is binary floating point — exactly
    ///   the rounding that made `DOUBLE` unacceptable for money in the first
    ///   place. Text round-trips a `Decimal` exactly. The cost is real and
    ///   worth naming: SQLite cannot sort or sum that column correctly. A
    ///   program doing arithmetic on money in the database wants a database
    ///   that has the type.
    static func typeSpelling(_ type: BASICColumnType) -> String {
        switch type {
        case .integer: return "INTEGER"
        case .double: return "REAL"
        case .decimal: return "TEXT"
        case .text: return "TEXT"
        case .blob: return "BLOB"
        case .boolean: return "INTEGER"
        // SQLite has no date types; ISO-8601 text is its own documented
        // convention, and it sorts chronologically, so predicates still work.
        case .date, .time, .timestamp: return "TEXT"
        }
    }

    /// Reads a declared type back, for introspection.
    static func columnType(declared: String) -> BASICColumnType {
        let upper = declared.uppercased()
        if upper.contains("INT") { return .integer }
        if upper.contains("REAL") || upper.contains("FLOA") || upper.contains("DOUB") { return .double }
        if upper.contains("BLOB") { return .blob }
        return .text(maximumLength: nil)
    }

    /// Lowers one structured change to SQLite statements.
    ///
    /// This is why `apply(_:)` takes values rather than SQL: the mapper says
    /// *boolean* and *decimal*, and this function decides what SQLite makes of
    /// them. A provider handed finished SQL would have to un-say it.
    static func statements(for change: BASICSchemaChange, quote: (String) -> String) throws -> [String] {
        func column(_ schema: BASICColumnSchema, includeKey: Bool) throws -> String {
            try BASICSQLIdentifier.validated(schema.name, describing: "column")
            var text = "\(quote(schema.name)) \(typeSpelling(schema.type))"
            if includeKey && schema.isPrimaryKey {
                text += " PRIMARY KEY"
                if schema.isGenerated { text += " AUTOINCREMENT" }
            }
            if !schema.isNullable { text += " NOT NULL" }
            if let names = schema.enumeratedNames, !names.isEmpty {
                let list = names.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
                text += " CHECK (\(quote(schema.name)) IN (\(list.joined(separator: ", "))))"
            }
            return text
        }

        switch change {
        case .createTable(let schema):
            try BASICSQLIdentifier.validated(schema.name, describing: "table")
            let keys = schema.primaryKeyColumns
            // SQLite spells a single integer key inline, because only that form
            // aliases rowid and gets filled in; a composite key is a table
            // constraint instead.
            let inlineKey = keys.count == 1
            var pieces = try schema.columns.map { try column($0, includeKey: inlineKey) }
            if keys.count > 1 {
                pieces.append("PRIMARY KEY (\(keys.map { quote($0.name) }.joined(separator: ", ")))")
            }
            var statements = ["CREATE TABLE \(quote(schema.name)) (\(pieces.joined(separator: ", ")))"]
            for index in schema.indexes {
                statements.append(contentsOf: try Self.statements(
                    for: .createIndex(table: schema.name, index: index),
                    quote: quote
                ))
            }
            return statements

        case .dropTable(let name):
            try BASICSQLIdentifier.validated(name, describing: "table")
            return ["DROP TABLE \(quote(name))"]

        case .addColumn(let table, let schema):
            try BASICSQLIdentifier.validated(table, describing: "table")
            return ["ALTER TABLE \(quote(table)) ADD COLUMN \(try column(schema, includeKey: false))"]

        case .dropColumn(let table, let name):
            try BASICSQLIdentifier.validated(table, describing: "table")
            try BASICSQLIdentifier.validated(name, describing: "column")
            return ["ALTER TABLE \(quote(table)) DROP COLUMN \(quote(name))"]

        case .alterColumn:
            throw BASICDataError.unsupported(
                "SQLite cannot alter a column in place; the table has to be rebuilt, which could lose data"
            )

        case .createIndex(let table, let index):
            try BASICSQLIdentifier.validated(table, describing: "table")
            try BASICSQLIdentifier.validated(index.name, describing: "index")
            for member in index.columns { try BASICSQLIdentifier.validated(member, describing: "column") }
            let unique = index.isUnique ? "UNIQUE " : ""
            let members = index.columns.map(quote).joined(separator: ", ")
            return ["CREATE \(unique)INDEX IF NOT EXISTS \(quote(index.name)) ON \(quote(table)) (\(members))"]

        case .dropIndex(_, let name):
            try BASICSQLIdentifier.validated(name, describing: "index")
            return ["DROP INDEX IF EXISTS \(quote(name))"]
        }
    }
}

#if canImport(SQLite3)

/// A `sqlite3_stmt`, compiled once and reset between runs (DB15).
private final class SQLitePreparedStatement: BASICPreparedStatement, @unchecked Sendable {
    let sql: String

    private let lock = NSLock()
    private var statement: OpaquePointer?
    private let database: OpaquePointer

    init(sql: String, statement: OpaquePointer, database: OpaquePointer) {
        self.sql = sql
        self.statement = statement
        self.database = database
    }

    deinit {
        if let statement { sqlite3_finalize(statement) }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ statement: OpaquePointer, _ parameters: [BASICDataValue]) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        let wanted = Int(sqlite3_bind_parameter_count(statement))
        guard parameters.count == wanted else {
            throw BASICDataError.driver("Statement wants \(wanted) parameters; \(parameters.count) supplied")
        }
        for (offset, value) in parameters.enumerated() {
            let position = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null:
                code = sqlite3_bind_null(statement, position)
            case .integer(let number):
                code = sqlite3_bind_int64(statement, position, number)
            case .double(let number):
                code = sqlite3_bind_double(statement, position, number)
            case .boolean(let flag):
                // DB24: a boolean is the dialect's integer, 0 or 1.
                code = sqlite3_bind_int64(statement, position, flag ? 1 : 0)
            case .decimal(let number):
                code = sqlite3_bind_text(statement, position, "\(number)", -1, Self.transient)
            case .text(let string):
                code = sqlite3_bind_text(statement, position, string, -1, Self.transient)
            case .date(let date):
                code = sqlite3_bind_text(statement, position, date.description, -1, Self.transient)
            case .time(let time):
                code = sqlite3_bind_text(statement, position, time.description, -1, Self.transient)
            case .timestamp(let stamp):
                code = sqlite3_bind_text(statement, position, stamp.description, -1, Self.transient)
            case .blob(let data):
                code = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, position, buffer.baseAddress, Int32(buffer.count), Self.transient)
                }
            }
            guard code == SQLITE_OK else {
                throw BASICDataError.driver(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    func execute(_ parameters: [BASICDataValue]) async throws -> Int {
        try locked {
            guard let statement else { throw BASICDataError.notConnected }
            try bind(statement, parameters)
            let code = sqlite3_step(statement)
            guard code == SQLITE_DONE || code == SQLITE_ROW else {
                throw BASICDataError.driver(String(cString: sqlite3_errmsg(database)))
            }
            sqlite3_reset(statement)
            return Int(sqlite3_changes(database))
        }
    }

    func query(_ parameters: [BASICDataValue]) async throws -> BASICResultSet {
        try locked {
            guard let statement else { throw BASICDataError.notConnected }
            try bind(statement, parameters)
            // The cursor holds `self`, not just the pointer. Without that the
            // prepared statement can be released while the cursor is still
            // reading, `deinit` finalizes the sqlite3_stmt, and every column
            // read is a use-after-free -- which is exactly how this first ran.
            return SQLiteResultSet(owner: self, statement: statement, database: database)
        }
    }

    func close() async {
        locked {
            if let statement { sqlite3_finalize(statement) }
            statement = nil
        }
    }
}

/// A real streaming cursor: one row at a time, straight from `sqlite3_step`.
private final class SQLiteResultSet: BASICResultSet, @unchecked Sendable {
    let columns: [BASICResultColumn]

    private let lock = NSLock()
    /// Keeps the compiled statement alive for as long as the cursor reads it.
    private let owner: AnyObject
    private let statement: OpaquePointer
    private let database: OpaquePointer
    private var exhausted = false

    init(owner: AnyObject, statement: OpaquePointer, database: OpaquePointer) {
        self.owner = owner
        self.statement = statement
        self.database = database
        self.columns = (0..<Int(sqlite3_column_count(statement))).map { index in
            let name = sqlite3_column_name(statement, Int32(index)).map { String(cString: $0) } ?? "column\(index)"
            let declared = sqlite3_column_decltype(statement, Int32(index)).map { String(cString: $0) }
            return BASICResultColumn(
                name: name,
                type: declared.map(BASICSQLiteProvider.columnType(declared:))
            )
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func next() async throws -> Bool {
        try locked {
            guard !exhausted else { return false }
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW { return true }
            exhausted = true
            sqlite3_reset(statement)
            guard code == SQLITE_DONE else {
                throw BASICDataError.driver(String(cString: sqlite3_errmsg(database)))
            }
            return false
        }
    }

    func value(at index: Int) throws -> BASICDataValue {
        try locked {
            guard index >= 0, index < columns.count else {
                throw BASICDataError.driver("No column at position \(index)")
            }
            let position = Int32(index)
            switch sqlite3_column_type(statement, position) {
            case SQLITE_NULL:
                return .null
            case SQLITE_INTEGER:
                return .integer(sqlite3_column_int64(statement, position))
            case SQLITE_FLOAT:
                return .double(sqlite3_column_double(statement, position))
            case SQLITE_BLOB:
                guard let bytes = sqlite3_column_blob(statement, position) else { return .blob(Data()) }
                let count = Int(sqlite3_column_bytes(statement, position))
                return .blob(Data(bytes: bytes, count: count))
            default:
                guard let text = sqlite3_column_text(statement, position) else { return .null }
                return .text(String(cString: text))
            }
        }
    }

    func value(named name: String) throws -> BASICDataValue {
        guard let position = columns.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw BASICDataError.driver("No column named \(name)")
        }
        return try value(at: position)
    }

    func close() async {
        locked {
            exhausted = true
            sqlite3_reset(statement)
        }
    }
}

#endif
