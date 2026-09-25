@testable import BASICCompilerKit
import BASICDialectTraditional
import BASICSyntax
import Foundation
import Testing

/// What the compiler tells the ORM about a program's classes (D3, D12).
///
/// The other end of this seam is `BASICCompiledDataTests` in BASICCoreTests,
/// which asserts that this exact text maps to what the interpreter maps the
/// same source to. Two packages, one literal: neither can move without the
/// other's test failing, which is the only way to pin a seam that no single
/// test can see both sides of.
struct DatabaseSchemaTests {

    static let source = """
    enum Status
        Pending
        Shipped
    end enum

    class Customer
        public Id as integer database key meta { version: 2 }
        public Name as string database name "customer_name"
        public State as Status database
        public Notes as string
        private Secret as string
    end class

    print "ok"
    """

    static let expected = """
    {"classes":[{"base":null,"fields":[\
    {"db":{"index":true,"key":true,"name":"Id","unique":true},"meta":{"version":{"n":2}},\
    "name":"Id","owner":"CUSTOMER","type":{"k":"integer"},"vis":"PUBLIC"},\
    {"db":{"name":"customer_name"},"name":"Name","owner":"CUSTOMER","type":{"k":"string"},"vis":"PUBLIC"},\
    {"db":{"name":"State"},"name":"State","owner":"CUSTOMER","type":{"k":"enum","n":"Status"},"vis":"PUBLIC"},\
    {"name":"Notes","owner":"CUSTOMER","type":{"k":"string"},"vis":"PUBLIC"},\
    {"name":"Secret","owner":"CUSTOMER","type":{"k":"string"},"vis":"PRIVATE"}],"name":"Customer"}],\
    "enums":[{"cases":[{"name":"Pending","value":0},{"name":"Shipped","value":1}],"name":"Status"}]}
    """

    private func schema(_ source: String) throws -> String? {
        try Compilation(dialect: TraditionalDialect()).bir(source: source, name: "schema").databaseSchema
    }

    @Test("The description carries what the mapper needs and nothing else")
    func descriptionIsWhatBASICCoreReads() throws {
        #expect(try schema(Self.source) == Self.expected)
    }

    @Test("Visibility and DATABASE options ride through, including implications")
    func annotationsSurvive() throws {
        let json = try #require(try schema("""
        class Item
            public Sku as string database key
            public Code as string database unique
            public Tag as string database index
            public Hidden as string
        end class
        print "ok"
        """))
        // KEY implies UNIQUE implies INDEX, applied once where the options are
        // built rather than at every reader.
        #expect(json.contains(#""db":{"index":true,"key":true,"name":"Sku","unique":true}"#))
        #expect(json.contains(#""db":{"index":true,"name":"Code","unique":true}"#))
        #expect(json.contains(#""db":{"index":true,"name":"Tag"}"#))
        #expect(json.contains(#""name":"Hidden","owner":"ITEM","type":{"k":"string"},"vis":"PUBLIC"}"#))
    }

    @Test("A program with no CLASS carries no schema at all")
    func nothingToDescribe() throws {
        #expect(try schema("PRINT 1") == nil)
        // A TYPE record is not a table: only a CLASS can be one.
        #expect(try schema("""
        type Point
            X as integer
            Y as integer
        end type
        print "ok"
        """) == nil)
    }

    @Test("An inherited field is described on the class that stores it")
    func inheritanceIsFlattened() throws {
        let json = try #require(try schema("""
        class Person
            public Id as integer database key
        end class

        class Customer
            inherits Person
            public Name as string database
        end class
        print "ok"
        """))
        // A subclass's table has the base's columns too, so its description
        // lists them — with `owner` saying where each was declared.
        #expect(json.contains(#""base":"Person""#))
        #expect(json.contains(#""name":"Id","owner":"PERSON""#))
        #expect(json.contains(#""name":"Name","owner":"CUSTOMER""#))
    }

    @Test("A type the ORM must refuse is described as what it is")
    func unmappableTypesAreNamed() throws {
        let json = try #require(try schema("""
        type Point
            X as integer
        end type

        class Shape
            public Id as integer database key
            public Origin as Point database
            public Anything as variant database
            public Lookup as dictionary database
        end class
        print "ok"
        """))
        // Described, not dropped: BASICCore refuses these by field name, and it
        // can only do that if it is told what they are.
        #expect(json.contains(#""type":{"k":"record","n":"Point"}"#))
        #expect(json.contains(#""type":{"k":"variant"}"#))
        #expect(json.contains(#""type":{"k":"dictionary"}"#))
    }
}

/// The compiler's half of the one registration point (D0.5).
///
/// `BASICSyntax`'s roster is where the database family is registered; this holds
/// the compiler's member table to it. A name on the roster and missing here
/// types as something else and fails with a message about indexes rather than
/// about the class — the same drift the roster exists to prevent, seen from the
/// other side.
struct DatabaseRosterTests {

    @Test("The member table covers every name on the roster")
    func theTableCoversTheRoster() {
        for pseudoClass in BASICDatabaseClasses.all {
            #expect(
                SemanticModel.isSystemClass(pseudoClass.normalizedName),
                "\(pseudoClass.displayName) is on the roster and not a system class"
            )
            #expect(
                SemanticModel.systemTypeName(pseudoClass.normalizedName) == pseudoClass.normalizedName,
                "\(pseudoClass.displayName) types as something else"
            )
            // A class whose table is empty would accept any method and answer
            // nothing, which is how a missing registration hides.
            #expect(
                SemanticModel.systemClasses[pseudoClass.normalizedName]?.isEmpty == false,
                "\(pseudoClass.displayName) has no members"
            )
        }
    }

    @Test("Every name on the roster compiles as a receiver")
    func everyNameCompiles() throws {
        // Through the front end, not past it: a name that types wrongly fails
        // here with a diagnostic rather than at run time with a driver error.
        let source = """
        LET DB = SqlDatabase(":memory:")
        LET DOCS = DocumentDatabase("memory:")
        LET STORE = DataStore(DB)
        LET ROWS = DB.Query("select 1 as a")
        PRINT ROWS.ColumnCount(); DOCS.Count("c"); STORE.SupportsTransactions()
        """
        #expect(throws: Never.self) {
            _ = try Compilation(dialect: TraditionalDialect()).bir(source: source, name: "roster")
        }
    }
}
