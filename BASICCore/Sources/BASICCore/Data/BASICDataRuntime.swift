import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Holds one result across the blocking bridge.
private final class BASICDataResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    func store(_ value: Result<T, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func take() throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let result else { throw BASICDataError.driver("The database call produced no result") }
        return try result.get()
    }
}

/// The database pseudo classes, and the state behind them.
///
/// DB6 says both spellings, synchronous by default. This is the synchronous
/// half: the provider protocol is `async` so a driver never blocks the
/// runtime lane by accident, and the BASIC-facing call blocks on it — which
/// is the same shape `runProgramSynchronously` already uses.
final class BASICDataRuntime: @unchecked Sendable {

    private let lock = NSLock()
    private var sqlProviders: [Int: any BASICSQLProvider] = [:]
    private var documentProviders: [Int: any BASICDocumentProvider] = [:]
    private var recordsets: [Int: any BASICResultSet] = [:]
    private var recordsetRows: [Int: [String: BASICDataValue]] = [:]
    private var stores: [Int: BASICDataStore] = [:]
    private var nextID = 1

    init() {}

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Runs an async database call and waits for it.
    ///
    /// Safe here because no provider awaits back into the interpreter: SQLite
    /// is a C API that never suspends, and a networked provider is off on its
    /// own executor. A provider that called BASIC back would deadlock, which
    /// is why the protocols take values and hand values back.
    static func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BASICDataResultBox<T>()
        Task.detached {
            do {
                box.store(.success(try await body()))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.take()
    }

    /// Runs a database call and states its failure as the language does.
    ///
    /// `BASICDataError` is the data layer's own vocabulary, and the language has
    /// exactly one: a `BASICError.runtime` is what `ON ERROR` traps and what
    /// `ERR` reports. Without this an ordinary refusal -- a destructive schema
    /// change, a missing migration -- escaped as a Swift error the program could
    /// neither trap nor read.
    static func translating<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as BASICDataError {
            throw BASICError.runtime(error.description)
        }
    }

    // MARK: - Construction

    /// `SqlDatabase(url$)` — opens a relational provider chosen by the URL.
    func makeSQLDatabase(url: String) throws -> BASICValue {
        let provider: any BASICSQLProvider
        if BASICMemorySQLProvider.handles(url) {
            provider = BASICMemorySQLProvider()
        } else if BASICSQLiteProvider.handles(url) {
            try BASICSQLiteProvider.requireAvailable()
            provider = BASICSQLiteProvider()
        } else {
            throw BASICDataError.noProviderFor(url: url)
        }
        try Self.blocking { try await provider.open(url) }
        let id = locked { () -> Int in
            let id = nextID
            nextID += 1
            sqlProviders[id] = provider
            return id
        }
        return .systemObject("SqlDatabase", id)
    }

    /// `DocumentDatabase(url$)` — opens a document provider chosen by the URL.
    func makeDocumentDatabase(url: String) throws -> BASICValue {
        guard BASICMemoryDocumentProvider.handles(url) else {
            throw BASICDataError.noProviderFor(url: url)
        }
        let provider = BASICMemoryDocumentProvider()
        try Self.blocking { try await provider.open(url) }
        let id = locked { () -> Int in
            let id = nextID
            nextID += 1
            documentProviders[id] = provider
            return id
        }
        return .systemObject("DocumentDatabase", id)
    }

