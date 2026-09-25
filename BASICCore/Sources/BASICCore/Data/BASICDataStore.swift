import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The ORM: saves a BASIC object to any compliant provider.
///
/// A convenience, not a gate. A program that wants SQL writes SQL through
/// `BASICSQLProvider`; this is for a program that would rather never mention a
/// table. Both reach the same database.
///
/// `Save` writes immediately (DB23) — no unit of work, no `SaveChanges`.
/// Atomicity is explicit: `begin` / `commit` / `rollback`, honored where the
/// provider has them and reported where it does not (DB14).
final class BASICDataStore: @unchecked Sendable {

    /// Which kind of provider is underneath.
    enum Backend {
        case sql(any BASICSQLProvider)
        case document(any BASICDocumentProvider)

        var provider: any BASICDataProvider {
            switch self {
            case .sql(let provider): return provider
            case .document(let provider): return provider
            }
        }
    }

    /// The provider this store writes to.
    let backend: Backend

    private let lock = NSLock()
    private var mappings: [String: BASICTableMapping] = [:]
    /// Not `@Sendable`: `BASICEnumDefinition` is not Sendable, and the class
    /// is already `@unchecked Sendable` because its mutable state is behind a
    /// lock. The closure is only ever called from inside that boundary.
    private let enumeration: (String) -> BASICEnumDefinition?
    /// Registered migrations, newest registration winning for a given step.
    private var migrations: [String: BASICMigration] = [:]
    /// How a migration gets back into the program: a BASIC function, by name.
    ///
    /// Injected because `BASICCore` has no route to either engine's call
    /// machinery — the interpreter passes its `callNamedHandler`, and a compiled
    /// program passes the host's trampoline table. The same seam the TUI binding
    /// already uses, for the same reason.
    private var invoke: ((String) throws -> Void)?
    /// Whether the ledger has been created in this session.
    private var ledgerExists = false

    /// Creates a store over a provider.
    init(backend: Backend, enumeration: @escaping (String) -> BASICEnumDefinition? = { _ in nil }) {
        self.backend = backend
        self.enumeration = enumeration
    }

    /// Sets how a registered migration reaches the program.
    func setMigrationInvoker(_ invoke: @escaping (String) throws -> Void) {
        locked { self.invoke = invoke }
    }

    // MARK: - Migrations (D7)

    /// Registers the function that takes a class from one version to the next.
    func register(migration: BASICMigration) throws {
        guard migration.toVersion == migration.fromVersion + 1 else {
            throw BASICDataError.unsupported(
                "a migration goes up one version at a time; \(migration.className) \(migration.fromVersion) to \(migration.toVersion) skips \(migration.toVersion - migration.fromVersion - 1)"
            )
        }
        guard migration.toVersion > migration.fromVersion else {
            throw BASICDataError.unsupported("migration is forward only; \(migration.className) cannot go from \(migration.fromVersion) to \(migration.toVersion)")
        }
        locked { migrations[Self.step(migration.className, migration.fromVersion)] = migration }
    }

    private static func step(_ className: String, _ from: Int) -> String {
        "\(className.uppercased())#\(from)"
    }

