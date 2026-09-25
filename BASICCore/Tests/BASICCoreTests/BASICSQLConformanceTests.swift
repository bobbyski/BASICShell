import Foundation
import Testing
@testable import BASICCore

/// The conformance suite every relational provider runs.
///
/// DATABASE_AND_ORM.md §4: the in-memory provider is "a real conformance ...
/// and it stays forever as the conformance suite any new provider runs to
/// claim it conforms." This is that, made literal — every test below runs
/// against both providers, so SQLite is held to the reference's behavior
/// rather than quietly redefining it.
@Suite("BASICSQLConformance")
struct BASICSQLConformanceTests {

    enum Provider: String, CaseIterable, CustomStringConvertible {
        case memory
        case sqlite

        var description: String { rawValue }

        func make() -> any BASICSQLProvider {
            switch self {
            case .memory: return BASICMemorySQLProvider()
            case .sqlite: return BASICSQLiteProvider()
            }
        }

        var url: String {
            switch self {
            case .memory: return "memory://conformance"
            case .sqlite: return ":memory:"
            }
        }
    }

    private func open(_ kind: Provider) async throws -> any BASICSQLProvider {
        let provider = kind.make()
        try await provider.open(kind.url)
        try await provider.apply([
            .createTable(BASICTableSchema(
                name: "Customer",
                columns: [
                    BASICColumnSchema(name: "Id", type: .integer, isNullable: false, isPrimaryKey: true, isGenerated: true),
                    BASICColumnSchema(name: "Name", type: .text(maximumLength: nil)),
                    BASICColumnSchema(name: "Balance", type: .integer),
                    BASICColumnSchema(name: "Vip", type: .boolean),
                ],
                indexes: [BASICIndexSchema(name: "ix_customer_name", columns: ["Name"])]
            ))
        ])
        return provider
    }

    @Test("Opens, pings and closes", arguments: Provider.allCases)
    func lifecycle(_ kind: Provider) async throws {
        let provider = kind.make()
        #expect(!provider.isOpen)
        try await provider.open(kind.url)
        #expect(provider.isOpen)
        #expect(try await provider.ping())
        await provider.close()
        #expect(!provider.isOpen)
    }

