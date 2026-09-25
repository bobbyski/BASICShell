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

    /// Creates a store over a provider.
    init(backend: Backend, enumeration: @escaping (String) -> BASICEnumDefinition? = { _ in nil }) {
        self.backend = backend
        self.enumeration = enumeration
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
