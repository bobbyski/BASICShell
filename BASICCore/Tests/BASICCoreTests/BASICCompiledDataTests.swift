import Foundation
import Testing
@testable import BASICCore

/// The database as a compiled program reaches it (D3, D12).
///
/// The point of these is not that the bridge moves values — it is that the
/// *same mapper* decides the table either way. A compiled program's classes
/// are slot lists by the time it runs, so the compiler describes them and
/// `BASICDataCompiledSchema` reads the description back; if that reconstitution
/// were even slightly off, the two engines would write different tables from
/// the same source, and the divergence would be in stored data.
@Suite("BASICCompiledData")
struct BASICCompiledDataTests {

    /// What `DatabaseSchemaDescriptor` emits for ``source``, verbatim.
    ///
    /// Pinned as a literal on purpose: the compiler is a different package and
    /// cannot be imported here, so the two ends of this seam are held together
    /// by both sides asserting the same text. `DatabaseSchemaTests` in
    /// BASICCompilerKitTests asserts the compiler produces it.
    static let descriptor = """
    {"classes":[{"base":null,"fields":[\
    {"db":{"index":true,"key":true,"name":"Id","unique":true},"meta":{"version":{"n":2}},\
    "name":"Id","owner":"CUSTOMER","type":{"k":"integer"},"vis":"PUBLIC"},\
    {"db":{"name":"customer_name"},"name":"Name","owner":"CUSTOMER","type":{"k":"string"},"vis":"PUBLIC"},\
    {"db":{"name":"State"},"name":"State","owner":"CUSTOMER","type":{"k":"enum","n":"Status"},"vis":"PUBLIC"},\
    {"name":"Notes","owner":"CUSTOMER","type":{"k":"string"},"vis":"PUBLIC"},\
    {"name":"Secret","owner":"CUSTOMER","type":{"k":"string"},"vis":"PRIVATE"}],"name":"Customer"}],\
    "enums":[{"cases":[{"name":"Pending","value":0},{"name":"Shipped","value":1}],"name":"Status"}]}
    """

    /// The program the descriptor came from.
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

    @Test("The compiler's description maps to exactly what the source does")
    func reconstitutionIsParity() throws {
        // The interpreter's way: parse, and read the definition off the session.
        let session = BASICSession(host: TestHost())
        session.program.loadSource(Self.source, fileName: "test.bas")
        try session.runProgram()
        let declared = try #require(session.declaredClasses["CUSTOMER"])
        let interpreted = try BASICObjectMapper.map(declared) {
            session.declaredEnums[$0.uppercased()]
        }

        // The compiled way: read the compiler's description of the same source.
        let schema = try BASICDataCompiledSchema(json: Self.descriptor)
        let described = try #require(schema.definition(named: "Customer"))
        let compiled = try BASICObjectMapper.map(described) { schema.enumeration(named: $0) }

        #expect(compiled == interpreted, "the two engines would write different tables")
        // Spelled out, so a failure says which part moved rather than just
        // "not equal".
        #expect(compiled.tableName == "Customer")
        #expect(compiled.tier == .explicit)
        #expect(compiled.version == 2)
        #expect(compiled.columns.map(\.columnName) == ["Id", "customer_name", "State"])
        #expect(compiled.keyColumn?.isGenerated == true)
        #expect(compiled.column(forField: "State")?.enumName == "Status")
        #expect(compiled.schema.column(named: "State")?.enumeratedNames == ["Pending", "Shipped"])
        #expect(compiled.column(forField: "Notes") == nil, "no DATABASE marker, no column")
    }

