import Foundation
import Testing
@testable import BASICCore

/// The ORM's mapper: a CLASS becomes a table, its instances become rows.
@Suite("BASICObjectMapper")
struct BASICObjectMapperTests {

    private func session(_ source: String) throws -> BASICSession {
        let session = BASICSession(host: TestHost())
        session.program.loadSource(source, fileName: "test.bas")
        try session.runProgram()
        return session
    }

    private func mapping(
        _ source: String,
        class className: String = "Customer"
    ) throws -> (BASICTableMapping, BASICSession) {
        let session = try self.session(source)
        let definition = try #require(session.declaredClasses[className.uppercased()])
        let mapping = try BASICObjectMapper.map(definition) { session.declaredEnums[$0.uppercased()] }
        return (mapping, session)
    }

    // MARK: - Tier resolution (§3.1)

    @Test("Tier 2: DATABASE markers win, and nothing else is persisted")
    func explicitTier() throws {
        let (mapping, _) = try mapping("""
        class Customer
            public Id as integer database key
            public Name as string database name "customer_name"
            public Email as string database unique
            public Notes as string
            public Draft as string json name "draft"
        end class
        print "ok"
        """)

        #expect(mapping.tier == .explicit)
        #expect(mapping.tableName == "Customer")
        #expect(mapping.columns.map(\.columnName) == ["Id", "customer_name", "Email"])
        #expect(mapping.keyColumn?.columnName == "Id")
        #expect(mapping.keyColumn?.isGenerated == true, "an integer key is the database's to fill in")
        // A JSON marker does not make a field persist (DB3).
        #expect(mapping.column(forField: "Draft") == nil)
        #expect(mapping.column(forField: "Notes") == nil)
        // DATABASE UNIQUE became an index.
        #expect(mapping.schema.indexes.map(\.columns) == [["Email"]])
        #expect(mapping.schema.indexes.first?.isUnique == true)
    }

    @Test("Tier 1: with no DATABASE markers, the Codable shape is used")
    func codableTier() throws {
        let (mapping, _) = try mapping("""
        class Customer
            public Id as integer json name "id"
            public Name as string json name "name"
            public Notes as string
        end class
        print "ok"
        """)

        #expect(mapping.tier == .codable)
        #expect(mapping.columns.map(\.columnName) == ["id", "name"])
        // DB4: a field named Id is the key by convention when none is marked.
        #expect(mapping.keyColumn?.fieldName == "Id")
    }

    @Test("Tier 0: with no markers at all, every public field persists")
    func everythingTier() throws {
        let (mapping, _) = try mapping("""
        class Customer
            public Id as integer
            public Name as string
            private Secret as string
        end class
        print "ok"
        """)

        #expect(mapping.tier == .everything)
        #expect(mapping.columns.map(\.columnName) == ["Id", "Name"])
        #expect(mapping.column(forField: "Secret") == nil, "private is not public")
        #expect(mapping.keyColumn?.fieldName == "Id")
    }

    @Test("A class with no version is version 0")
    func versionDefaultsToZero() throws {
        let (plain, _) = try mapping("""
        class Customer
            public Id as integer database key
        end class
        print "ok"
        """)
        #expect(plain.version == 0, "so the first migration anyone writes is 0 to 1")

        let (versioned, _) = try mapping("""
        class Customer
            public Id as integer database key meta { version: 3 }
        end class
        print "ok"
        """)
        #expect(versioned.version == 3)
    }

    // MARK: - Types

    @Test("Scalars map to column types, and a boolean is a boolean")
    func scalarTypes() throws {
        let (mapping, _) = try mapping("""
        class Customer
            public Id as integer database key
            public Rate as double database
            public Name as string database
            public Vip as boolean database
        end class
        print "ok"
        """)
        #expect(mapping.column(forField: "Id")?.columnType == .integer)
        #expect(mapping.column(forField: "Rate")?.columnType == .double)
        #expect(mapping.column(forField: "Name")?.columnType == .text(maximumLength: nil))
        // DB24: the provider narrows it to its own integer; the mapper says
        // "boolean" and lets it.
        #expect(mapping.column(forField: "Vip")?.columnType == .boolean)
    }

