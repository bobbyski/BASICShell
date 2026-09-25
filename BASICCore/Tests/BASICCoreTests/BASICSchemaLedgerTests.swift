import Foundation
import Testing
@testable import BASICCore

/// Versioning and migration (D7).
///
/// The cases here are the ones a `.bas` program cannot easily show: the same
/// class at two different shapes, and the checksum that notices when one moved
/// without its version.
@Suite("BASICSchemaLedger")
struct BASICSchemaLedgerTests {

    enum Backend: String, CaseIterable, CustomStringConvertible {
        case memorySQL, sqlite, memoryDocument
        var description: String { rawValue }
    }

    private func store(_ kind: Backend) async throws -> BASICDataStore {
        let backend: BASICDataStore.Backend
        switch kind {
        case .memorySQL:
            let provider = BASICMemorySQLProvider()
            try await provider.open("memory:")
            backend = .sql(provider)
        case .sqlite:
            let provider = BASICSQLiteProvider()
            try await provider.open(":memory:")
            backend = .sql(provider)
        case .memoryDocument:
            let provider = BASICMemoryDocumentProvider()
            try await provider.open("memory:")
            backend = .document(provider)
        }
        return BASICDataStore(backend: backend)
    }

    /// A mapping for a one-key class, at a version, optionally with an extra column.
    private func mapping(version: Int, extraColumn: Bool = false, column: String = "Name") throws -> BASICTableMapping {
        var fields: [BASICClassField] = [
            BASICClassField(
                displayName: "Id", normalizedName: "ID", type: .scalar(.integer),
                arrayDimensions: [], visibility: .public, declaringClassName: "Customer",
                json: nil, database: BASICDatabaseFieldOptions(name: "Id", isKey: true),
                metadata: version == 0 ? [:] : ["version": .number(Double(version))], defaultValue: nil
            ),
        ]
        if extraColumn {
            fields.append(BASICClassField(
                displayName: column, normalizedName: column.uppercased(), type: .scalar(.string),
                arrayDimensions: [], visibility: .public, declaringClassName: "Customer",
                json: nil, database: BASICDatabaseFieldOptions(name: column),
                metadata: [:], defaultValue: nil
            ))
        }
        return try BASICObjectMapper.map(BASICClassDefinition(
            displayName: "Customer", normalizedName: "CUSTOMER", baseClassName: nil,
            fields: fields, implementedInterfaces: [], methods: [:]
        ))
    }

    // MARK: - The ledger

    @Test("A fresh database records the class's version and runs nothing", arguments: Backend.allCases)
    func firstEnsureRecords(_ kind: Backend) async throws {
        let store = try await store(kind)
        var ran: [String] = []
        store.setMigrationInvoker { ran.append($0) }
        try store.register(migration: BASICMigration(className: "Customer", fromVersion: 0, toVersion: 1, functionName: "Up"))

        try await store.ensureSchema(try mapping(version: 1))
        // DB5: an unversioned class recording 0 is a legitimate starting state,
        // and a versioned one starting where it is means the first program to
        // run does not migrate a database it just created.
        #expect(try await store.schemaVersion(of: "Customer") == 1)
        #expect(ran.isEmpty, "a new database is not behind")
    }

    @Test("A database behind the class runs the chain in order", arguments: Backend.allCases)
    func theChainRunsInOrder(_ kind: Backend) async throws {
        let store = try await store(kind)
        var ran: [String] = []
        store.setMigrationInvoker { ran.append($0) }
        try store.register(migration: BASICMigration(className: "Customer", fromVersion: 0, toVersion: 1, functionName: "To1"))
        try store.register(migration: BASICMigration(className: "Customer", fromVersion: 1, toVersion: 2, functionName: "To2"))
        try store.register(migration: BASICMigration(className: "Customer", fromVersion: 2, toVersion: 3, functionName: "To3"))

        try await store.ensureSchema(try mapping(version: 0))
        #expect(try await store.schemaVersion(of: "Customer") == 0)

        try await store.ensureSchema(try mapping(version: 3))
        #expect(ran == ["To1", "To2", "To3"], "in order, one version at a time")
        #expect(try await store.schemaVersion(of: "Customer") == 3)

        // And again is a no-op: the ledger says it is already there.
        ran = []
        try await store.ensureSchema(try mapping(version: 3))
        #expect(ran.isEmpty)
    }