    /// The chain from `current` to `wanted`, or the step that is missing.
    func migrationPath(for className: String, from current: Int, to wanted: Int) throws -> [BASICMigration] {
        var path: [BASICMigration] = []
        var version = current
        while version < wanted {
            guard let migration = locked({ migrations[Self.step(className, version)] }) else {
                throw BASICDataError.unsupported(
                    "\(className) is at version \(version) in the database and \(wanted) in the program, and no migration is registered for \(version) to \(version + 1)"
                )
            }
            path.append(migration)
            version = migration.toVersion
        }
        return path
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Whether the provider honors transactions (DB14).
    var supportsTransactions: Bool { backend.provider.capabilities.supportsTransactions }

    // MARK: - Registration

    /// Registers a class, deriving its table from whatever the class already is.
    ///
    /// This is tier 0 of §3.1 when the class has no markers: "I want to store
    /// this object", and nothing else. The tiers above it need no different
    /// call — the mapper picks the most specific one the class offers.
    @discardableResult
    func register(_ definition: BASICClassDefinition, tableName: String? = nil) throws -> BASICTableMapping {
        let mapping = try BASICObjectMapper.map(definition, tableName: tableName, enumeration: enumeration)
        locked { mappings[definition.normalizedName] = mapping }
        return mapping
    }

    /// The mapping for a registered class.
    func mapping(for className: String) throws -> BASICTableMapping {
        guard let mapping = locked({ mappings[className.uppercased()] }) else {
            throw BASICDataError.unsupported("CLASS \(className) has not been registered with this store")
        }
        return mapping
    }

    /// The schema the store inferred, as pasteable tier-2 annotations.
    ///
    /// Tier 0 exists so a first program works in one line; this is the way up
    /// from it, made visible rather than described (§3.1).
    func describe(_ mapping: BASICTableMapping) -> String {
        var lines = ["' \(mapping.className) -> \(mapping.tableName)  (tier: \(mapping.tier.rawValue), version \(mapping.version))"]
        lines.append("class \(mapping.className)")
        for column in mapping.columns {
            var marker = "database"
            if column.columnName != column.fieldName { marker += " name \"\(column.columnName)\"" }
            if column.isKey { marker += " key" }
            else if let index = mapping.schema.indexes.first(where: { $0.columns == [column.columnName] }) {
                marker += index.isUnique ? " unique" : " index"
            }
            lines.append("    public \(column.fieldName) as \(Self.basicTypeName(column.basicType)) \(marker)")
        }
        lines.append("end class")
        return lines.joined(separator: "\n")
    }

    private static func basicTypeName(_ type: BASICType) -> String {
        switch type {
        case .scalar(let scalar): return scalar.rawValue.lowercased()
        case .enumType(let name), .record(let name), .classType(let name),
             .interfaceType(let name), .functionType(let name):
            return name
        case .dictionary: return "dictionary"
        case .void: return "variant"
        }
    }

    // MARK: - Schema

    /// Brings the database's shape up to the class's, and refuses to guess.
    ///
    /// A change it can apply safely — a new table, a new column, a new index —
    /// it applies. A change that could lose data it refuses, naming each one
    /// (D7). `basicc db schema` is for reviewing the difference offline;
    /// this is for a program that wants its table to exist.
    @discardableResult
    func ensureSchema(_ mapping: BASICTableMapping) async throws -> [BASICSchemaChange] {
        let changes = try await applySchema(mapping)
        try await reconcileVersion(mapping)
        return changes
    }

    /// Brings the *version* up to the class's, running registered migrations.
    ///
    /// Read before written, and refused rather than guessed at in three cases:
    /// a database ahead of the program (migration is forward only), a missing
    /// step in the chain, and a shape that changed with no version bump. The
    /// last one is why the checksum is stored at all.
    private func reconcileVersion(_ mapping: BASICTableMapping) async throws {
        let shape = BASICSchemaLedger.shape(of: mapping)
        guard let record = try await schemaRecord(for: mapping.className) else {
            // First time: record where we are. An unversioned class recording
            // version 0 is a legitimate starting state, not an error (DB5).
            try await writeSchemaRecord(BASICSchemaRecord(
                className: mapping.className, version: mapping.version,
                appliedAt: BASICSchemaLedger.timestamp(), shape: shape
            ))
            return
        }

        if record.version > mapping.version {
            throw BASICDataError.unsupported(
                "the database holds \(mapping.className) at version \(record.version) and the program is at \(mapping.version); migration is forward only"
            )
        }

        if record.version == mapping.version {
            guard record.shape == shape else {
                // The checksum is the safety net only where introspection
                // cannot reach. A relational provider was just compared against
                // the live table by `applySchema`, which is strictly better than
                // a checksum: it applies the safe changes and refuses the
                // destructive ones *by name*. Refusing here as well would refuse
                // adding a column, which the plan calls safe and means it.
                //
                // A document store has no shape to introspect at all, so there
                // the checksum is the only thing that can notice a field renamed
                // or retyped with no version bump -- exactly the deliberate,
                // dangerous change DB2 leaves behind.
                if case .document = backend {
                    // Which change, not just that there was one: adding a field
                    // to a schemaless store is free, and refusing it would make
                    // the ledger worse than no ledger. What cannot be waved
                    // through is a column that *was* there and is not, or one
                    // whose type moved -- a rename reads as both.
                    let before = BASICSchemaLedger.columns(in: record.shape)
                    let now = BASICSchemaLedger.columns(in: shape)
                    var refused: [String] = []
                    for (name, type) in before {
                        guard let current = now[name] else {
                            refused.append("\(mapping.className).\(name) was stored and is no longer in the class")
                            continue
                        }
                        if current != type {
                            refused.append("\(mapping.className).\(name) was stored as \(type) and the class now wants \(current)")
                        }
                    }
                    guard refused.isEmpty else {
                        throw BASICDataError.destructiveChangeRefused(
                            refused + ["bump meta { version: \(mapping.version + 1) } and register a migration"]
                        )
                    }
                }
                // Safe, applied, and now recorded: the ledger tracks what is
                // there rather than what was there first.
                try await writeSchemaRecord(BASICSchemaRecord(
                    className: mapping.className, version: mapping.version,
                    appliedAt: BASICSchemaLedger.timestamp(), shape: shape
                ))
                return
            }
            return
        }

        // Behind: plan the whole chain before running any of it, so a missing
        // step is a refusal rather than a half-migrated database.
        let path = try migrationPath(for: mapping.className, from: record.version, to: mapping.version)
        guard let invoke = locked({ self.invoke }) else {
            throw BASICDataError.unsupported(
                "\(mapping.className) needs \(path.count) migration(s) and this store has no way to call one"
            )
        }
        for migration in path {
            try invoke(migration.functionName)
            try await writeSchemaRecord(BASICSchemaRecord(
                className: mapping.className, version: migration.toVersion,
                appliedAt: BASICSchemaLedger.timestamp(), shape: shape
            ))
        }
    }

    /// The version the database holds for a class, or nil when it holds none.
    func schemaVersion(of className: String) async throws -> Int? {
        try await schemaRecord(for: className)?.version
    }

    private func schemaRecord(for className: String) async throws -> BASICSchemaRecord? {
        try await ensureLedger()
        let filter = BASICQueryPredicate.compare("class_name", .equal, .text(className))
        switch backend {
        case .document(let provider):
            let found = try await provider.find(
                collection: BASICSchemaLedger.tableName, filter: filter, limit: 1
            )
            guard let document = found.first else { return nil }
            return Self.record(from: BASICSchemaLedger.schema.columns.reduce(into: [:]) {
                $0[$1.name] = document.scalar($1.name) ?? .null
            })
        case .sql(let provider):
            let quote = provider.quoteIdentifier
            let clause = try BASICSQLPredicateLowering.lower(
                filter, quote: quote, supported: provider.capabilities.operators
            )
            let columns = BASICSchemaLedger.schema.columns.map { quote($0.name) }.joined(separator: ", ")
            let sql = "SELECT \(columns) FROM \(quote(BASICSchemaLedger.tableName)) WHERE \(clause.sql) LIMIT 1"
            let rows = try await provider.query(sql, clause.parameters).toArray()
            guard let row = rows.first else { return nil }
            return Self.record(from: row)
        }
    }

    private static func record(from row: [String: BASICDataValue]) -> BASICSchemaRecord? {
        func text(_ name: String) -> String {
            if case .text(let value) = row[name] ?? .null { return value }
            return ""
        }
        guard case .integer(let version) = row["version"] ?? .null else { return nil }
        return BASICSchemaRecord(
            className: text("class_name"), version: Int(version),
            appliedAt: text("applied_at"), shape: text("shape")
        )
    }

    private func writeSchemaRecord(_ record: BASICSchemaRecord) async throws {
        try await ensureLedger()
        let values: [(String, BASICDataValue)] = [
            ("class_name", .text(record.className)),
            ("version", .integer(Int64(record.version))),
            ("applied_at", .text(record.appliedAt)),
            ("shape", .text(record.shape)),
        ]
        switch backend {
        case .document(let provider):
            var document = BASICDocument()
            for (name, value) in values { document.setScalar(name, value) }
            try await provider.upsert(
                collection: BASICSchemaLedger.tableName,
                key: .text(record.className), document: document
            )
        case .sql(let provider):
            let quote = provider.quoteIdentifier
            let table = quote(BASICSchemaLedger.tableName)
            let updated = try await provider.execute(
                "UPDATE \(table) SET \(values.dropFirst().map { "\(quote($0.0)) = ?" }.joined(separator: ", ")) WHERE \(quote("class_name")) = ?",
                values.dropFirst().map(\.1) + [.text(record.className)]
            )
            guard updated == 0 else { return }
            try await provider.execute(
                "INSERT INTO \(table) (\(values.map { quote($0.0) }.joined(separator: ", "))) VALUES (\(values.map { _ in "?" }.joined(separator: ", ")))",
                values.map(\.1)
            )
        }
    }

    /// Creates the ledger if it is not there. Idempotent, and cheap after the
    /// first call — a store is one connection, so this is once per process.
    private func ensureLedger() async throws {
        if locked({ ledgerExists }) { return }
        switch backend {
        case .document(let provider):
            try await provider.ensureIndex(
                collection: BASICSchemaLedger.tableName, fields: ["class_name"], unique: true
            )
        case .sql(let provider):
            let present = try await provider.tables().contains {
                $0.name.caseInsensitiveCompare(BASICSchemaLedger.tableName) == .orderedSame
            }
            if !present {
                try await provider.apply([.createTable(BASICSchemaLedger.schema)])
            }
        }
        locked { ledgerExists = true }
    }

    /// Brings the database's *shape* up to the class's, and refuses to guess.
    private func applySchema(_ mapping: BASICTableMapping) async throws -> [BASICSchemaChange] {
        switch backend {
        case .document(let provider):
            for index in mapping.schema.indexes {
                try await provider.ensureIndex(
                    collection: mapping.tableName,
                    fields: index.columns,
                    unique: index.isUnique
                )
            }
            return []

        case .sql(let provider):
            let existing = try await provider.tables()
                .first { $0.name.caseInsensitiveCompare(mapping.tableName) == .orderedSame }

            guard let existing else {
                let changes = [BASICSchemaChange.createTable(mapping.schema)]
                try await provider.apply(changes)
                return changes
            }

            var safe: [BASICSchemaChange] = []
            var refused: [String] = []

            for column in mapping.schema.columns {
                guard let current = existing.column(named: column.name) else {
                    safe.append(.addColumn(table: mapping.tableName, column: column))
                    continue
                }
                if !Self.storageSatisfies(existing: current.type, wanted: column.type) {
                    refused.append(
                        "\(mapping.tableName).\(column.name) is \(current.type) and the class wants \(column.type)"
                    )
                }
            }
            for current in existing.columns
            where mapping.schema.column(named: current.name) == nil {
                refused.append("\(mapping.tableName).\(current.name) is in the database and not in \(mapping.className)")
            }
            for index in mapping.schema.indexes
            where !existing.indexes.contains(where: { $0.name == index.name }) {
                safe.append(.createIndex(table: mapping.tableName, index: index))
            }

            guard refused.isEmpty else {
                throw BASICDataError.destructiveChangeRefused(refused)
            }
            if !safe.isEmpty { try await provider.apply(safe) }
            return safe
        }
    }

    /// Whether a column already in the database can hold what the class wants.
    ///
    /// Introspection reports what the *dialect* stored, which is not always
    /// what the mapper asked for — and that is by design, not by accident.
    /// DB24 writes a boolean as an integer, so SQLite reads it back as one;
    /// SQLite has no decimal or date types, so those come back as text. A
    /// literal comparison would call every one of those a destructive change
    /// and refuse a schema it had just created itself.
    static func storageSatisfies(existing: BASICColumnType, wanted: BASICColumnType) -> Bool {
        if existing == wanted { return true }
        switch (existing, wanted) {
        case (.integer, .boolean), (.boolean, .integer):
            return true
        case (.text, .text):
            // Introspection rarely reports a length, and narrowing one is a
            // separate concern from the type being wrong.
            return true
        case (.text, .decimal), (.text, .date), (.text, .time), (.text, .timestamp):
            return true
        case (.double, .decimal), (.decimal, .double):
            return true
        default:
            return false
        }
    }

    // MARK: - Writing

    /// Writes an object, returning it with any generated key filled in.
    @discardableResult
    func save(_ value: BASICValue, as mapping: BASICTableMapping) async throws -> BASICValue {
        guard case .object(let typeName, var fields) = value else {
            throw BASICDataError.unsupported("Expected an object of CLASS \(mapping.className)")
        }
        guard let key = mapping.keyColumn else {
            throw BASICDataError.unsupported(
                "CLASS \(mapping.className) has no key, so it cannot be saved by identity"
            )
        }

        let currentKey = fields[key.normalizedFieldName] ?? .empty
        let hasKey = try !Self.keyIsAbsent(currentKey, generated: key.isGenerated)

        switch backend {
        case .document(let provider):
            var document = BASICDocument()
            for entry in try mapping.row(from: value, enumeration: enumeration) {
                document.setScalar(entry.column, entry.value)
            }
            if hasKey {
                let keyValue = try BASICTableMapping.dataValue(currentKey, for: key, enumeration: enumeration)
                try await provider.upsert(collection: mapping.tableName, key: keyValue, document: document)
            } else {
                // Insert without the key so the store assigns one, then write
                // it back into the document under the *mapping's* column name.
                // Otherwise the key lives only in the store's own _id and a
                // later find on the class's key column matches nothing.
                document[key.columnName] = nil
                let assigned = try await provider.insert(collection: mapping.tableName, document: document)
                document.setScalar(key.columnName, assigned)
                try await provider.upsert(collection: mapping.tableName, key: assigned, document: document)
                fields[key.normalizedFieldName] = try BASICTableMapping.basicValue(
                    assigned, for: key, enumeration: enumeration
                )
            }
            return .object(typeName, fields)

        case .sql(let provider):
            let quote = provider.quoteIdentifier
            if hasKey {
                // Update first; if nothing matched, this is an insert with a
                // key the program chose.
                let row = try mapping.row(from: value, enumeration: enumeration)
                    .filter { $0.column != key.columnName }
                if !row.isEmpty {
                    let assignments = row.map { "\(quote($0.column)) = ?" }.joined(separator: ", ")
                    let keyValue = try BASICTableMapping.dataValue(currentKey, for: key, enumeration: enumeration)
                    let affected = try await provider.execute(
                        "UPDATE \(quote(mapping.tableName)) SET \(assignments) WHERE \(quote(key.columnName)) = ?",
                        row.map(\.value) + [keyValue]
                    )
                    if affected > 0 { return .object(typeName, fields) }
                }
            }

            let row = try mapping.row(from: value, includingKey: !key.isGenerated || hasKey, enumeration: enumeration)
            let columns = row.map { quote($0.column) }.joined(separator: ", ")
            let placeholders = row.map { _ in "?" }.joined(separator: ", ")
            let sql = "INSERT INTO \(quote(mapping.tableName)) (\(columns)) VALUES (\(placeholders))"

            if key.isGenerated && !hasKey {
                let cursor = try await provider.query(sql + " RETURNING \(quote(key.columnName))", row.map(\.value))
                if try await cursor.next() {
                    let assigned = try cursor.value(at: 0)
                    fields[key.normalizedFieldName] = try BASICTableMapping.basicValue(
                        assigned, for: key, enumeration: enumeration
                    )
                }
                await cursor.close()
            } else {
                _ = try await provider.execute(sql, row.map(\.value))
            }
            return .object(typeName, fields)
        }
    }

    /// Whether a key field holds nothing the database could look up.
    ///
    /// A generated integer key counts 0 as absent, because that is what an
    /// object built by `NEW` holds before it has ever been saved.
    private static func keyIsAbsent(_ value: BASICValue, generated: Bool) throws -> Bool {
        switch value {
        case .empty, .null:
            return true
        case .number(let number):
            return generated && number == 0
        case .string(let text):
            return text.description.isEmpty
        default:
            return false
        }
    }

    // MARK: - Reading

    /// Loads one object by key, or nil when there is none.
    func load(_ mapping: BASICTableMapping, key value: BASICDataValue) async throws -> BASICValue? {
        guard let key = mapping.keyColumn else {
            throw BASICDataError.unsupported("CLASS \(mapping.className) has no key")
        }
        let found = try await find(mapping, matching: .compare(key.columnName, .equal, value), limit: 1)
        return found.first
    }

    /// Finds objects matching a predicate.
    ///
    /// The predicate names *class fields*; they are translated to column names
    /// here, so a program never has to know whether `DATABASE NAME` renamed
    /// anything (§7.1).
    func find(
        _ mapping: BASICTableMapping,
        matching predicate: BASICQueryPredicate,
        limit: Int? = nil
    ) async throws -> [BASICValue] {
        let columnPredicate = try translate(predicate, for: mapping)

        switch backend {
        case .document(let provider):
            let documents = try await provider.find(
                collection: mapping.tableName,
                filter: columnPredicate,
                limit: limit
            )
            return try documents.map { document in
                var row: [String: BASICDataValue] = [:]
                for column in mapping.columns {
                    row[column.columnName] = document.scalar(column.columnName) ?? .null
                }
                return .object(mapping.className, try mapping.fields(from: row, enumeration: enumeration))
            }

        case .sql(let provider):
            let quote = provider.quoteIdentifier
            let clause = try BASICSQLPredicateLowering.lower(
                columnPredicate,
                quote: quote,
                supported: provider.capabilities.operators
            )
            var sql = "SELECT \(mapping.columns.map { quote($0.columnName) }.joined(separator: ", "))"
            sql += " FROM \(quote(mapping.tableName))"
            if !clause.sql.isEmpty { sql += " WHERE \(clause.sql)" }
            if let limit { sql += " LIMIT \(limit)" }

            let rows = try await provider.query(sql, clause.parameters).toArray()
            return try rows.map { row in
                .object(mapping.className, try mapping.fields(from: row, enumeration: enumeration))
            }
        }
    }

    /// Deletes matching objects, returning how many went.
    @discardableResult
    func delete(_ mapping: BASICTableMapping, matching predicate: BASICQueryPredicate) async throws -> Int {
        let columnPredicate = try translate(predicate, for: mapping)
        switch backend {
        case .document(let provider):
            return try await provider.delete(collection: mapping.tableName, filter: columnPredicate)
        case .sql(let provider):
            let quote = provider.quoteIdentifier
            let clause = try BASICSQLPredicateLowering.lower(
                columnPredicate,
                quote: quote,
                supported: provider.capabilities.operators
            )
            var sql = "DELETE FROM \(quote(mapping.tableName))"
            if !clause.sql.isEmpty { sql += " WHERE \(clause.sql)" }
            return try await provider.execute(sql, clause.parameters)
        }
    }

    /// Rewrites a predicate's field names to column names, refusing one that
    /// names a field the class does not persist.
    private func translate(
        _ predicate: BASICQueryPredicate,
        for mapping: BASICTableMapping
    ) throws -> BASICQueryPredicate {
        try predicate.renamingFields { name in
            if let column = mapping.column(forField: name) { return column.columnName }
            if mapping.schema.column(named: name) != nil { return name }
            throw BASICDataError.noSuchColumn(name, table: mapping.className)
        }
    }

    // MARK: - Transactions

    func begin() async throws {
        guard case .sql(let provider) = backend, supportsTransactions else {
            throw BASICDataError.unsupported(
                "\(type(of: backend.provider).providerName) does not have transactions"
            )
        }
        try await provider.begin()
    }

    func commit() async throws {
        guard case .sql(let provider) = backend, supportsTransactions else {
            throw BASICDataError.unsupported("This store has no transaction to commit")
        }
        try await provider.commit()
    }

    func rollback() async throws {
        guard case .sql(let provider) = backend, supportsTransactions else {
            throw BASICDataError.unsupported("This store has no transaction to roll back")
        }
        try await provider.rollback()
    }
}
