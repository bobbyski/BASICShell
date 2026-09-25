import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A cursor over rows already in hand.
///
/// The reference provider materializes, because its rows are already in memory
/// — but it still presents `BASICResultSet`'s cursor contract so the ORM is
/// written against a cursor from the first line (DB22). A driver-backed
/// provider streams behind the same protocol.
public final class BASICArrayResultSet: BASICResultSet, @unchecked Sendable {
    public let columns: [BASICResultColumn]

    private let lock = NSLock()
    private var rows: [[BASICDataValue]]
    private var index = -1
    private var closed = false

    /// Creates a cursor over rows, each in column order.
    public init(columns: [BASICResultColumn], rows: [[BASICDataValue]]) {
        self.columns = columns
        self.rows = rows
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public func next() async throws -> Bool {
        locked {
            guard !closed, index + 1 < rows.count else { return false }
            index += 1
            return true
        }
    }

    public func value(at index: Int) throws -> BASICDataValue {
        try locked {
            guard self.index >= 0, self.index < rows.count else {
                throw BASICDataError.driver("Read before the first row, or after the last")
            }
            guard index >= 0, index < columns.count else {
                throw BASICDataError.driver("No column at position \(index)")
            }
            return rows[self.index][index]
        }
    }

    public func value(named name: String) throws -> BASICDataValue {
        guard let position = columns.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw BASICDataError.driver("No column named \(name)")
        }
        return try value(at: position)
    }

    public func close() async {
        locked { closed = true }
    }
}

/// The reference relational provider: real, in memory, no dependency.
///
/// It understands exactly the statement shapes the ORM emits and refuses
/// anything else *by name* — it is a conformance, not a database. Building it
/// before SQLite is what stops SQLite's assumptions becoming the protocol's
/// (§10), and it is the conformance suite every later provider runs.
public final class BASICMemorySQLProvider: BASICSQLProvider, @unchecked Sendable {
    public static let providerName = "Memory"

    public static func handles(_ url: String) -> Bool {
        let lowered = url.lowercased()
        return lowered == "memory:" || lowered.hasPrefix("memory://")
    }

    private struct Table {
        var schema: BASICTableSchema
        var rows: [[String: BASICDataValue]] = []
        var nextGenerated: Int64 = 1
    }

    private let lock = NSLock()
    private var tableOrder: [String] = []
    private var store: [String: Table] = [:]
    private var savepoint: (order: [String], store: [String: Table])?
    private var open = false

    /// Creates an empty database.
    public init() {}

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public var capabilities: BASICDataCapabilities {
        BASICDataCapabilities(
            supportsTransactions: true,
            // Deliberately false, matching SQLite: the reference provider must
            // not let the ORM lean on something its first real peer lacks.
            supportsAlterColumn: false,
            supportsIndexes: true,
            reportsGeneratedKeys: true,
            booleanSpelling: "INTEGER"
        )
    }

    public var isOpen: Bool { locked { open } }

    public func open(_ url: String) async throws {
        try Self.requireAvailable()
        locked { open = true }
    }

    public func close() async {
        locked { open = false }
    }

    public func ping() async throws -> Bool { isOpen }

    public func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Transactions

    public func begin() async throws {
        try requireOpen()
        try locked {
            guard savepoint == nil else { throw BASICDataError.unsupported("nested transactions") }
            savepoint = (tableOrder, store)
        }
    }

    public func commit() async throws {
        try requireOpen()
        try locked {
            guard savepoint != nil else { throw BASICDataError.unsupported("commit without begin") }
            savepoint = nil
        }
    }

    public func rollback() async throws {
        try requireOpen()
        try locked {
            guard let savepoint else { throw BASICDataError.unsupported("rollback without begin") }
            tableOrder = savepoint.order
            store = savepoint.store
            self.savepoint = nil
        }
    }

    // MARK: - Schema

    public func tables() async throws -> [BASICTableSchema] {
        try requireOpen()
        return locked { tableOrder.compactMap { store[$0]?.schema } }
    }

