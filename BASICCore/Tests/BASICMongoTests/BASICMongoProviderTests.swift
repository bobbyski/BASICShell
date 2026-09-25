import BASICCore
import Foundation
import MongoKitten
import Testing
@testable import BASICMongo

/// MongoDB, through MongoKitten (D8, DB13).
///
/// Most of these need no server, and that is on purpose: what can be wrong
/// without one is the *translation* — a predicate becoming a filter, a value
/// becoming BSON and coming back — and that is where a driver's bugs live.
/// The behavioral suite is the one every provider shares, and it runs against
/// a real `mongod` when `BASIC_MONGO_URL` names one.
@Suite("BASICMongoProvider")
struct BASICMongoProviderTests {

    // MARK: - What it answers to

    @Test("Both MongoDB spellings are recognized, and nothing else")
    func handlesItsOwnURLs() {
        #expect(BASICMongoProvider.handles("mongodb://localhost:27017/shop"))
        // `+srv` is a different scheme to a URL parser and the same database to
        // a person, which is why `handles` is a match and not a constant.
        #expect(BASICMongoProvider.handles("mongodb+srv://cluster.example.com/shop"))
        #expect(BASICMongoProvider.handles("MONGODB://LOCALHOST/shop"))
        #expect(!BASICMongoProvider.handles("sqlite:///tmp/shop.db"))
        #expect(!BASICMongoProvider.handles(":memory:"))
        #expect(!BASICMongoProvider.handles("jdbc:postgresql://host/db"))
    }

    @Test("A connection string it does not recognize is refused by name")
    func badURLsAreRefused() async {
        let provider = BASICMongoProvider()
        await #expect(throws: BASICDataError.self) { try await provider.open(":memory:") }
        #expect(!provider.isOpen)
    }

    @Test("It exists wherever Swift does; reaching a server is a separate question")
    func availabilityIsNotReachability() {
        // DB17 separates "this build has the driver" from "this machine can
        // reach the database". Conflating them turns a firewall into a missing
        // feature, which sends someone looking in the wrong place.
        #expect(BASICMongoProvider.isAvailableOnThisPlatform)
        #expect(BASICMongoProvider.providerName == "MongoDB")
    }

    @Test("Transactions are reported absent, because a standalone mongod has none")
    func capabilitiesAreRead() {
        let capabilities = BASICMongoProvider().capabilities
        // DB14: reported rather than attempted, so `store.Begin` says so
        // instead of failing halfway through.
        #expect(!capabilities.supportsTransactions)
        #expect(capabilities.supportsIndexes)
        #expect(capabilities.reportsGeneratedKeys)
        // §7.1: declined here, so a MATCHES predicate is refused where it is
        // built rather than turned into a regular expression nobody wrote.
        #expect(!capabilities.operators.contains(.matches))
        #expect(capabilities.operators.contains(.beginsWith))
    }

    // MARK: - Registration (DB11)

    @Test("Registering is what makes mongodb:// a string this process knows")
    func registrationIsTheSeam() {
        BASICMongoProvider.register()
        #expect(BASICDataProviders.documentProviderNames.contains("MongoDB"))
        // Registering twice replaces rather than accumulates: a test process
        // running two programs must not end up with two drivers.
        BASICMongoProvider.register()
        #expect(BASICDataProviders.documentProviderNames.filter { $0 == "MongoDB" }.count == 1)
    }

    // MARK: - Values

    @Test("A value survives the trip through BSON")
    func valuesRoundTrip() {
        func roundTrip(_ value: BASICDataValue) -> BASICDataValue? {
            BASICMongoProvider.value(BASICMongoProvider.primitive(value))
        }
        #expect(roundTrip(.text("Ada")) == .text("Ada"))
        #expect(roundTrip(.integer(42)) == .integer(42))
        #expect(roundTrip(.double(2.5)) == .double(2.5))
        #expect(roundTrip(.boolean(true)) == .boolean(true))
        #expect(roundTrip(.null) == .null)
        #expect(roundTrip(.blob(Data([1, 2, 3]))) == .blob(Data([1, 2, 3])))
    }

    @Test("DB19's four cross as text, not as BSON's own types")
    func exactValuesKeepTheirExactness() {
        // A BSON date is an instant and a BASIC `DATE` has no time, so storing
        // one as the other invents a midnight. A DECIMAL written as a double
        // would lose the exactness the type exists for -- so both go as text,
        // and the same rule reads them back.
        let date = BASICDataDate(year: 2026, month: 9, day: 25)
        #expect(BASICMongoProvider.value(BASICMongoProvider.primitive(.date(date))) == .text("2026-09-25"))
        let money = Decimal(string: "19.99")!
        #expect(BASICMongoProvider.value(BASICMongoProvider.primitive(.decimal(money))) == .text("19.99"))
    }