    @Test("Structured DDL creates a table the provider can describe", arguments: Provider.allCases)
    func schemaRoundTrip(_ kind: Provider) async throws {
        let provider = try await open(kind)

        let tables = try await provider.tables()
        #expect(tables.count == 1)
        let customer = try #require(tables.first)
        #expect(customer.name == "Customer")
        #expect(customer.column(named: "name") != nil, "lookup is case-insensitive")
        #expect(customer.primaryKeyColumns.map(\.name) == ["Id"])
        #expect(customer.indexes.contains { $0.name == "ix_customer_name" })

        try await provider.apply([
            .addColumn(table: "Customer", column: BASICColumnSchema(name: "City", type: .text(maximumLength: 40)))
        ])
        #expect(try await provider.tables()[0].column(named: "City") != nil)

        // Neither provider alters a column in place, and both say so rather
        // than rebuilding the table behind the program's back.
        #expect(!provider.capabilities.supportsAlterColumn)
        await #expect(throws: BASICDataError.self) {
            try await provider.apply([
                .alterColumn(table: "Customer", column: BASICColumnSchema(name: "Name", type: .integer))
            ])
        }
    }

    @Test("Insert reports a generated key", arguments: Provider.allCases)
    func generatedKeys(_ kind: Provider) async throws {
        let provider = try await open(kind)

        let returned = try await provider.query(
            "insert into Customer (Name, Balance) values (?, ?) returning Id",
            [.text("Ada"), .integer(250)]
        )
        #expect(try await returned.next())
        #expect(try returned.value(named: "Id") == .integer(1))
        await returned.close()
        #expect(provider.capabilities.reportsGeneratedKeys)
    }

    @Test("Select filters, orders and limits", arguments: Provider.allCases)
    func selection(_ kind: Provider) async throws {
        let provider = try await open(kind)

        for (name, balance) in [("Ada", 250), ("Grace", 50), ("Katherine", 900)] {
            #expect(try await provider.execute(
                "insert into Customer (Name, Balance) values (?, ?)",
                [.text(name), .integer(Int64(balance))]
            ) == 1)
        }

        let rich = try await provider
            .query("select Name, Balance from Customer where Balance > ? order by Balance desc", [.integer(60)])
            .toArray()
        #expect(rich.map { $0["Name"] } == [.text("Katherine"), .text("Ada")])

        let limited = try await provider
            .query("select Name from Customer order by Name limit 2", [])
            .toArray()
        #expect(limited.map { $0["Name"] } == [.text("Ada"), .text("Grace")])

        let missing = try await provider
            .query("select Name from Customer where Balance is null", [])
            .toArray()
        #expect(missing.isEmpty)
    }

    @Test("Update and delete report what they touched", arguments: Provider.allCases)
    func mutation(_ kind: Provider) async throws {
        let provider = try await open(kind)

        for name in ["Ada", "Grace"] {
            _ = try await provider.execute("insert into Customer (Name, Balance) values (?, ?)", [.text(name), .integer(10)])
        }
        #expect(try await provider.execute("update Customer set Balance = ? where Name = ?", [.integer(99), .text("Ada")]) == 1)
        #expect(try await provider.execute("update Customer set Balance = ? where Name = ?", [.integer(99), .text("Nobody")]) == 0)
        #expect(try await provider.execute("delete from Customer where Balance < ?", [.integer(50)]) == 1)
        #expect(try await provider.query("select Id from Customer", []).toArray().count == 1)
    }

    @Test("A prepared statement runs many times", arguments: Provider.allCases)
    func preparedReuse(_ kind: Provider) async throws {
        let provider = try await open(kind)

        let insert = try await provider.prepare("insert into Customer (Name, Balance) values (?, ?)")
        for (index, name) in ["Ada", "Grace", "Katherine"].enumerated() {
            #expect(try await insert.execute([.text(name), .integer(Int64(index))]) == 1)
        }
        await insert.close()
        #expect(try await provider.query("select Id from Customer", []).toArray().count == 3)
    }

    @Test("A bound value is data, never statement text", arguments: Provider.allCases)
    func injectionIsBound(_ kind: Provider) async throws {
        let provider = try await open(kind)

        let hostile = "Ada'; drop table Customer--"
        _ = try await provider.execute("insert into Customer (Name, Balance) values (?, ?)", [.text(hostile), .integer(1)])
        let rows = try await provider.query("select Name from Customer", []).toArray()
        #expect(rows.first?["Name"] == .text(hostile), "stored verbatim, not executed")
        #expect(try await provider.tables().count == 1, "the table is still there")
        #expect(provider.quoteIdentifier("od\"d") == "\"od\"\"d\"")
    }

    @Test("A boolean writes as the dialect's integer and reads back permissively", arguments: Provider.allCases)
    func booleanStorage(_ kind: Provider) async throws {
        let provider = try await open(kind)

        _ = try await provider.execute("insert into Customer (Name, Vip) values (?, ?)", [.text("Ada"), .boolean(true)])
        _ = try await provider.execute("insert into Customer (Name, Vip) values (?, ?)", [.text("Grace"), .boolean(false)])

        let rows = try await provider.query("select Name, Vip from Customer order by Name", []).toArray()
        // DB24: written as an integer, so it reads back as one on every dialect.
        #expect(rows[0]["Vip"] == .integer(1))
        #expect(rows[1]["Vip"] == .integer(0))
        #expect(rows[0]["Vip"]?.booleanValue == true)
        #expect(rows[1]["Vip"]?.booleanValue == false)
        #expect(provider.capabilities.booleanSpelling == "INTEGER")
    }

    @Test("Rollback restores, commit keeps", arguments: Provider.allCases)
    func transactions(_ kind: Provider) async throws {
        let provider = try await open(kind)
        #expect(provider.capabilities.supportsTransactions)

        _ = try await provider.execute("insert into Customer (Name) values (?)", [.text("Ada")])

        try await provider.begin()
        _ = try await provider.execute("insert into Customer (Name) values (?)", [.text("Grace")])
        try await provider.rollback()
        #expect(try await provider.query("select Id from Customer", []).toArray().count == 1)

        try await provider.begin()
        _ = try await provider.execute("insert into Customer (Name) values (?)", [.text("Katherine")])
        try await provider.commit()
        #expect(try await provider.query("select Id from Customer", []).toArray().count == 2)
        await provider.close()
    }

    @Test("Null round-trips, and IS NULL finds it", arguments: Provider.allCases)
    func nullHandling(_ kind: Provider) async throws {
        let provider = try await open(kind)

        _ = try await provider.execute("insert into Customer (Name, Balance) values (?, ?)", [.text("Ada"), .null])
        _ = try await provider.execute("insert into Customer (Name, Balance) values (?, ?)", [.text("Grace"), .integer(5)])

        let unset = try await provider.query("select Name from Customer where Balance is null", []).toArray()
        #expect(unset.map { $0["Name"] } == [.text("Ada")])

        let set = try await provider.query("select Name from Customer where Balance is not null", []).toArray()
        #expect(set.map { $0["Name"] } == [.text("Grace")])

        let read = try await provider.query("select Balance from Customer where Name = ?", [.text("Ada")]).toArray()
        #expect(read.first?["Balance"] == .null)
    }

    @Test("An operator the provider cannot honor is declared, not discovered", arguments: Provider.allCases)
    func declaredOperators(_ kind: Provider) async throws {
        let provider = kind.make()
        let supported = provider.capabilities.operators
        // Both honor the portable core; SQLite declines MATCHES because its
        // REGEXP hook is unregistered by default (§7.1).
        for op in [BASICPredicateOperator.equal, .notEqual, .lessThan, .greaterThan, .in, .between, .like] {
            #expect(supported.contains(op), "\(kind) should honor \(op.rawValue)")
        }
        if kind == .sqlite {
            #expect(!supported.contains(.matches))
        }
    }
}

