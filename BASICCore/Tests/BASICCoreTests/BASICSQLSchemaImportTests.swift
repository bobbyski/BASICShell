import Foundation
import Testing
@testable import BASICCore
import BASICSyntax

/// `IMPORT "schema.sql"` — a BASIC class per table (D6).
///
/// The schemas below are written the way a DBA writes them, not the way an
/// importer would like them: every dialect's spelling of the same handful of
/// ideas, constraints in both the column and the table position, and the
/// punctuation traps that make a naive parser confidently wrong.
@Suite("BASICSQLSchemaImport")
struct BASICSQLSchemaImportTests {

    private func table(_ sql: String, _ name: String = "T") throws -> BASICSQLSchemaImport.Table {
        let tables = try BASICSQLSchemaImport.tables(fromSQL: sql)
        return try #require(tables.first { $0.sqlName.uppercased() == name.uppercased() })
    }

    // MARK: - Types

    @Test("Every dialect's spelling of the same idea reads as one type")
    func typesAreMatchedByWhatTheySay() {
        func kind(_ declaration: String) -> BASICSQLSchemaImport.ColumnKind {
            BASICSQLSchemaImport.kind(ofType: declaration)
        }
        // Matched on what the type contains, not on an exact spelling: an
        // exact-match table falls through to text for the next dialect's name.
        for text in ["INT", "INTEGER", "BIGINT", "SMALLINT", "INT4", "MEDIUMINT UNSIGNED", "SERIAL"] {
            #expect(kind(text) == .integer, "\(text)")
        }
        for text in ["DOUBLE", "DOUBLE PRECISION", "REAL", "FLOAT(24)"] {
            #expect(kind(text) == .double, "\(text)")
        }
        for text in ["TEXT", "VARCHAR(120)", "NVARCHAR(40)", "CHAR(1)", "CLOB"] {
            #expect(kind(text) == .string, "\(text)")
        }
        // DB24: a boolean is stored as the narrowest integer, and TINYINT(1) is
        // what MySQL writes for one -- so it has to win over "contains INT".
        for text in ["BOOLEAN", "BOOL", "BIT", "TINYINT(1)"] {
            #expect(kind(text) == .boolean, "\(text)")
        }
        // DB19: exactness is the point of DECIMAL, so it is never quietly a
        // double. Carried as text, named, until D0.7 gives the language a type.
        #expect(kind("DECIMAL(12,2)") == .textFor("DECIMAL"))
        #expect(kind("NUMERIC(10, 2)") == .textFor("DECIMAL"))
        #expect(kind("MONEY") == .textFor("DECIMAL"))
        #expect(kind("TIMESTAMP WITH TIME ZONE") == .textFor("DATETIME"))
        #expect(kind("DATETIME") == .textFor("DATETIME"))
        #expect(kind("DATE") == .textFor("DATE"))
        #expect(kind("TIME") == .textFor("TIME"))
        #expect(kind("BLOB") == .textFor("BINARY"))
        #expect(kind("VARBINARY(64)") == .textFor("BINARY"))
    }

    // MARK: - Constraints

    @Test("A constraint counts from the column position or the table position")
    func constraintsFromEitherPosition() throws {
        let inColumn = try table("""
        CREATE TABLE T (
            a INTEGER PRIMARY KEY,
            b TEXT UNIQUE,
            c TEXT
        );
        """)
        #expect(inColumn.columns.map(\.isPrimaryKey) == [true, false, false])
        #expect(inColumn.columns.map(\.isUnique) == [false, true, false])
        // UNIQUE implies an index, as the DATABASE modifiers do.
        #expect(inColumn.columns.map(\.isIndexed) == [true, true, false])

        let inTable = try table("""
        CREATE TABLE T (
            a INTEGER NOT NULL,
            b TEXT,
            c TEXT,
            PRIMARY KEY (a),
            CONSTRAINT uq_b UNIQUE (b),
            FOREIGN KEY (c) REFERENCES Other (c),
            CHECK (a > 0)
        );
        """)
        #expect(inTable.columns.map(\.isPrimaryKey) == [true, false, false])
        #expect(inTable.columns.map(\.isUnique) == [false, true, false])
        #expect(inTable.columns.map(\.isNotNull) == [true, false, false])
        // A FOREIGN KEY and a CHECK declare no column, so they add none.
        #expect(inTable.columns.count == 3)
    }

    @Test("A default whose text reads as a keyword is not a constraint")
    func quotedTextIsNotAConstraint() throws {
        // The trap a naive `contains("PRIMARY")` falls into, and the reason a
        // column's tail is read with quotes removed.
        let read = try table("""
        CREATE TABLE T (
            a INTEGER,
            notes TEXT DEFAULT 'primary contact',
            label TEXT DEFAULT 'not null unique'
        );
        """)
        #expect(read.columns.allSatisfy { !$0.isPrimaryKey })
        #expect(read.columns.allSatisfy { !$0.isUnique })
        #expect(read.columns.allSatisfy { !$0.isNotNull })
        // And a word that merely *contains* one is not it either.
        let notNullable = try table("CREATE TABLE T (a INTEGER NOTNULLABLE);")
        #expect(notNullable.columns[0].isNotNull == false)
    }

    @Test("A separate CREATE INDEX lands on the column it indexes")
    func createIndexIsTheSameStatement() throws {
        let tables = try BASICSQLSchemaImport.tables(fromSQL: """
        CREATE TABLE T (a INTEGER, b TEXT, c TEXT);
        CREATE INDEX ix_a ON T (a);
        CREATE UNIQUE INDEX ix_b ON main.T (b);
        CREATE INDEX ix_elsewhere ON Other (c);
        """)
        let read = try #require(tables.first)
        #expect(read.columns.map(\.isIndexed) == [true, true, false])
        #expect(read.columns.map(\.isUnique) == [false, true, false])
    }