    @Test("A document with nesting and a list comes back the same shape")
    func documentsRoundTrip() {
        var address = BASICDocument()
        address.setScalar("city", .text("London"))
        var customer = BASICDocument()
        customer.setScalar("name", .text("Ada"))
        customer["address"] = .document(address)
        customer["tags"] = .array([.scalar(.text("vip")), .scalar(.text("beta"))])

        let back = BASICMongoProvider.document(BASICMongoProvider.bson(customer))
        #expect(back.scalar("name") == .text("Ada"))
        #expect(back["address"] == .document(address))
        #expect(back["tags"] == .array([.scalar(.text("vip")), .scalar(.text("beta"))]))
    }

    // MARK: - Filters (DB15)

    @Test("A predicate becomes a built filter, never a parsed string")
    func predicatesBecomeFilters() throws {
        func filter(_ predicate: BASICQueryPredicate) throws -> String {
            String(describing: try BASICMongoProvider.query(predicate))
        }
        #expect(try filter(.all) == String(describing: Document()))
        #expect(try filter(.compare("name", .equal, .text("Ada"))).contains("Ada"))
        #expect(try filter(.compare("age", .greaterThan, .integer(30))).contains("$gt"))
        #expect(try filter(.compare(field: "age", op: .between, operand: .range(.integer(1), .integer(9)))).contains("$gte"))
        #expect(try filter(.compare(field: "city", op: .in, operand: .list([.text("A"), .text("B")]))).contains("$in"))
        #expect(try filter(.and([.compare("a", .equal, .integer(1)), .compare("b", .equal, .integer(2))])).contains("$and"))
        #expect(try filter(.not(.compare("a", .equal, .integer(1)))).contains("$nor"))
    }

    @Test("A program's text is data in a filter, never pattern syntax")
    func textIsEscapedInRegularExpressions() throws {
        // The document-store shape of DB15: `$gt`, `$ne` and `$where` get in
        // through a filter assembled from a *string*, and a regular expression
        // built from unescaped text is the same hole one layer down.
        let query = try BASICMongoProvider.query(.compare(field: "name", op: .beginsWith, operand: .value(.text("a.b*c"))))
        let rendered = String(describing: query)
        #expect(rendered.contains("\\."), "a dot is a dot, not any character")
        #expect(rendered.contains("\\*"), "a star is a star")
        #expect(rendered.contains("^"), "BEGINSWITH anchors at the start")
    }

    @Test("An operator the provider declined is refused where the filter is built")
    func declinedOperatorsAreRefused() {
        #expect(throws: BASICDataError.self) {
            try BASICMongoProvider.query(.compare(field: "name", op: .matches, operand: .value(.text("^a.*"))))
        }
    }

    // MARK: - Against a real server

    /// `BASIC_MONGO_URL=mongodb://localhost:27017/basictest swift test`.
    ///
    /// Skipped without one rather than mocked: a driver test that never speaks
    /// the wire protocol proves the translation and nothing else, and saying so
    /// is more useful than a green tick that means less than it looks.
    static var serverURL: String? {
        ProcessInfo.processInfo.environment["BASIC_MONGO_URL"]
    }

    @Test("Against a real mongod, the document contract holds",
          .enabled(if: BASICMongoProviderTests.serverURL != nil))
    func theContractHoldsAgainstAServer() async throws {
        let url = try #require(Self.serverURL)
        let provider = BASICMongoProvider()
        try await provider.open(url)
        #expect(provider.isOpen)
        #expect(try await provider.ping())

        let collection = "basictest_\(UUID().uuidString.prefix(8))"
        var ada = BASICDocument()
        ada.setScalar("name", .text("Ada"))
        ada.setScalar("balance", .integer(250))
        let key = try await provider.insert(collection: collection, document: ada)
        #expect(key != .null, "the store assigned a key")

        let found = try await provider.find(collection: collection, filter: .compare("name", .equal, .text("Ada")), limit: nil)
        #expect(found.count == 1)
        #expect(found.first?.scalar("balance") == .integer(250))

        try await provider.ensureIndex(collection: collection, fields: ["name"], unique: true)
        #expect(try await provider.collections().contains(collection))

        #expect(try await provider.delete(collection: collection, filter: .all) == 1)
        await provider.close()
        #expect(!provider.isOpen)
    }
}