/// SQLite-only behavior: the dialect decisions, and a real file on disk.
@Suite("BASICSQLite")
struct BASICSQLiteTests {

    @Test("Connection strings resolve to a path")
    func connectionStrings() {
        #expect(BASICSQLiteProvider.path(from: "sqlite://app.db") == "app.db")
        #expect(BASICSQLiteProvider.path(from: "sqlite:/tmp/app.db") == "/tmp/app.db")
        #expect(BASICSQLiteProvider.path(from: ":memory:") == ":memory:")
        #expect(BASICSQLiteProvider.handles("sqlite://app.db"))
        #expect(BASICSQLiteProvider.handles("/data/store.sqlite3"))
        #expect(!BASICSQLiteProvider.handles("mongodb://localhost/app"))
    }

    @Test("The dialect spells the logical types SQLite's way")
    func typeSpelling() {
        #expect(BASICSQLiteProvider.typeSpelling(.integer) == "INTEGER")
        #expect(BASICSQLiteProvider.typeSpelling(.double) == "REAL")
        #expect(BASICSQLiteProvider.typeSpelling(.blob) == "BLOB")
        // DB24: a boolean is an integer, which is also SQLite's only option.
        #expect(BASICSQLiteProvider.typeSpelling(.boolean) == "INTEGER")
        // Decimal is TEXT on purpose: SQLite's NUMERIC affinity turns a
        // fraction into REAL, which is the binary rounding that made DOUBLE
        // unacceptable for money to begin with.
        #expect(BASICSQLiteProvider.typeSpelling(.decimal(precision: 28, scale: 4)) == "TEXT")
        // SQLite has no date types; ISO-8601 text is its own convention and
        // sorts chronologically, so predicates keep working.
        #expect(BASICSQLiteProvider.typeSpelling(.date) == "TEXT")
        #expect(BASICSQLiteProvider.typeSpelling(.timestamp) == "TEXT")
    }