    // MARK: - Lexing

    @Test("Comments, other statements and quoted punctuation are handled")
    func theFileIsAFileNotAnIdealizedSchema() throws {
        let tables = try BASICSQLSchemaImport.tables(fromSQL: """
        -- a line comment; with a semicolon in it
        # a MySQL comment
        /* a block comment
           spanning lines; with punctuation */
        SET client_encoding = 'UTF8';
        CREATE TABLE `orders` (
            [order id] INTEGER PRIMARY KEY,
            "note"     TEXT DEFAULT 'a; b; c'
        );
        INSERT INTO orders (note) VALUES ('one; two');
        GRANT SELECT ON orders TO reporting;
        """)
        // A schema file carries far more than tables, and an importer that died
        // on the first SET would be useless -- so they are skipped, and only a
        // CREATE TABLE it cannot read is an error.
        #expect(tables.count == 1)
        let read = try #require(tables.first)
        #expect(read.sqlName == "orders")
        #expect(read.columns.map(\.sqlName) == ["order id", "note"])
        #expect(read.columns.map(\.fieldName) == ["OrderId", "Note"])
    }

    // MARK: - Names

    @Test("A column name is prettified; a table name never is")
    func namesFollowTwoDifferentRules() throws {
        // A column keeps its original in DATABASE NAME, so it is safe to make
        // it read like something a person would have typed.
        #expect(BASICSQLSchemaImport.identifier(from: "order_date") == "OrderDate")
        #expect(BASICSQLSchemaImport.identifier(from: "Full Name") == "FullName")
        #expect(BASICSQLSchemaImport.identifier(from: "order-date") == "OrderDate")
        #expect(BASICSQLSchemaImport.identifier(from: "2024_qty") == "T2024Qty")
        #expect(BASICSQLSchemaImport.identifier(from: "print") == "PrintField")
        #expect(BASICSQLSchemaImport.identifier(from: "!!") == "Column")

        // A table has no such escape hatch: a CLASS names its table by being
        // called the same thing, so the name is used exactly or refused.
        #expect(try BASICSQLSchemaImport.className(fromTable: "customers") == "customers")
        #expect(try BASICSQLSchemaImport.className(fromTable: "order_items") == "order_items")
        #expect(throws: BASICSQLSchemaImport.Failure.self) {
            try BASICSQLSchemaImport.className(fromTable: "order items")
        }
        // Refused for the same reason a keyword is: it would not parse.
        #expect(throws: BASICSQLSchemaImport.Failure.self) {
            try BASICSQLSchemaImport.className(fromTable: "print")
        }
    }

    @Test("Two tables that would become one class are named, not merged")
    func collisionsAreRefused() {
        #expect(throws: BASICSQLSchemaImport.Failure.self) {
            try BASICSQLSchemaImport.tables(fromSQL: """
            CREATE TABLE orders (a INTEGER);
            CREATE TABLE ORDERS (b INTEGER);
            """)
        }
    }

    @Test("A malformed CREATE TABLE is refused; a file with none says so")
    func refusalsAreByName() throws {
        #expect(throws: BASICSQLSchemaImport.Failure.self) {
            try BASICSQLSchemaImport.tables(fromSQL: "CREATE TABLE (a INTEGER);")
        }
        #expect(throws: BASICSQLSchemaImport.Failure.self) {
            try BASICSQLSchemaImport.tables(fromSQL: "CREATE TABLE T;")
        }
        #expect(throws: BASICSQLSchemaImport.Failure.self) {
            try BASICSQLSchemaImport.tables(fromSQL: "CREATE TABLE T ();")
        }
        // No table is not an error here -- the caller says it in its own words.
        #expect(try BASICSQLSchemaImport.basicSource(fromSQL: "SELECT 1;") == nil)
    }

    // MARK: - The generated class

    @Test("The generated class persists every field, and maps to the same table")
    func generatedClassIsWhatTheMapperReads() throws {
        let source = try #require(try BASICSQLSchemaImport.basicSource(fromSQL: """
        CREATE TABLE customers (
            customer_id  INTEGER PRIMARY KEY AUTOINCREMENT,
            "Full Name"  VARCHAR(120) NOT NULL,
            is_vip       TINYINT(1) DEFAULT 0
        );
        """, fileName: "schema.sql"))

        // DB2: persistence is opt in, so a generated class with bare fields
        // would persist nothing -- which would read as a broken importer.
        #expect(source.contains("PUBLIC CustomerId AS integer DATABASE NAME \"customer_id\" KEY"))
        #expect(source.contains("PUBLIC FullName AS string DATABASE NAME \"Full Name\""))
        #expect(source.contains("PUBLIC IsVip AS boolean DATABASE NAME \"is_vip\""))
        #expect(source.contains("CLASS customers"))

        // And it is a class the front end actually accepts: run it, and let the
        // mapper say what table it asked for. The round trip, in one assertion.
        let session = BASICSession(host: TestHost())
        session.program.loadSource(source + "\nPRINT \"ok\"\n", fileName: "generated.bas")
        try session.runProgram()
        let definition = try #require(session.declaredClasses["CUSTOMERS"])
        let mapping = try BASICObjectMapper.map(definition)
        #expect(mapping.tableName == "customers", "the very table the SQL declared")
        #expect(mapping.tier == .explicit)
        #expect(mapping.columns.map(\.columnName) == ["customer_id", "Full Name", "is_vip"])
        #expect(mapping.keyColumn?.columnName == "customer_id")
        #expect(mapping.keyColumn?.isGenerated == true)
        #expect(mapping.column(forField: "IsVip")?.columnType == .boolean)
    }
}