    @Test("A payload-free ENUM stores its case name, with a check")
    func enumStoresTheName() throws {
        let (mapping, session) = try mapping("""
        enum Status
            Pending
            Shipped
            Delivered
        end enum

        class Customer
            public Id as integer database key
            public State as Status database
        end class
        print "ok"
        """)

        let column = try #require(mapping.column(forField: "State"))
        // §7.3: the name, not the ordinal, because inserting a case renumbers
        // every later one and would silently reinterpret stored data.
        #expect(column.columnType == .text(maximumLength: nil))
        #expect(column.enumName == "Status")
        let schemaColumn = try #require(mapping.schema.column(named: "State"))
        #expect(schemaColumn.enumeratedNames == ["Pending", "Shipped", "Delivered"])

        // Round-trip: the value is a number in BASIC, a name in the database.
        let lookup: (String) -> BASICEnumDefinition? = { session.declaredEnums[$0.uppercased()] }
        let stored = try BASICTableMapping.dataValue(.number(1), for: column, enumeration: lookup)
        #expect(stored == .text("Shipped"))
        let restored = try BASICTableMapping.basicValue(.text("Shipped"), for: column, enumeration: lookup)
        #expect(restored == .number(1))
        // A name the enum does not have is an error, not a silent zero.
        #expect(throws: BASICDataError.self) {
            try BASICTableMapping.basicValue(.text("Lost"), for: column, enumeration: lookup)
        }
    }

    @Test("A type the mapper cannot name is refused, naming the field")
    func unsupportedTypesRefused() throws {
        func expectRefusal(_ field: String) throws {
            let session = try self.session("""
            class Other
                public X as integer
            end class

            class Customer
                public Id as integer database key
                \(field)
            end class
            print "ok"
            """)
            let definition = try #require(session.declaredClasses["CUSTOMER"])
            #expect(throws: BASICDataError.self) {
                try BASICObjectMapper.map(definition) { session.declaredEnums[$0.uppercased()] }
            }
        }

        try expectRefusal("public Anything as variant database")
        try expectRefusal("public Friend as Other database")
        try expectRefusal("public Lookup as dictionary database")
    }

    // MARK: - Rows

    @Test("An object becomes a row and comes back")
    func roundTripsThroughARow() throws {
        let (mapping, session) = try mapping("""
        class Customer
            public Id as integer database key
            public Name as string database name "customer_name"
            public Balance as double database
            public Vip as boolean database
        end class
        print "ok"
        """)
        let lookup: (String) -> BASICEnumDefinition? = { session.declaredEnums[$0.uppercased()] }

        let object = BASICValue.object("CUSTOMER", [
            "ID": .number(7),
            "NAME": .string(BASICString("Ada")),
            "BALANCE": .number(250.5),
            "VIP": .boolean(true),
        ])

        let row = try mapping.row(from: object, enumeration: lookup)
        #expect(row.map(\.column) == ["Id", "customer_name", "Balance", "Vip"])
        #expect(row.map(\.value) == [.integer(7), .text("Ada"), .double(250.5), .boolean(true)])

        // Omitting a generated key is what an insert does.
        let insert = try mapping.row(from: object, includingKey: false, enumeration: lookup)
        #expect(insert.map(\.column) == ["customer_name", "Balance", "Vip"])

        // Coming back, from what a real store returns: DB24 means the boolean
        // arrives as an integer, and §7.2 means that still reads as a boolean.
        let fields = try mapping.fields(from: [
            "Id": .integer(7),
            "customer_name": .text("Ada"),
            "Balance": .double(250.5),
            "Vip": .integer(1),
        ], enumeration: lookup)
        #expect(fields["ID"] == .number(7))
        #expect(fields["NAME"] == .string(BASICString("Ada")))
        #expect(fields["BALANCE"] == .number(250.5))
        #expect(fields["VIP"] == .boolean(true))

        // A legacy Y/N column reads too, which is the AS-400 case.
        let legacy = try mapping.fields(from: ["Vip": .text("Y")], enumeration: lookup)
        #expect(legacy["VIP"] == .boolean(true))
        // And -1, which is what a classic VB application wrote for true.
        let vb = try mapping.fields(from: ["Vip": .integer(-1)], enumeration: lookup)
        #expect(vb["VIP"] == .boolean(true))
    }

    @Test("A null column becomes EMPTY, and an unreadable one is an error")
    func nullAndMismatch() throws {
        let (mapping, _) = try mapping("""
        class Customer
            public Id as integer database key
            public Name as string database
            public Vip as boolean database
        end class
        print "ok"
        """)
        let fields = try mapping.fields(from: ["Id": .integer(1), "Name": .null])
        #expect(fields["NAME"] == .empty)

        let column = try #require(mapping.column(forField: "Vip"))
        #expect(throws: BASICDataError.self) {
            try BASICTableMapping.basicValue(.text("maybe"), for: column)
        }
    }

    @Test("A name that would break quoting is refused at mapping time")
    func identifierGuardAtMappingTime() throws {
        let session = try self.session("""
        class Customer
            public Id as integer database key
        end class
        print "ok"
        """)
        let definition = try #require(session.declaredClasses["CUSTOMER"])
        // DB15: DATABASE NAME and the table name both put a program string
        // into an identifier position, so they fail here -- naming the class
        // -- rather than at query time.
        #expect(throws: BASICDataError.self) {
            try BASICObjectMapper.map(definition, tableName: "bad\nname")
        }
        #expect(throws: BASICDataError.self) {
            try BASICObjectMapper.map(definition, tableName: "")
        }
        // A quote is fine: quoting handles it, which is the other half.
        #expect(try BASICObjectMapper.map(definition, tableName: "od\"d").tableName == "od\"d")
    }
}