    @Test("Visibility survives the trip, which is what tier 0 rests on")
    func visibilityIsCarried() throws {
        // §3.1's last tier persists every *public* field. A description that
        // lost visibility would quietly persist a private one.
        let schema = try BASICDataCompiledSchema(json: """
        {"classes":[{"fields":[
          {"name":"Id","vis":"PUBLIC","type":{"k":"integer"}},
          {"name":"Name","vis":"PUBLIC","type":{"k":"string"}},
          {"name":"Secret","vis":"PRIVATE","type":{"k":"string"}}
        ],"name":"Customer"}],"enums":[]}
        """)
        let mapping = try BASICObjectMapper.map(try #require(schema.definition(named: "Customer")))
        #expect(mapping.tier == .everything)
        #expect(mapping.columns.map(\.columnName) == ["Id", "Name"])
        #expect(mapping.keyColumn?.fieldName == "Id", "DB4's convention still applies")
    }

    @Test("An unreadable description is refused, not half-read")
    func badDescriptionRefused() {
        #expect(throws: BASICDataError.self) { _ = try BASICDataCompiledSchema(json: "not json") }
        #expect(throws: BASICDataError.self) {
            _ = try BASICDataCompiledSchema(json: #"{"classes":[{"fields":[]}]}"#)
        }
        #expect(throws: BASICDataError.self) {
            _ = try BASICDataCompiledSchema(json: #"{"classes":[{"name":"C","fields":[{"type":{"k":"integer"}}]}]}"#)
        }
    }

    // MARK: - The bridge itself

    @Test("A compiled program saves an object and loads it back")
    func savesAndLoadsThroughTheBridge() throws {
        try BASICCompiledData.registerSchema(Self.descriptor)
        let database = try BASICCompiledData.make(typeName: "SqlDatabase", arguments: [.string(":memory:")])
        guard case .handle(let databaseID, let databaseKind) = database else {
            Issue.record("SqlDatabase did not answer with a handle")
            return
        }
        #expect(databaseKind == "SqlDatabase")

        let store = try BASICCompiledData.make(typeName: "DataStore", arguments: [database])
        guard case .handle(let storeID, _) = store else {
            Issue.record("DataStore did not answer with a handle")
            return
        }
        func call(_ method: String, _ arguments: [BASICCompiledData.Value]) throws -> BASICCompiledData.Value {
            try BASICCompiledData.call(typeName: "DataStore", id: storeID, method: method, arguments: arguments)
        }
        _ = try call("EnsureSchema", [.string("Customer")])

        // Saved with no key: the database fills it in, and the object comes
        // back knowing it — the same contract the interpreter has.
        let saved = try call("Save", [.object(typeName: "Customer", fields: [
            "ID": .number(0),
            "NAME": .string("Ada Lovelace"),
            "STATE": .number(1),
            "NOTES": .string("not persisted"),
            "SECRET": .string("nor this"),
        ])])
        guard case .object(let typeName, let fields) = saved else {
            Issue.record("Save did not answer with an object")
            return
        }
        #expect(typeName == "Customer")
        #expect(fields["ID"] == .number(1))

        let loaded = try call("Load", [.string("Customer"), .number(1)])
        guard case .object(_, let back) = loaded else {
            Issue.record("Load did not answer with an object")
            return
        }
        #expect(back["NAME"] == .string("Ada Lovelace"))
        // §7.3: the column held the case *name*, and it reads back as the number.
        #expect(back["STATE"] == .number(1))
        // Never stored, and still present: an object off the wire is a whole
        // instance of its class, at the default for what the table does not hold.
        #expect(back["NOTES"] == .string(""))
        #expect(back["SECRET"] == .string(""))

        #expect(try call("Count", [.string("Customer")]) == .number(1))
        _ = try BASICCompiledData.call(typeName: "SqlDatabase", id: databaseID, method: "Close", arguments: [])
    }

    @Test("The raw layer binds parameters rather than splicing them")
    func rawLayerBindsParameters() throws {
        let database = try BASICCompiledData.make(typeName: "SqlDatabase", arguments: [.string(":memory:")])
        guard case .handle(let id, _) = database else {
            Issue.record("SqlDatabase did not answer with a handle")
            return
        }
        func call(_ method: String, _ arguments: [BASICCompiledData.Value]) throws -> BASICCompiledData.Value {
            try BASICCompiledData.call(typeName: "SqlDatabase", id: id, method: method, arguments: arguments)
        }
        _ = try call("Execute", [.string("create table T (Name text)")])
        // DB15: a value that reads as SQL is a value.
        _ = try call("Execute", [.string("insert into T (Name) values (?)"), .string("'); drop table T; --")])

        let cursor = try call("Query", [.string("select count(*) as c from T")])
        guard case .handle(let cursorID, let kind) = cursor else {
            Issue.record("Query did not answer with a Recordset")
            return
        }
        #expect(kind == "Recordset")
        #expect(try BASICCompiledData.call(typeName: "Recordset", id: cursorID, method: "Read", arguments: []) == .boolean(true))
        #expect(try BASICCompiledData.call(typeName: "Recordset", id: cursorID, method: "Number", arguments: [.string("c")]) == .number(1))
        _ = try BASICCompiledData.call(typeName: "Recordset", id: cursorID, method: "Close", arguments: [])
        _ = try call("Close", [])
    }

    @Test("A Recordset is produced, and says so when named as a constructor")
    func recordsetIsNotConstructible() {
        #expect(throws: BASICCompiledData.Failure.self) {
            _ = try BASICCompiledData.make(typeName: "Recordset", arguments: [])
        }
        #expect(throws: BASICCompiledData.Failure.self) {
            _ = try BASICCompiledData.make(typeName: "Nonesuch", arguments: [])
        }
    }

    @Test("A failure crosses as the message the interpreter would have shown")
    func failuresKeepTheirMessage() {
        do {
            _ = try BASICCompiledData.make(typeName: "SqlDatabase", arguments: [.string("wat://nowhere")])
            Issue.record("an unrecognized connection string was accepted")
        } catch let failure as BASICCompiledData.Failure {
            #expect(failure.message == "No database provider recognizes wat://nowhere")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}

/// The one registration point, held (D0.5).
///
/// The scar this guards against is named in `BASICKeywords.pseudoClasses`: a
/// class missing from one site "constructs, then reports 'has no method' for
/// everything, which reads like a broken binding rather than a missing
/// registration". For a database that reads like a driver bug. So every name on
/// the roster is exercised here through every site that has to know it.
@Suite("BASICDatabaseClasses")
struct BASICDatabaseRosterTests {

    @Test("Every name on the roster is a keyword")
    func theRosterIsTheKeywordList() {
        for pseudoClass in BASICDatabaseClasses.all {
            #expect(BASICKeywords.pseudoClasses.contains(pseudoClass.normalizedName), "\(pseudoClass.displayName)")
            #expect(BASICKeywords.isKeyword(pseudoClass.displayName), "\(pseudoClass.displayName)")
        }
        #expect(BASICDatabaseClasses.all.count == 4)
    }

    @Test("Every constructible name constructs, interpreted")
    func everyNameConstructs() throws {
        for pseudoClass in BASICDatabaseClasses.all where pseudoClass.isConstructible {
            let session = BASICSession(host: TestHost())
            // DataStore takes a database; the others take the URL their own
            // provider answers to. Written as a program so this goes through the
            // *language* rather than past it.
            let argument: String
            switch pseudoClass.normalizedName {
            case "DATASTORE": argument = "SqlDatabase(\":memory:\")"
            case "DOCUMENTDATABASE": argument = "\"memory:\""
            default: argument = "\":memory:\""
            }
            session.program.loadSource("""
            let it = \(pseudoClass.displayName)(\(argument))
            print "made"
            """, fileName: "roster.bas")
            #expect(throws: Never.self, "\(pseudoClass.displayName) did not construct") {
                try session.runProgram()
            }
        }
    }

    @Test("A produced name refuses construction in its own words, not by falling through")
    func producedNamesSaySo() throws {
        for pseudoClass in BASICDatabaseClasses.all where !pseudoClass.isConstructible {
            let session = BASICSession(host: TestHost())
            session.program.loadSource("let it = \(pseudoClass.displayName)()", fileName: "roster.bas")
            do {
                try session.runProgram()
                Issue.record("\(pseudoClass.displayName) was constructible")
            } catch let error as BASICError {
                // Its own message, from the roster -- so "Unknown CLASS" can
                // never be what a program is told about a class the language has.
                #expect(error.description.contains(pseudoClass.constructorDescription), "\(error.description)")
            }
        }
    }

    @Test("Every name dispatches methods rather than reporting none")
    func everyNameDispatches() throws {
        // The scar exactly: a name that constructs and then says "has no
        // method" for everything. Asking for a method that does not exist must
        // name the *class*, which only happens if dispatch reached it.
        let session = BASICSession(host: TestHost())
        session.program.loadSource("""
        let db = SqlDatabase(":memory:")
        db.Execute("create table T (a integer)")
        let rows = db.Query("select a from T")
        let store = DataStore(db)
        print "ok"
        """, fileName: "roster.bas")
        try session.runProgram()

        for (name, receiver) in [("SqlDatabase", "db"), ("Recordset", "rows"), ("DataStore", "store")] {
            let probe = BASICSession(host: TestHost())
            probe.program.loadSource("""
            let db = SqlDatabase(":memory:")
            db.Execute("create table T (a integer)")
            let rows = db.Query("select a from T")
            let store = DataStore(db)
            \(receiver).NoSuchMethod()
            """, fileName: "roster.bas")
            do {
                try probe.runProgram()
                Issue.record("\(name).NoSuchMethod did not fail")
            } catch let error as BASICError {
                #expect(error.description.contains(name), "\(name): \(error.description)")
                #expect(error.description.contains("NoSuchMethod"), "\(error.description)")
            }
        }
    }
}