    public func apply(_ changes: [BASICSchemaChange]) async throws {
        try requireOpen()
        try locked {
            for change in changes {
                switch change {
                case .createTable(let schema):
                    guard store[schema.name] == nil else {
                        throw BASICDataError.driver("Table \(schema.name) already exists")
                    }
                    store[schema.name] = Table(schema: schema)
                    tableOrder.append(schema.name)
                case .dropTable(let name):
                    store.removeValue(forKey: name)
                    tableOrder.removeAll { $0 == name }
                case .addColumn(let table, let column):
                    try mutate(table) { entry in
                        entry.schema = BASICTableSchema(
                            name: entry.schema.name,
                            columns: entry.schema.columns + [column],
                            indexes: entry.schema.indexes
                        )
                        for index in entry.rows.indices where entry.rows[index][column.name] == nil {
                            entry.rows[index][column.name] = .null
                        }
                    }
                case .dropColumn(let table, let column):
                    try mutate(table) { entry in
                        entry.schema = BASICTableSchema(
                            name: entry.schema.name,
                            columns: entry.schema.columns.filter { $0.name != column },
                            indexes: entry.schema.indexes
                        )
                        for index in entry.rows.indices {
                            entry.rows[index].removeValue(forKey: column)
                        }
                    }
                case .alterColumn:
                    throw BASICDataError.unsupported("\(Self.providerName) cannot alter a column in place")
                case .createIndex(let table, let index):
                    try mutate(table) { entry in
                        guard !entry.schema.indexes.contains(where: { $0.name == index.name }) else { return }
                        entry.schema = BASICTableSchema(
                            name: entry.schema.name,
                            columns: entry.schema.columns,
                            indexes: entry.schema.indexes + [index]
                        )
                    }
                case .dropIndex(let table, let name):
                    try mutate(table) { entry in
                        entry.schema = BASICTableSchema(
                            name: entry.schema.name,
                            columns: entry.schema.columns,
                            indexes: entry.schema.indexes.filter { $0.name != name }
                        )
                    }
                }
            }
        }
    }

    private func mutate(_ table: String, _ body: (inout Table) throws -> Void) throws {
        guard var entry = store[table] else { throw BASICDataError.noSuchTable(table) }
        try body(&entry)
        store[table] = entry
    }

    // MARK: - Statements

    public func prepare(_ sql: String) async throws -> BASICPreparedStatement {
        try requireOpen()
        let statement = try MemorySQLParser.parse(sql)
        return MemoryPreparedStatement(sql: sql, statement: statement, provider: self)
    }

    public func execute(_ sql: String, _ parameters: [BASICDataValue]) async throws -> Int {
        let statement = try await prepare(sql)
        let affected = try await statement.execute(parameters)
        await statement.close()
        return affected
    }

    public func query(_ sql: String, _ parameters: [BASICDataValue]) async throws -> BASICResultSet {
        let statement = try await prepare(sql)
        return try await statement.query(parameters)
    }

    // MARK: - Execution

