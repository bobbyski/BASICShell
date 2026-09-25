import Foundation
import Testing
@testable import BASICCore

@Suite("BASICData")
struct BASICDataTests {

    // MARK: - Values

    @Test("Dates, times and timestamps round-trip through ISO-8601")
    func temporalValuesRoundTrip() throws {
        let date = BASICDataDate(year: 2026, month: 9, day: 24)
        #expect(date.description == "2026-09-24")
        #expect(BASICDataDate(iso8601: "2026-09-24") == date)

        let time = BASICDataTime(hour: 14, minute: 30, second: 5)
        #expect(time.description == "14:30:05")
        #expect(BASICDataTime(iso8601: "14:30:05") == time)

        let fractional = BASICDataTime(hour: 1, minute: 2, second: 3, nanosecond: 500_000_000)
        #expect(fractional.description == "01:02:03.5")
        #expect(BASICDataTime(iso8601: "01:02:03.5") == fractional)

        let stamp = BASICDataTimestamp(date: date, time: time, utcOffsetMinutes: 0)
        #expect(stamp.description == "2026-09-24T14:30:05Z")
        #expect(BASICDataTimestamp(iso8601: "2026-09-24T14:30:05Z") == stamp)

        let offset = BASICDataTimestamp(date: date, time: time, utcOffsetMinutes: -240)
        #expect(offset.description == "2026-09-24T14:30:05-04:00")
        #expect(BASICDataTimestamp(iso8601: "2026-09-24T14:30:05-04:00") == offset)

        // A space separator is what most SQL drivers hand back.
        #expect(BASICDataTimestamp(iso8601: "2026-09-24 14:30:05") ==
                BASICDataTimestamp(date: date, time: time))
        #expect(BASICDataDate(iso8601: "not a date") == nil)
    }

    @Test("A boolean reads back from every spelling a real column holds")
    func booleanReadsPermissively() {
        #expect(BASICDataValue.boolean(true).booleanValue == true)
        #expect(BASICDataValue.integer(1).booleanValue == true)
        #expect(BASICDataValue.integer(0).booleanValue == false)
        // What a classic VB or GW-BASIC application wrote for true.
        #expect(BASICDataValue.integer(-1).booleanValue == true)
        #expect(BASICDataValue.text("Y").booleanValue == true)
        #expect(BASICDataValue.text("n").booleanValue == false)
        #expect(BASICDataValue.text("t").booleanValue == true)
        #expect(BASICDataValue.text("FALSE").booleanValue == false)
        // Anything else is not silently truthy.
        #expect(BASICDataValue.text("maybe").booleanValue == nil)
        #expect(BASICDataValue.integer(7).booleanValue == nil)
        #expect(BASICDataValue.null.booleanValue == nil)
    }

    // MARK: - Predicates

    @Test("Predicate evaluation follows SQL for null and NSPredicate for nil comparison")
    func predicateNullSemantics() {
        let row: [String: BASICDataValue] = ["a": .integer(5), "b": .null]
        func check(_ predicate: BASICQueryPredicate) -> Bool {
            BASICPredicateEvaluator.matches(predicate) { row[$0] }
        }

        #expect(check(.compare("a", .equal, .integer(5))))
        #expect(!check(.compare("a", .equal, .integer(6))))
        // A null in the data fails every ordinary comparison.
        #expect(!check(.compare("b", .equal, .integer(5))))
        #expect(!check(.compare("b", .notEqual, .integer(5))))
        #expect(!check(.compare("b", .lessThan, .integer(5))))
        // Comparing against the literal null is a nullity test.
        #expect(check(.compare("b", .equal, .null)))
        #expect(!check(.compare("a", .equal, .null)))
        #expect(check(.compare("a", .notEqual, .null)))
        // A field nobody has is null.
        #expect(check(.compare("missing", .equal, .null)))
    }

    @Test("Predicate operators cover the NSPredicate vocabulary")
    func predicateOperators() {
        let row: [String: BASICDataValue] = ["name": .text("Ada Lovelace"), "n": .integer(42)]
        func check(_ predicate: BASICQueryPredicate) -> Bool {
            BASICPredicateEvaluator.matches(predicate) { row[$0] }
        }

        #expect(check(.compare("name", .beginsWith, .text("Ada"))))
        #expect(check(.compare("name", .endsWith, .text("lace"))))
        #expect(check(.compare("name", .contains, .text("Love"))))
        #expect(check(.compare("name", .like, .text("Ada%"))))
        #expect(check(.compare("name", .like, .text("A_a %"))))
        #expect(!check(.compare("name", .like, .text("Grace%"))))
        #expect(check(.compare("name", .matches, .text("^Ada .*e$"))))
        #expect(check(.compare(field: "n", op: .in, operand: .list([.integer(1), .integer(42)]))))
        #expect(!check(.compare(field: "n", op: .in, operand: .list([.integer(1)]))))
        #expect(check(.compare(field: "n", op: .between, operand: .range(.integer(40), .integer(50)))))
        #expect(!check(.compare(field: "n", op: .between, operand: .range(.integer(50), .integer(60)))))

        // Numbers compare across representations, so 42 == 42.0 == Decimal(42).
        #expect(check(.compare("n", .equal, .double(42))))
        #expect(check(.compare("n", .equal, .decimal(Decimal(42)))))
    }

    @Test("Predicates combine, report their fields, and rename")
    func predicateComposition() throws {
        let predicate = BASICQueryPredicate
            .compare("Balance", .greaterThan, .integer(100))
            .and(.compare("City", .equal, .text("Philadelphia")))
            .and(.compare("Balance", .lessThan, .integer(900)))

        #expect(predicate.referencedFields == ["Balance", "City"])
        #expect(predicate.usedOperators == [.greaterThan, .equal, .lessThan])
        // and() flattens rather than nesting.
        guard case .and(let children) = predicate else {
            Issue.record("expected a flattened and")
            return
        }
        #expect(children.count == 3)

        let renamed = try predicate.renamingFields { $0.lowercased() }
        #expect(renamed.referencedFields == ["balance", "city"])
        #expect(BASICQueryPredicate.all.and(.compare("a", .equal, .integer(1))) ==
                .compare("a", .equal, .integer(1)))
    }

    // MARK: - The document reference provider

    @Test("The document provider inserts, finds, upserts and deletes")
    func documentProviderRoundTrip() async throws {
        let provider = BASICMemoryDocumentProvider()
        try await provider.open("memory://test")

        var ada = BASICDocument()
        ada.setScalar("Name", .text("Ada"))
        ada.setScalar("Balance", .integer(250))
        let adaKey = try await provider.insert(collection: "Customer", document: ada)
        #expect(adaKey == .integer(1))

        var grace = BASICDocument()
        grace.setScalar("Name", .text("Grace"))
        grace.setScalar("Balance", .integer(50))
        _ = try await provider.insert(collection: "Customer", document: grace)

        let rich = try await provider.find(
            collection: "Customer",
            filter: .compare("Balance", .greaterThan, .integer(100)),
            limit: nil
        )
        #expect(rich.count == 1)
        #expect(rich.first?.scalar("Name") == .text("Ada"))
        // Insert stamped the identifier into the stored document.
        #expect(rich.first?.scalar(BASICMemoryDocumentProvider.identifierField) == .integer(1))

        var updated = ada
        updated.setScalar("Balance", .integer(10))
        try await provider.upsert(collection: "Customer", key: adaKey, document: updated)
        let afterUpsert = try await provider.find(collection: "Customer", filter: .all, limit: nil)
        #expect(afterUpsert.count == 2, "upsert replaces rather than appending")

        let removed = try await provider.delete(
            collection: "Customer",
            filter: .compare("Name", .equal, .text("Grace"))
        )
        #expect(removed == 1)
        #expect(try await provider.collections() == ["Customer"])

        try await provider.ensureIndex(collection: "Customer", fields: ["Name"], unique: true)
        try await provider.ensureIndex(collection: "Customer", fields: ["Name"], unique: true)
        #expect(provider.declaredIndexes(collection: "Customer").count == 1, "ensureIndex is idempotent")

        await provider.close()
        await #expect(throws: BASICDataError.notConnected) {
            _ = try await provider.find(collection: "Customer", filter: .all, limit: nil)
        }
    }

    // MARK: - The SQL reference provider

    private func openCustomerDatabase() async throws -> BASICMemorySQLProvider {
        let provider = BASICMemorySQLProvider()
        try await provider.open("memory://test")
        try await provider.apply([
            .createTable(BASICTableSchema(
                name: "Customer",
                columns: [
                    BASICColumnSchema(name: "Id", type: .integer, isNullable: false, isPrimaryKey: true, isGenerated: true),
                    BASICColumnSchema(name: "Name", type: .text(maximumLength: nil)),
                    BASICColumnSchema(name: "Balance", type: .decimal(precision: 28, scale: 4)),
                    BASICColumnSchema(name: "Vip", type: .boolean),
                ]
            ))
        ])
        return provider
    }

    @Test("The SQL provider applies structured DDL and reports it back")
    func sqlProviderSchema() async throws {
        let provider = try await openCustomerDatabase()
        let tables = try await provider.tables()
        #expect(tables.count == 1)
        #expect(tables[0].name == "Customer")
        #expect(tables[0].primaryKeyColumns.map(\.name) == ["Id"])
        #expect(tables[0].column(named: "balance")?.type == .decimal(precision: 28, scale: 4))

        try await provider.apply([
            .addColumn(table: "Customer", column: BASICColumnSchema(name: "City", type: .text(maximumLength: 40))),
            .createIndex(table: "Customer", index: BASICIndexSchema(name: "ix_name", columns: ["Name"], isUnique: true)),
        ])
        let widened = try await provider.tables()[0]
        #expect(widened.columns.count == 5)
        #expect(widened.indexes.map(\.name) == ["ix_name"])

        // Deliberately absent, matching SQLite, so the ORM cannot lean on it.
        await #expect(throws: BASICDataError.self) {
            try await provider.apply([
                .alterColumn(table: "Customer", column: BASICColumnSchema(name: "Name", type: .integer))
            ])
        }
        #expect(!provider.capabilities.supportsAlterColumn)
    }

    @Test("Insert reports the generated key, and select filters, orders and limits")
    func sqlProviderStatements() async throws {
        let provider = try await openCustomerDatabase()

        let keys = try await provider.query(
            "insert into Customer (Name, Balance, Vip) values (?, ?, ?) returning Id",
            [.text("Ada"), .decimal(Decimal(250)), .boolean(true)]
        )
        #expect(try await keys.next())
        #expect(try keys.value(named: "Id") == .integer(1))
        await keys.close()

        for (name, balance) in [("Grace", 50), ("Katherine", 900)] {
            let affected = try await provider.execute(
                "insert into Customer (Name, Balance, Vip) values (?, ?, ?)",
                [.text(name), .decimal(Decimal(balance)), .boolean(false)]
            )
            #expect(affected == 1)
        }

        let rows = try await provider
            .query("select Name, Balance from Customer where Balance > ? order by Balance desc", [.integer(60)])
            .toArray()
        #expect(rows.map { $0["Name"] } == [.text("Katherine"), .text("Ada")])

        let limited = try await provider
            .query("select Name from Customer order by Name limit 2", [])
            .toArray()
        #expect(limited.map { $0["Name"] } == [.text("Ada"), .text("Grace")])

        // A boolean was stored as the dialect's integer (DB24) and reads back as one.
        let vip = try await provider.query("select Vip from Customer where Name = ?", [.text("Ada")]).toArray()
        #expect(vip.first?["Vip"] == .integer(1))
        #expect(vip.first?["Vip"]?.booleanValue == true)

        let updated = try await provider.execute(
            "update Customer set Balance = ? where Name = ?",
            [.decimal(Decimal(999)), .text("Grace")]
        )
        #expect(updated == 1)

        let deleted = try await provider.execute("delete from Customer where Balance < ?", [.integer(100)])
        #expect(deleted == 0, "Grace was just raised to 999")

        let remaining = try await provider.query("select Id from Customer", []).toArray()
        #expect(remaining.count == 3)
    }

    @Test("A prepared statement runs many times with different arguments")
    func preparedStatementReuse() async throws {
        let provider = try await openCustomerDatabase()
        let insert = try await provider.prepare("insert into Customer (Name, Balance) values (?, ?)")
        for name in ["Ada", "Grace", "Katherine"] {
            #expect(try await insert.execute([.text(name), .integer(10)]) == 1)
        }
        await insert.close()
        let names = try await provider.query("select Name from Customer order by Name", []).toArray()
        #expect(names.count == 3)
    }

    @Test("Values are bound, never interpolated")
    func valuesAreBoundNotInterpolated() async throws {
        let provider = try await openCustomerDatabase()
        // The classic injection payload. Bound, it is just a name.
        let hostile = "Ada'; drop table Customer--"
        #expect(try await provider.execute(
            "insert into Customer (Name, Balance) values (?, ?)",
            [.text(hostile), .integer(1)]
        ) == 1)

        let rows = try await provider.query("select Name from Customer", []).toArray()
        #expect(rows.first?["Name"] == .text(hostile), "stored verbatim, not executed")
        #expect(try await provider.tables().count == 1, "the table is still there")

        // Quoting is the other half, for identifiers, which cannot be bound.
        #expect(provider.quoteIdentifier("Customer") == "\"Customer\"")
        #expect(provider.quoteIdentifier("od\"d") == "\"od\"\"d\"")
    }

    @Test("Rollback restores the rows and the schema")
    func transactionRollback() async throws {
        let provider = try await openCustomerDatabase()
        _ = try await provider.execute("insert into Customer (Name) values (?)", [.text("Ada")])

        try await provider.begin()
        _ = try await provider.execute("insert into Customer (Name) values (?)", [.text("Grace")])
        try await provider.apply([.addColumn(table: "Customer", column: BASICColumnSchema(name: "Nickname", type: .text(maximumLength: nil)))])
        #expect(try await provider.query("select Id from Customer", []).toArray().count == 2)
        try await provider.rollback()

        #expect(try await provider.query("select Id from Customer", []).toArray().count == 1)
        #expect(try await provider.tables()[0].columns.count == 4, "the added column went too")

        try await provider.begin()
        _ = try await provider.execute("insert into Customer (Name) values (?)", [.text("Katherine")])
        try await provider.commit()
        #expect(try await provider.query("select Id from Customer", []).toArray().count == 2)
    }

    @Test("A statement outside the grammar is refused by name, not half-understood")
    func unsupportedStatementsAreRefused() async throws {
        let provider = try await openCustomerDatabase()
        await #expect(throws: BASICDataError.self) {
            _ = try await provider.query("select Name from Customer join Orders on 1 = 1", [])
        }
        await #expect(throws: BASICDataError.self) {
            _ = try await provider.execute("truncate table Customer", [])
        }
        await #expect(throws: BASICDataError.self) {
            _ = try await provider.query("select Missing from Customer", [])
        }
        await #expect(throws: BASICDataError.self) {
            _ = try await provider.query("select Name from Nowhere", [])
        }
    }
}
