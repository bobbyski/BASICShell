import Foundation
import Testing
@testable import BASICCore

/// The database pseudo classes, driven from BASIC.
///
/// Everything above this suite is Swift proving itself to Swift. This is the
/// part a program can actually reach (D3).
@Suite("BASICDatabaseProgram")
struct BASICDatabaseProgramTests {

    private func run(_ source: String) throws -> [String] {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource(source, fileName: "test.bas")
        try session.runProgram()
        return host.output
    }

    @Test("A program opens a database, writes and reads it back")
    func rawSQLFromBASIC() throws {
        let output = try run("""
        let db = SqlDatabase(":memory:")
        db.Execute("create table Customer (Id integer primary key autoincrement, Name text, Balance real)")
        db.Execute("insert into Customer (Name, Balance) values (?, ?)", "Ada", 250)
        db.Execute("insert into Customer (Name, Balance) values (?, ?)", "Grace", 50)

        let rows = db.Query("select Name, Balance from Customer where Balance > ? order by Balance desc", 60)
        while rows.Read()
            print rows.Text$("Name"); " "; rows.Number("Balance")
        wend
        rows.Close()
        db.Close()
        """)
        #expect(output == ["Ada 250"])
    }

    @Test("A value that looks like SQL is a value")
    func parametersAreBound() throws {
        let output = try run("""
        let db = SqlDatabase(":memory:")
        db.Execute("create table Customer (Id integer primary key autoincrement, Name text)")
        db.Execute("insert into Customer (Name) values (?)", "Ada'; drop table Customer--")

        let rows = db.Query("select Name from Customer")
        while rows.Read()
            print rows.Text$("Name")
        wend
        rows.Close()

        let check = db.Query("select count(*) as n from Customer")
        check.Read()
        print "rows "; check.Number("n")
        check.Close()
        db.Close()
        """)
        #expect(output == ["Ada'; drop table Customer--", "rows 1"])
    }

    @Test("The ORM saves and loads a class with no SQL written")
    func ormFromBASIC() throws {
        let output = try run("""
        class Customer
            public Id as integer database key
            public Name as string database name "customer_name"
            public Balance as double database
            public Vip as boolean database
        end class

        let db = SqlDatabase(":memory:")
        let store = DataStore(db)
        store.EnsureSchema("Customer")

        dim c as Customer
        c = new Customer()
        c.Name = "Ada"
        c.Balance = 250
        c.Vip = true
        c = store.Save(c)
        print "saved as "; c.Id

        dim found as Customer
        found = store.Load("Customer", c.Id)
        print found.Name; " "; found.Balance; " "; found.Vip

        print "count "; store.Count("Customer")
        print "deleted "; store.Delete("Customer", c.Id)
        print "count "; store.Count("Customer")
        db.Close()
        """)
        #expect(output == [
            "saved as 1",
            "Ada 250 TRUE",
            "count 1",
            "deleted 1",
            "count 0",
        ])
    }

    @Test("Tier 0: a class with no markers is stored anyway")
    func tierZeroFromBASIC() throws {
        let output = try run("""
        class Note
            public Id as integer
            public Body as string
        end class

        let db = SqlDatabase(":memory:")
        let store = DataStore(db)
        store.EnsureSchema("Note")

        dim n as Note
        n = new Note()
        n.Body = "the least a program can do"
        n = store.Save(n)

        dim back as Note
        back = store.Load("Note", n.Id)
        print back.Body
        print store.Describe$("Note")
        db.Close()
        """)
        #expect(output.first == "the least a program can do")
        // Describe prints the way up from tier 0: pasteable tier-2 annotations.
        #expect(output.contains { $0.contains("tier: everything") })
        #expect(output.contains { $0.contains("public Body as string database") })
    }

    @Test("The same program runs against a document store")
    func documentStoreFromBASIC() throws {
        let output = try run("""
        class Customer
            public Id as integer database key
            public Name as string database
        end class

        let db = DocumentDatabase("memory://app")
        let store = DataStore(db)
        store.EnsureSchema("Customer")

        dim c as Customer
        c = new Customer()
        c.Name = "Ada"
        c = store.Save(c)

        dim found as Customer
        found = store.Load("Customer", c.Id)
        print found.Name
        print "transactions "; store.SupportsTransactions()
        db.Close()
        """)
        #expect(output == ["Ada", "transactions FALSE"])
    }

    @Test("A rolled-back transaction leaves nothing behind")
    func transactionsFromBASIC() throws {
        let output = try run("""
        class Customer
            public Id as integer database key
            public Name as string database
        end class

        let db = SqlDatabase(":memory:")
        let store = DataStore(db)
        store.EnsureSchema("Customer")

        dim a as Customer
        a = new Customer()
        a.Name = "Ada"
        a = store.Save(a)

        store.Begin()
        dim g as Customer
        g = new Customer()
        g.Name = "Grace"
        g = store.Save(g)
        print "inside "; store.Count("Customer")
        store.Rollback()
        print "after "; store.Count("Customer")
        db.Close()
        """)
        #expect(output == ["inside 2", "after 1"])
    }

    @Test("An unknown method and a bad connection string each say so")
    func errorsAreNamed() throws {
        #expect(throws: (any Error).self) {
            try run("""
            let db = SqlDatabase("postgres://nowhere/app")
            """)
        }
        #expect(throws: (any Error).self) {
            try run("""
            let db = SqlDatabase(":memory:")
            db.Frobnicate("x")
            """)
        }
    }
}