    /// `DataStore(database)` — the ORM over an already-open database.
    func makeDataStore(
        from database: BASICValue,
        enumeration: @escaping (String) -> BASICEnumDefinition?,
        invokeMigration: ((String) throws -> Void)? = nil
    ) throws -> BASICValue {
        guard case .systemObject(let typeName, let databaseID) = database else {
            throw BASICDataError.unsupported("DataStore takes a SqlDatabase or a DocumentDatabase")
        }
        let backend: BASICDataStore.Backend
        switch typeName.uppercased() {
        case "SQLDATABASE":
            guard let provider = locked({ sqlProviders[databaseID] }) else {
                throw BASICDataError.notConnected
            }
            backend = .sql(provider)
        case "DOCUMENTDATABASE":
            guard let provider = locked({ documentProviders[databaseID] }) else {
                throw BASICDataError.notConnected
            }
            backend = .document(provider)
        default:
            throw BASICDataError.unsupported("DataStore takes a SqlDatabase or a DocumentDatabase, not a \(typeName)")
        }
        let store = BASICDataStore(backend: backend, enumeration: enumeration)
        if let invokeMigration { store.setMigrationInvoker(invokeMigration) }
        let id = locked { () -> Int in
            let id = nextID
            nextID += 1
            stores[id] = store
            return id
        }
        return .systemObject("DataStore", id)
    }

    // MARK: - Dispatch

    func callSQLDatabase(id: Int, method: String, arguments: [BASICValue]) throws -> BASICValue {
        guard let provider = locked({ sqlProviders[id] }) else {
            throw BASICDataError.notConnected
        }
        switch method.uppercased() {
        case "EXECUTE":
            let (sql, parameters) = try Self.statement(arguments, method: "Execute")
            let affected = try Self.blocking { try await provider.execute(sql, parameters) }
            return .number(Double(affected))

        case "QUERY":
            let (sql, parameters) = try Self.statement(arguments, method: "Query")
            let cursor = try Self.blocking { try await provider.query(sql, parameters) }
            let id = locked { () -> Int in
                let id = nextID
                nextID += 1
                recordsets[id] = cursor
                return id
            }
            return .systemObject("Recordset", id)

        case "BEGIN":
            try Self.blocking { try await provider.begin() }
            return .empty
        case "COMMIT":
            try Self.blocking { try await provider.commit() }
            return .empty
        case "ROLLBACK":
            try Self.blocking { try await provider.rollback() }
            return .empty
        case "CLOSE":
            try Self.blocking { await provider.close() }
            locked { sqlProviders.removeValue(forKey: id) }
            return .empty
        default:
            throw BASICError.runtime("SqlDatabase has no method \(method)")
        }
    }

    func callDocumentDatabase(id: Int, method: String, arguments: [BASICValue]) throws -> BASICValue {
        guard let provider = locked({ documentProviders[id] }) else {
            throw BASICDataError.notConnected
        }
        switch method.uppercased() {
        case "CLOSE":
            try Self.blocking { await provider.close() }
            locked { documentProviders.removeValue(forKey: id) }
            return .empty
        case "COLLECTIONS", "COLLECTIONS$":
            let names = try Self.blocking { try await provider.collections() }
            return .string(BASICString(names.joined(separator: ",")))
        case "COUNT":
            let name = try Self.string(arguments.first, method: "Count")
            let found = try Self.blocking {
                try await provider.find(collection: name, filter: .all, limit: nil)
            }
            return .number(Double(found.count))
        default:
            throw BASICError.runtime("DocumentDatabase has no method \(method)")
        }
    }

    func callRecordset(id: Int, method: String, arguments: [BASICValue]) throws -> BASICValue {
        guard let cursor = locked({ recordsets[id] }) else {
            throw BASICDataError.driver("This Recordset is closed")
        }
        switch method.uppercased() {
        case "READ":
            let more = try Self.blocking { try await cursor.next() }
            if more {
                var row: [String: BASICDataValue] = [:]
                for (index, column) in cursor.columns.enumerated() {
                    row[column.name.uppercased()] = try cursor.value(at: index)
                }
                locked { recordsetRows[id] = row }
            } else {
                locked { recordsetRows[id] = nil }
            }
            return .boolean(more)

        case "TEXT", "TEXT$":
            let value = try currentValue(id: id, arguments: arguments, method: "Text$")
            return .string(BASICString(Self.text(of: value)))
        case "NUMBER":
            let value = try currentValue(id: id, arguments: arguments, method: "Number")
            return .number(Self.number(of: value) ?? 0)
        case "BOOLEAN":
            let value = try currentValue(id: id, arguments: arguments, method: "Boolean")
            return .boolean(value.booleanValue ?? false)
        case "ISNULL":
            return .boolean(try currentValue(id: id, arguments: arguments, method: "IsNull").isNull)

        case "COLUMNCOUNT":
            return .number(Double(cursor.columns.count))
        case "COLUMNNAME", "COLUMNNAME$":
            guard let index = arguments.first?.number.map(Int.init),
                  index >= 1, index <= cursor.columns.count else {
                throw BASICError.runtime("Recordset.ColumnName$ wants a column number from 1 to \(cursor.columns.count)")
            }
            return .string(BASICString(cursor.columns[index - 1].name))

        case "CLOSE":
            try Self.blocking { await cursor.close() }
            locked {
                recordsets.removeValue(forKey: id)
                recordsetRows.removeValue(forKey: id)
            }
            return .empty
        default:
            throw BASICError.runtime("Recordset has no method \(method)")
        }
    }