    @Test("A missing step refuses before anything runs", arguments: Backend.allCases)
    func aMissingStepRefusesWhole(_ kind: Backend) async throws {
        let store = try await store(kind)
        var ran: [String] = []
        store.setMigrationInvoker { ran.append($0) }
        // 0 -> 1 is registered and 1 -> 2 is not.
        try store.register(migration: BASICMigration(className: "Customer", fromVersion: 0, toVersion: 1, functionName: "To1"))
        try await store.ensureSchema(try mapping(version: 0))

        await #expect(throws: BASICDataError.self) {
            try await store.ensureSchema(try self.mapping(version: 2))
        }
        // The whole chain is planned before any of it runs, so a gap leaves the
        // database where it was rather than half migrated.
        #expect(ran.isEmpty)
        #expect(try await store.schemaVersion(of: "Customer") == 0)
    }

    @Test("A database ahead of the program is refused: migration is forward only", arguments: Backend.allCases)
    func forwardOnly(_ kind: Backend) async throws {
        let store = try await store(kind)
        try await store.ensureSchema(try mapping(version: 5))
        await #expect(throws: BASICDataError.self) {
            try await store.ensureSchema(try self.mapping(version: 2))
        }
        #expect(try await store.schemaVersion(of: "Customer") == 5)
    }

    @Test("A shape that moves without its version is refused, by whichever gate can see it", arguments: Backend.allCases)
    func theChecksumEarnsItsPlace(_ kind: Backend) async throws {
        let store = try await store(kind)
        try await store.ensureSchema(try mapping(version: 1, extraColumn: true, column: "Name"))

        // Same version, a renamed column: the change DB2 leaves behind, because
        // opt-in means adding a field cannot do this by accident -- so when it
        // does happen it was deliberate, and it maps to a destructive DDL.
        //
        // Both gates refuse it, and it matters which one: a relational store was
        // compared against its live table and names the column, while a document
        // store has no shape to ask about and only has the checksum.
        await #expect(throws: BASICDataError.self) {
            try await store.ensureSchema(try self.mapping(version: 1, extraColumn: true, column: "Label"))
        }
    }

    @Test("Adding a column is safe, and the ledger keeps up with it", arguments: Backend.allCases)
    func addingAColumnIsNotAChecksumFailure(_ kind: Backend) async throws {
        let store = try await store(kind)
        try await store.ensureSchema(try mapping(version: 1))
        // The plan calls a new column safe and means it: `applySchema` compares
        // against the live table, applies it, and the checksum follows rather
        // than refusing what was just applied.
        try await store.ensureSchema(try mapping(version: 1, extraColumn: true))
        #expect(try await store.schemaVersion(of: "Customer") == 1)
        // And it settles: running it again is a no-op.
        try await store.ensureSchema(try mapping(version: 1, extraColumn: true))
    }

    @Test("A migration must go up exactly one version")
    func stepsAreOneAtATime() async throws {
        let store = try await store(.memorySQL)
        #expect(throws: BASICDataError.self) {
            try store.register(migration: BASICMigration(className: "C", fromVersion: 0, toVersion: 2, functionName: "Skip"))
        }
        #expect(throws: BASICDataError.self) {
            try store.register(migration: BASICMigration(className: "C", fromVersion: 3, toVersion: 1, functionName: "Down"))
        }
    }

    @Test("A store with no way to call a migration says so rather than skipping it")
    func noInvokerIsAnError() async throws {
        let store = try await store(.memorySQL)
        try store.register(migration: BASICMigration(className: "Customer", fromVersion: 0, toVersion: 1, functionName: "To1"))
        try await store.ensureSchema(try mapping(version: 0))
        // Recording version 1 without running the function would be the
        // deniable failure: the database would claim a migration it never had.
        await #expect(throws: BASICDataError.self) {
            try await store.ensureSchema(try self.mapping(version: 1))
        }
        #expect(try await store.schemaVersion(of: "Customer") == 0)
    }

    // MARK: - The checksum itself

    @Test("The stored shape covers storage and ignores BASIC names")
    func theShapeCoversWhatMatters() throws {
        let base = try mapping(version: 1, extraColumn: true, column: "Name")
        #expect(BASICSchemaLedger.shape(of: base) == "table Customer|Id:integer:key|Name:text(maximumLength: nil)")
        // A different column name is a different schema.
        #expect(BASICSchemaLedger.shape(of: base)
                != BASICSchemaLedger.shape(of: try mapping(version: 1, extraColumn: true, column: "Label")))
        // A version bump alone is not: the version is recorded beside it.
        #expect(BASICSchemaLedger.shape(of: base)
                == BASICSchemaLedger.shape(of: try mapping(version: 7, extraColumn: true, column: "Name")))
        // And it can be read back per column, which is what lets a refusal name
        // the column rather than just saying something moved.
        #expect(BASICSchemaLedger.columns(in: BASICSchemaLedger.shape(of: base)).keys.sorted() == ["Id", "Name"])
    }

    @Test("A document store names the field that went missing")
    func documentRefusalsNameTheField() async throws {
        let store = try await store(.memoryDocument)
        try await store.ensureSchema(try mapping(version: 1, extraColumn: true, column: "Name"))
        do {
            try await store.ensureSchema(try mapping(version: 1))
            Issue.record("a removed field was waved through")
        } catch let error as BASICDataError {
            #expect(error.description.contains("Customer.Name"))
        }
    }

    @Test("The digest is stable across processes, which a Hasher is not")
    func theDigestIsStable() {
        // Seeded hashing would make a stored digest meaningless: the same shape
        // would not match itself tomorrow, which for a value in a database is
        // not a checksum at all.
        #expect(BASICSchemaLedger.digest("Customer|Id:integer:key") == "9243260ecfecea97")
        #expect(BASICSchemaLedger.digest("") == "cbf29ce484222325")
    }
}