    @Test("A structured change becomes SQLite SQL, with identifiers quoted")
    func ddlLowering() throws {
        let quote = BASICSQLIdentifier.quotedDouble
        let create = try BASICSQLiteProvider.statements(
            for: .createTable(BASICTableSchema(
                name: "Customer",
                columns: [
                    BASICColumnSchema(name: "Id", type: .integer, isNullable: false, isPrimaryKey: true, isGenerated: true),
                    BASICColumnSchema(name: "Status", type: .text(maximumLength: nil), enumeratedNames: ["PENDING", "SHIPPED"]),
                ]
            )),
            quote: quote
        )
        #expect(create.count == 1)
        #expect(create[0].contains("\"Id\" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL"))
        // §7.3: a payload-free ENUM stores its case name, with a CHECK.
        #expect(create[0].contains("CHECK (\"Status\" IN ('PENDING', 'SHIPPED'))"))

        let index = try BASICSQLiteProvider.statements(
            for: .createIndex(table: "Customer", index: BASICIndexSchema(name: "ix", columns: ["Name"], isUnique: true)),
            quote: quote
        )
        #expect(index[0] == "CREATE UNIQUE INDEX IF NOT EXISTS \"ix\" ON \"Customer\" (\"Name\")")
    }

    @Test("An identifier that would break quoting is refused, naming the field")
    func identifierGuard() throws {
        // DB15: DATABASE NAME "..." puts a program string into an identifier
        // position, so it is validated before it is ever interpolated.
        #expect(throws: BASICDataError.self) {
            try BASICSQLIdentifier.validated("", describing: "column")
        }
        #expect(throws: BASICDataError.self) {
            try BASICSQLIdentifier.validated("Bad\nName", describing: "column")
        }
        #expect(throws: BASICDataError.self) {
            try BASICSQLiteProvider.statements(
                for: .createTable(BASICTableSchema(name: "T", columns: [
                    BASICColumnSchema(name: "x\u{0}y", type: .integer)
                ])),
                quote: BASICSQLIdentifier.quotedDouble
            )
        }
        // A quote in a name is not refused -- it is quoted, which is the
        // other half of the defense.
        #expect(try BASICSQLIdentifier.validated("od\"d") == "od\"d")
        #expect(BASICSQLIdentifier.quotedDouble("od\"d") == "\"od\"\"d\"")
        // Unicode names are welcome (DB20): a schema in another language is a
        // real schema.
        #expect(try BASICSQLIdentifier.validated("Kundennummer") == "Kundennummer")
        #expect(try BASICSQLIdentifier.validated("顧客") == "顧客")
    }

    @Test("A database survives being closed and reopened from a file")
    func fileRoundTrip() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("basic-sqlite-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let writer = BASICSQLiteProvider()
        try await writer.open("sqlite://\(path)")
        try await writer.apply([
            .createTable(BASICTableSchema(name: "Note", columns: [
                BASICColumnSchema(name: "Id", type: .integer, isNullable: false, isPrimaryKey: true, isGenerated: true),
                BASICColumnSchema(name: "Body", type: .text(maximumLength: nil)),
                BASICColumnSchema(name: "Written", type: .timestamp),
            ]))
        ])
        let stamp = BASICDataTimestamp(
            date: BASICDataDate(year: 2026, month: 9, day: 24),
            time: BASICDataTime(hour: 14, minute: 30, second: 5)
        )
        _ = try await writer.execute(
            "insert into Note (Body, Written) values (?, ?)",
            [.text("hello — with a unicode dash"), .timestamp(stamp)]
        )
        await writer.close()

        let reader = BASICSQLiteProvider()
        try await reader.open(path)
        let rows = try await reader.query("select Body, Written from Note", []).toArray()
        #expect(rows.count == 1)
        #expect(rows[0]["Body"] == .text("hello — with a unicode dash"), "UTF-8 survives the round trip (DB20)")
        // A timestamp came back as the ISO-8601 text SQLite stores. Normalizing
        // to the declared column type is the mapper's job (D4), not the
        // provider's -- a provider returns what its store holds.
        #expect(rows[0]["Written"] == .text("2026-09-24T14:30:05"))
        #expect(BASICDataTimestamp(iso8601: "2026-09-24T14:30:05") == stamp)
        await reader.close()
    }
}