    func callDataStore(
        id: Int,
        method: String,
        arguments: [BASICValue],
        classDefinition: (String) -> BASICClassDefinition?
    ) throws -> BASICValue {
        guard let store = locked({ stores[id] }) else {
            throw BASICDataError.notConnected
        }

        /// Registers on demand, so `store.Save(c)` works with no ceremony —
        /// the object already knows its class (tier 0 of §3.1).
        func mapping(named className: String) throws -> BASICTableMapping {
            if let existing = try? store.mapping(for: className) { return existing }
            guard let definition = classDefinition(className) else {
                throw BASICError.runtime("Unknown CLASS \(className)")
            }
            return try store.register(definition)
        }

        switch method.uppercased() {
        case "REGISTER":
            let name = try Self.string(arguments.first, method: "Register")
            return .string(BASICString(try mapping(named: name).tableName))

        case "ENSURESCHEMA":
            let name = try Self.string(arguments.first, method: "EnsureSchema")
            let table = try mapping(named: name)
            let changes = try Self.blocking { try await store.ensureSchema(table) }
            return .number(Double(changes.count))

        case "DESCRIBE", "DESCRIBE$":
            let name = try Self.string(arguments.first, method: "Describe$")
            return .string(BASICString(store.describe(try mapping(named: name))))

        case "SAVE":
            guard let value = arguments.first, case .object(let typeName, _) = value else {
                throw BASICError.runtime("DataStore.Save wants an object")
            }
            let table = try mapping(named: typeName)
            return try Self.blocking { try await store.save(value, as: table) }

        case "LOAD":
            let name = try Self.string(arguments.first, method: "Load")
            guard arguments.count == 2 else {
                throw BASICError.runtime("DataStore.Load wants a class name and a key")
            }
            let table = try mapping(named: name)
            guard let key = table.keyColumn else {
                throw BASICError.runtime("CLASS \(name) has no key")
            }
            let keyValue = try BASICTableMapping.dataValue(arguments[1], for: key)
            let found = try Self.blocking { try await store.load(table, key: keyValue) }
            return found ?? .empty

        case "DELETE":
            let name = try Self.string(arguments.first, method: "Delete")
            guard arguments.count == 2 else {
                throw BASICError.runtime("DataStore.Delete wants a class name and a key")
            }
            let table = try mapping(named: name)
            guard let key = table.keyColumn else {
                throw BASICError.runtime("CLASS \(name) has no key")
            }
            let keyValue = try BASICTableMapping.dataValue(arguments[1], for: key)
            let removed = try Self.blocking {
                try await store.delete(table, matching: .compare(key.columnName, .equal, keyValue))
            }
            return .number(Double(removed))

        case "COUNT":
            let name = try Self.string(arguments.first, method: "Count")
            let table = try mapping(named: name)
            let found = try Self.blocking { try await store.find(table, matching: .all) }
            return .number(Double(found.count))

        case "BEGIN":
            try Self.blocking { try await store.begin() }
            return .empty
        case "COMMIT":
            try Self.blocking { try await store.commit() }
            return .empty
        case "ROLLBACK":
            try Self.blocking { try await store.rollback() }
            return .empty
        case "SUPPORTSTRANSACTIONS":
            return .boolean(store.supportsTransactions)

        case "MIGRATION":
            // Registered, never discovered: the name is an argument, so a
            // compiled program resolves it at build time from a known set
            // rather than by convention (D7, §1.5.1).
            guard arguments.count == 4 else {
                throw BASICError.runtime("DataStore.Migration wants a class name, a from version, a to version and a function name")
            }
            let className = try Self.string(arguments[0], method: "Migration")
            guard let from = arguments[1].number, let to = arguments[2].number,
                  from == from.rounded(), to == to.rounded() else {
                throw BASICError.runtime("DataStore.Migration wants whole version numbers")
            }
            let function = try Self.string(arguments[3], method: "Migration")
            // The class has to be one this store knows, so a typo in the name is
            // caught here rather than the next time EnsureSchema runs.
            _ = try mapping(named: className)
            try store.register(migration: BASICMigration(
                className: className, fromVersion: Int(from), toVersion: Int(to), functionName: function
            ))
            return .empty

        case "SCHEMAVERSION":
            let name = try Self.string(arguments.first, method: "SchemaVersion")
            let version = try Self.blocking { try await store.schemaVersion(of: name) }
            // -1 rather than EMPTY for "the database has never seen it": a
            // program comparing versions is doing arithmetic, and EMPTY reads
            // as 0, which is a real version (DB5).
            return .number(Double(version ?? -1))
        default:
            throw BASICError.runtime("DataStore has no method \(method)")
        }
    }