    fileprivate func run(_ statement: MemorySQLStatement, _ parameters: [BASICDataValue]) throws -> (affected: Int, result: BASICArrayResultSet?) {
        try requireOpen()
        return try locked {
            guard var entry = store[statement.table] else {
                throw BASICDataError.noSuchTable(statement.table)
            }
            defer { store[statement.table] = entry }

            switch statement {
            case .insert(_, let columns, let values, let returning):
                var row: [String: BASICDataValue] = [:]
                for column in entry.schema.columns { row[column.name] = .null }
                for (name, term) in zip(columns, values) {
                    guard let column = entry.schema.column(named: name) else {
                        throw BASICDataError.noSuchColumn(name, table: entry.schema.name)
                    }
                    row[column.name] = coerce(try term.bound(parameters), to: column.type)
                }
                for column in entry.schema.columns where column.isGenerated {
                    if row[column.name]?.isNull ?? true {
                        row[column.name] = .integer(entry.nextGenerated)
                        entry.nextGenerated += 1
                    }
                }
                entry.rows.append(row)
                guard !returning.isEmpty else { return (1, nil) }
                let result = BASICArrayResultSet(
                    columns: returning.map { BASICResultColumn(name: $0, type: entry.schema.column(named: $0)?.type) },
                    rows: [returning.map { row[$0] ?? .null }]
                )
                return (1, result)

            case .update(_, let assignments, let condition):
                let predicate = try condition.bound(parameters)
                var affected = 0
                for index in entry.rows.indices {
                    guard BASICPredicateEvaluator.matches(predicate, { entry.rows[index][$0] }) else { continue }
                    for (name, term) in assignments {
                        guard let column = entry.schema.column(named: name) else {
                            throw BASICDataError.noSuchColumn(name, table: entry.schema.name)
                        }
                        entry.rows[index][column.name] = coerce(try term.bound(parameters), to: column.type)
                    }
                    affected += 1
                }
                return (affected, nil)

            case .delete(_, let condition):
                let predicate = try condition.bound(parameters)
                let before = entry.rows.count
                entry.rows.removeAll { row in BASICPredicateEvaluator.matches(predicate, { row[$0] }) }
                return (before - entry.rows.count, nil)

            case .select(let columns, _, let condition, let orderBy, let limit):
                let predicate = try condition.bound(parameters)
                var matched = entry.rows.filter { row in
                    BASICPredicateEvaluator.matches(predicate, { row[$0] })
                }
                for term in orderBy.reversed() {
                    matched.sort { left, right in
                        let order = BASICPredicateEvaluator.order(
                            left[term.column] ?? .null,
                            right[term.column] ?? .null
                        ) ?? 0
                        return term.ascending ? order < 0 : order > 0
                    }
                }
                if let limit, matched.count > limit {
                    matched = Array(matched.prefix(limit))
                }
                let names = columns ?? entry.schema.columns.map(\.name)
                for name in names where entry.schema.column(named: name) == nil {
                    throw BASICDataError.noSuchColumn(name, table: entry.schema.name)
                }
                let result = BASICArrayResultSet(
                    columns: names.map { BASICResultColumn(name: $0, type: entry.schema.column(named: $0)?.type) },
                    rows: matched.map { row in names.map { row[$0] ?? .null } }
                )
                return (matched.count, result)
            }
        }
    }

    /// Stores a value the way a real SQL store would.
    ///
    /// A boolean becomes the dialect's integer (DB24), so reading it back gives
    /// an integer — which is exactly the permissive-read path §7.2 describes,
    /// exercised by the reference provider rather than only by a real driver.
    private func coerce(_ value: BASICDataValue, to type: BASICColumnType) -> BASICDataValue {
        switch (value, type) {
        case (.boolean(let flag), .boolean), (.boolean(let flag), .integer):
            return .integer(flag ? 1 : 0)
        case (.integer(let number), .double):
            return .double(Double(number))
        case (.integer(let number), .decimal):
            return .decimal(Decimal(number))
        case (.double(let number), .decimal):
            return .decimal(Decimal(number))
        default:
            return value
        }
    }

    private func requireOpen() throws {
        guard isOpen else { throw BASICDataError.notConnected }
    }
}

/// A statement compiled once and run many times (DB15).
private final class MemoryPreparedStatement: BASICPreparedStatement, @unchecked Sendable {
    let sql: String
    private let statement: MemorySQLStatement
    private weak var provider: BASICMemorySQLProvider?

    init(sql: String, statement: MemorySQLStatement, provider: BASICMemorySQLProvider) {
        self.sql = sql
        self.statement = statement
        self.provider = provider
    }

    func execute(_ parameters: [BASICDataValue]) async throws -> Int {
        guard let provider else { throw BASICDataError.notConnected }
        return try provider.run(statement, parameters).affected
    }

    func query(_ parameters: [BASICDataValue]) async throws -> BASICResultSet {
        guard let provider else { throw BASICDataError.notConnected }
        guard statement.isQuery else {
            throw BASICDataError.unsupported("this statement returns no rows: \(sql)")
        }
        guard let result = try provider.run(statement, parameters).result else {
            throw BASICDataError.driver("Statement produced no result set: \(sql)")
        }
        return result
    }

    func close() async {}
}
