import Foundation
import Testing
@testable import BASICCore

/// The ORM, over every provider.
///
/// "Can save in any compliant database provider" is the claim, so every test
/// here runs against all three — the reference SQL store, SQLite, and the
/// reference document store — with one set of assertions. A program written
/// against `BASICDataStore` does not know which it got.
@Suite("BASICDataStore")
struct BASICDataStoreTests {

    enum Backend: String, CaseIterable, CustomStringConvertible {
        case memorySQL
        case sqlite
        case memoryDocument

        var description: String { rawValue }

        func make() async throws -> BASICDataStore.Backend {
            switch self {
            case .memorySQL:
                let provider = BASICMemorySQLProvider()
                try await provider.open("memory://orm")
                return .sql(provider)
            case .sqlite:
                let provider = BASICSQLiteProvider()
                try await provider.open(":memory:")
                return .sql(provider)
            case .memoryDocument:
                let provider = BASICMemoryDocumentProvider()
                try await provider.open("memory://orm")
                return .document(provider)
            }
        }
    }

    private static let customerSource = """
    enum Status
        Pending
        Shipped
        Delivered
    end enum

    class Customer
        public Id as integer database key
        public Name as string database name "customer_name"
        public Balance as double database
        public Vip as boolean database
        public State as Status database
        public Scratch as string
    end class
    print "ok"
    """

    private func store(_ kind: Backend, source: String = customerSource) async throws -> (BASICDataStore, BASICTableMapping) {
        let session = BASICSession(host: TestHost())
        session.program.loadSource(source, fileName: "test.bas")
        try session.runProgram()
        let enums = session.declaredEnums
        let store = BASICDataStore(backend: try await kind.make()) { enums[$0.uppercased()] }
        let definition = try #require(session.declaredClasses["CUSTOMER"])
        let mapping = try store.register(definition)
        try await store.ensureSchema(mapping)
        return (store, mapping)
    }

    private func customer(
        _ name: String,
        balance: Double,
        vip: Bool = false,
        state: Int = 0,
        id: Double = 0
    ) -> BASICValue {
        .object("CUSTOMER", [
            "ID": .number(id),
            "NAME": .string(BASICString(name)),
            "BALANCE": .number(balance),
            "VIP": .boolean(vip),
            "STATE": .number(Double(state)),
            "SCRATCH": .string(BASICString("not persisted")),
        ])
    }

    private func name(of value: BASICValue) -> String? {
        guard case .object(_, let fields) = value, case .string(let text)? = fields["NAME"] else { return nil }
        return text.description
    }

    private func identifier(of value: BASICValue) -> Double? {
        guard case .object(_, let fields) = value, case .number(let number)? = fields["ID"] else { return nil }
        return number
    }

    @Test("Save fills in the generated key, and load brings it back", arguments: Backend.allCases)
    func saveAndLoad(_ kind: Backend) async throws {
        let (store, mapping) = try await store(kind)

        let saved = try await store.save(customer("Ada", balance: 250, vip: true, state: 1), as: mapping)
        let key = try #require(identifier(of: saved))
        #expect(key != 0, "the database filled the key in")

        let loaded = try #require(try await store.load(mapping, key: .integer(Int64(key))))
        guard case .object(_, let fields) = loaded else {
            Issue.record("expected an object")
            return
        }
        #expect(fields["NAME"] == .string(BASICString("Ada")))
        #expect(fields["BALANCE"] == .number(250))
        #expect(fields["VIP"] == .boolean(true), "written as an integer, read back as a boolean")
        #expect(fields["STATE"] == .number(1), "stored as the case name Shipped, read back as its number")
        // A field with no marker was never persisted, and comes back at its
        // default: what `Load` answers with is a whole instance of the class,
        // not the part of one that happened to be in the table. A program
        // reading `customer.Scratch` is reading a field of its own class, and
        // the compiled engine fills a typed slot whether it is told to or not
        // — so the two engines only agree if this one does too (D12).
        #expect(fields["SCRATCH"] == .string(BASICString("")))
    }