    // MARK: - Helpers

    private func currentValue(id: Int, arguments: [BASICValue], method: String) throws -> BASICDataValue {
        guard let row = locked({ recordsetRows[id] }) else {
            throw BASICError.runtime("Recordset.\(method) needs a successful Read first")
        }
        let name = try Self.string(arguments.first, method: method).uppercased()
        guard let value = row[name] else {
            throw BASICError.runtime("This Recordset has no column named \(name)")
        }
        return value
    }

    private static func statement(_ arguments: [BASICValue], method: String) throws -> (String, [BASICDataValue]) {
        guard let first = arguments.first, let sql = first.string else {
            throw BASICError.runtime("SqlDatabase.\(method) wants a SQL string")
        }
        // Every remaining argument is a *bound* parameter. There is no form of
        // this call that splices a value into the statement text (DB15).
        let parameters = try arguments.dropFirst().map(dataValue(of:))
        return (sql.description, parameters)
    }

    private static func dataValue(of value: BASICValue) throws -> BASICDataValue {
        switch value {
        case .empty, .null: return .null
        case .number(let number):
            return number == number.rounded() && abs(number) < 9.2e18
                ? .integer(Int64(number))
                : .double(number)
        case .string(let text): return .text(text.description)
        case .boolean(let flag): return .boolean(flag)
        default:
            throw BASICError.runtime("A \(value.description) cannot be a database parameter")
        }
    }

    private static func string(_ value: BASICValue?, method: String) throws -> String {
        guard let text = value?.string else {
            throw BASICError.runtime("\(method) wants a string")
        }
        return text.description
    }

    private static func text(of value: BASICDataValue) -> String {
        switch value {
        case .text(let text): return text
        case .integer(let number): return "\(number)"
        case .double(let number): return "\(number)"
        case .decimal(let number): return "\(number)"
        case .boolean(let flag): return flag ? "1" : "0"
        case .date(let date): return date.description
        case .time(let time): return time.description
        case .timestamp(let stamp): return stamp.description
        case .blob(let data): return data.base64EncodedString()
        case .null: return ""
        }
    }

    private static func number(of value: BASICDataValue) -> Double? {
        switch value {
        case .integer(let number): return Double(number)
        case .double(let number): return number
        case .decimal(let number): return NSDecimalNumber(decimal: number).doubleValue
        case .boolean(let flag): return flag ? 1 : 0
        case .text(let text): return Double(text)
        default: return nil
        }
    }
}
