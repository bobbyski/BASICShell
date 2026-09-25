import Foundation
import Testing
import BASICSyntax
@testable import BASICCore

/// The `DATABASE` field modifier (DB2, DB4, DB9).
///
/// Persistence is opt in, spelled exactly parallel to `JSON`:
///
/// ```
/// DATABASE [ EXCLUDE | [NAME "column"] [KEY] [INDEX] [UNIQUE] ]
/// ```
@Suite("BASICDatabaseField")
struct BASICDatabaseFieldTests {

    private func fields(of source: String) throws -> [(name: String, database: BASICDatabaseFieldOptions?, json: BASICJSONFieldOptions?)] {
        let lines = ProgramLine.parse(source, fileName: "test.bas", isImported: false)
        return try ProgramParser.parse(lines).compactMap { parsed in
            switch parsed.statement {
            case .classField(let name, _, _, _, let json, let database, _, _),
                 .typeField(let name, _, _, _, let json, let database, _, _):
                return (name, database, json)
            default:
                return nil
            }
        }
    }

    @Test("A field with no marker is not persisted")
    func optInIsTheDefault() throws {
        let parsed = try fields(of: """
        class Customer
            public Name as string
            public Notes as string
        end class
        """)
        #expect(parsed.count == 2)
        #expect(parsed.allSatisfy { $0.database == nil },
                "adding a public field must not silently change a table (DB2)")
    }

    @Test("The three forms mirror JSON's exactly")
    func threeForms() throws {
        let parsed = try fields(of: """
        class Customer
            public Name as string database
            public Balance as double database name "balance_cents"
            public Secret as string database exclude
        end class
        """)
        #expect(parsed[0].database?.name == "Name", "bare DATABASE keeps the field name")
        #expect(parsed[1].database?.name == "balance_cents")
        #expect(parsed[2].database == nil, "EXCLUDE says out loud what absence already means")
    }

    @Test("KEY, INDEX and UNIQUE combine, and imply each other")
    func modifiers() throws {
        let parsed = try fields(of: """
        class Customer
            public Id as integer database key
            public Email as string database unique
            public City as string database index
            public Code as string database name "code" key
            public Plain as string database
        end class
        """)

        // KEY implies a unique index, so the three need not be written together.
        let key = try #require(parsed[0].database)
        #expect(key.isKey && key.isUnique && key.isIndexed)

        // UNIQUE implies INDEX.
        let unique = try #require(parsed[1].database)
        #expect(!unique.isKey && unique.isUnique && unique.isIndexed)

        let indexed = try #require(parsed[2].database)
        #expect(!indexed.isKey && !indexed.isUnique && indexed.isIndexed)

        let named = try #require(parsed[3].database)
        #expect(named.name == "code" && named.isKey)

        let plain = try #require(parsed[4].database)
        #expect(!plain.isKey && !plain.isIndexed && !plain.isUnique)
    }

    @Test("DATABASE and JSON are independent, and coexist on one field")
    func independentOfJSON() throws {
        let parsed = try fields(of: """
        class Customer
            public Name as string json name "name" database name "customer_name"
            public Badge as string json name "badge"
            public Internal as string database
        end class
        """)
        // Different names for the two destinations, which is the point of
        // keeping them independent (DB3).
        #expect(parsed[0].json?.name == "name")
        #expect(parsed[0].database?.name == "customer_name")
        // Serialized but not persisted.
        #expect(parsed[1].json?.name == "badge")
        #expect(parsed[1].database == nil)
        // Persisted but not serialized.
        #expect(parsed[2].json == nil)
        #expect(parsed[2].database?.name == "Internal")
    }

    @Test("A record takes the same markers as a class")
    func recordsToo() throws {
        let parsed = try fields(of: """
        type Address
            Street as string database
            Zip as string database name "postal_code" index
        end type
        """)
        #expect(parsed[0].database?.name == "Street")
        #expect(parsed[1].database?.name == "postal_code")
        #expect(parsed[1].database?.isIndexed == true)
    }

    @Test("The modifiers cost no reserved words")
    func modifiersAreContextual() throws {
        // Like JSON's, the modifiers are matched with matchIdentifier, which
        // reads an identifier by text only where one is expected. So a program
        // keeps its variables called index, unique, key and database -- the
        // TUI.md hazard about claiming words does not apply here.
        let lines = ProgramLine.parse("""
        let index = 3
        let unique = 4
        let key = 5
        let database = 6
        print index + unique + key + database
        """, fileName: "test.bas", isImported: false)
        let parsed = try ProgramParser.parse(lines)
        #expect(parsed.count == 5)
    }

    @Test("A class carries its markers through to its definition")
    func reachesTheClassDefinition() throws {
        // The mapper reads BASICClassDefinition, not the AST, so the markers
        // have to survive the walk that builds it.
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource("""
        class Customer
            public Id as integer database key
            public Name as string database name "customer_name"
            public Notes as string
        end class

        dim c as Customer
        c = new Customer()
        c.Name = "Ada"
        print c.Name
        """, fileName: "test.bas")
        try session.runProgram()
        #expect(host.output == ["Ada"])
    }
}