    @Test("Save twice updates rather than duplicating", arguments: Backend.allCases)
    func saveIsIdempotentOnKey(_ kind: Backend) async throws {
        let (store, mapping) = try await store(kind)

        var ada = try await store.save(customer("Ada", balance: 250), as: mapping)
        guard case .object(let typeName, var fields) = ada else { return }
        fields["BALANCE"] = .number(999)
        ada = .object(typeName, fields)
        _ = try await store.save(ada, as: mapping)

        let all = try await store.find(mapping, matching: .all)
        #expect(all.count == 1, "the second save was an update")
        guard case .object(_, let updated)? = all.first else { return }
        #expect(updated["BALANCE"] == .number(999))
    }

    @Test("Find takes a predicate over class field names", arguments: Backend.allCases)
    func findByPredicate(_ kind: Backend) async throws {
        let (store, mapping) = try await store(kind)
        for (person, balance) in [("Ada", 250.0), ("Grace", 50.0), ("Katherine", 900.0)] {
            _ = try await store.save(customer(person, balance: balance), as: mapping)
        }

        // "Name" is the class's field; the column is customer_name. A program
        // never has to know that (7.1).
        let ada = try await store.find(mapping, matching: .compare("Name", .equal, .text("Ada")))
        #expect(ada.count == 1)
        #expect(name(of: ada[0]) == "Ada")

        let rich = try await store.find(
            mapping,
            matching: .compare("Balance", .greaterThan, .double(100))
        )
        #expect(Set(rich.compactMap(name(of:))) == ["Ada", "Katherine"])

        let combined = try await store.find(
            mapping,
            matching: BASICQueryPredicate
                .compare("Balance", .greaterThan, .double(100))
                .and(.compare("Name", .beginsWith, .text("Kat")))
        )
        #expect(combined.compactMap(name(of:)) == ["Katherine"])

        let limited = try await store.find(mapping, matching: .all, limit: 2)
        #expect(limited.count == 2)

        // A field the class does not persist is refused, naming it.
        await #expect(throws: BASICDataError.self) {
            _ = try await store.find(mapping, matching: .compare("Scratch", .equal, .text("x")))
        }
    }

    @Test("A wildcard in the data is not a wildcard in the pattern", arguments: Backend.allCases)
    func likeEscaping(_ kind: Backend) async throws {
        let (store, mapping) = try await store(kind)
        _ = try await store.save(customer("50% off", balance: 1), as: mapping)
        _ = try await store.save(customer("50 percent", balance: 2), as: mapping)

        // BEGINSWITH "50%" must find the three characters 5, 0, % -- not
        // "50" followed by anything. Without escaping this is a quiet wrong
        // answer rather than an error.
        let found = try await store.find(mapping, matching: .compare("Name", .beginsWith, .text("50%")))
        #expect(found.compactMap(name(of:)) == ["50% off"])
    }

    @Test("An enum stores its case name and refuses one it does not have", arguments: Backend.allCases)
    func enumStorage(_ kind: Backend) async throws {
        let (store, mapping) = try await store(kind)
        _ = try await store.save(customer("Ada", balance: 1, state: 2), as: mapping)

        // The predicate is written in the database's terms for an enum, since
        // that is what the column holds.
        let delivered = try await store.find(mapping, matching: .compare("State", .equal, .text("Delivered")))
        #expect(delivered.count == 1)

        let column = try #require(mapping.column(forField: "State"))
        #expect(column.enumName == "Status")
        #expect(column.columnType == .text(maximumLength: nil))
    }

    @Test("Delete removes what the predicate names", arguments: Backend.allCases)
    func deleteByPredicate(_ kind: Backend) async throws {
        let (store, mapping) = try await store(kind)
        for (person, balance) in [("Ada", 250.0), ("Grace", 50.0)] {
            _ = try await store.save(customer(person, balance: balance), as: mapping)
        }
        #expect(try await store.delete(mapping, matching: .compare("Balance", .lessThan, .double(100))) == 1)
        #expect(try await store.find(mapping, matching: .all).compactMap(name(of:)) == ["Ada"])
    }

    @Test("EnsureSchema is idempotent and adds a new column", arguments: Backend.allCases)
    func schemaEvolution(_ kind: Backend) async throws {
        let (store, mapping) = try await store(kind)
        // Running it again changes nothing.
        #expect(try await store.ensureSchema(mapping).isEmpty)

        guard case .sql = store.backend else { return }
        // A class that gained a field adds a column, which is a safe change.
        let session = BASICSession(host: TestHost())
        session.program.loadSource("""
        class Customer
            public Id as integer database key
            public Name as string database name "customer_name"
            public Balance as double database
            public Vip as boolean database
            public State as string database
            public City as string database
        end class
        print "ok"
        """, fileName: "test.bas")
        try session.runProgram()
        let widened = try store.register(try #require(session.declaredClasses["CUSTOMER"]))
        let changes = try await store.ensureSchema(widened)
        #expect(changes.count == 1)
        if case .addColumn(_, let column) = changes[0] {
            #expect(column.name == "City")
        } else {
            Issue.record("expected an addColumn, got \(changes[0])")
        }
    }

    @Test("A change that could lose data is refused, naming it", arguments: Backend.allCases)
    func destructiveChangesRefused(_ kind: Backend) async throws {
        let (store, _) = try await store(kind)
        guard case .sql = store.backend else { return }

        // The class dropped a field, so the database has a column nothing maps
        // to. D7 refuses rather than guessing that it should go.
        let session = BASICSession(host: TestHost())
        session.program.loadSource("""
        class Customer
            public Id as integer database key
            public Name as string database name "customer_name"
        end class
        print "ok"
        """, fileName: "test.bas")
        try session.runProgram()
        let narrowed = try store.register(try #require(session.declaredClasses["CUSTOMER"]))
        await #expect(throws: BASICDataError.self) {
            _ = try await store.ensureSchema(narrowed)
        }
    }

    @Test("Describe prints the inferred schema as pasteable annotations", arguments: Backend.allCases)
    func describeShowsTheWayUp(_ kind: Backend) async throws {
        // Tier 0: a class with no markers at all.
        let (store, mapping) = try await store(kind, source: """
        class Customer
            public Id as integer
            public Name as string
        end class
        print "ok"
        """)
        #expect(mapping.tier == .everything)
        let text = store.describe(mapping)
        #expect(text.contains("tier: everything"))
        #expect(text.contains("public Id as integer database key"))
        #expect(text.contains("public Name as string database"))
    }

    @Test("Transactions are honored where the provider has them", arguments: Backend.allCases)
    func transactions(_ kind: Backend) async throws {
        let (store, mapping) = try await store(kind)

        guard store.supportsTransactions else {
            // The document store says no rather than pretending (DB14).
            await #expect(throws: BASICDataError.self) { try await store.begin() }
            return
        }

        _ = try await store.save(customer("Ada", balance: 1), as: mapping)
        try await store.begin()
        _ = try await store.save(customer("Grace", balance: 2), as: mapping)
        try await store.rollback()
        #expect(try await store.find(mapping, matching: .all).compactMap(name(of:)) == ["Ada"])
    }

    @Test("A value that looks like SQL is data", arguments: Backend.allCases)
    func injectionThroughTheORM(_ kind: Backend) async throws {
        let (store, mapping) = try await store(kind)
        let hostile = "Ada'; drop table Customer--"
        _ = try await store.save(customer(hostile, balance: 1), as: mapping)

        let found = try await store.find(mapping, matching: .compare("Name", .equal, .text(hostile)))
        #expect(found.count == 1, "stored and found verbatim, not executed")
        #expect(try await store.find(mapping, matching: .all).count == 1)
    }
}
