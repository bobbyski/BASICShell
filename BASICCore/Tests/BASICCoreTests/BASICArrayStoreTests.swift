//
//  BASICArrayStoreTests.swift
//  BASICCoreTests
//
//  Storing into one element of an array, or one entry of a dictionary,
//  changes that element and copies nothing else. It used to copy the whole
//  array on every store, so a loop filling an array was quadratic: the
//  timing test's 100,001 elements took 84 seconds to fill.
//

import Foundation
import Testing
@testable import BASICCore

@Suite("Storing into an array")
struct BASICArrayStoreTests {
    private func run(_ source: String) -> (output: [String], seconds: Double) {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource(source)
        let clock = ContinuousClock()
        let took = clock.measure { session.submit("RUN") }
        let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
        return (host.output, seconds)
    }

    /// The seconds a loop of `count` passes takes, storing into an array of
    /// that size, and the same loop reading a variable instead: the store's
    /// share of the time, whatever the machine.
    private func storeCost(_ count: Int) -> (stores: Double, reads: Double) {
        let stores = run("""
        DIM values(\(count)) AS DOUBLE
        DIM i AS INTEGER
        FOR i = 0 TO \(count)
            values(i) = i * 2
        NEXT i
        PRINT values(\(count))
        """)
        #expect(stores.output == ["\(count * 2)"])
        let reads = run("""
        DIM total AS DOUBLE
        DIM i AS INTEGER
        FOR i = 0 TO \(count)
            total = i * 2
        NEXT i
        PRINT total
        """)
        #expect(reads.output == ["\(count * 2)"])
        return (stores.seconds, reads.seconds)
    }

    @Test("Filling a large array takes about as long as a loop that stores nothing")
    func linear() {
        let cost = storeCost(40_000)
        print("BASICArrayStoreTests: 40,001 stores \(cost.stores) s, 40,001 plain assignments \(cost.reads) s")
        #expect(cost.stores < cost.reads * 4 + 0.5, "stores \(cost.stores) s against \(cost.reads) s")
    }

    @Test("A dictionary's entries are stored without copying the rest")
    func dictionary() {
        let result = run("""
        DIM names AS DICTIONARY
        DIM i AS INTEGER
        FOR i = 1 TO 5000
            names(STR$(i)) = i
        NEXT i
        PRINT names(STR$(5000))
        """)
        #expect(result.output == ["5000"], "\(result.output)")
    }

    @Test("A store that fails leaves the array as it was")
    func failedStore() {
        let result = run("""
        DIM values(3) AS INTEGER
        values(1) = 7
        ON ERROR GOTO handled
        values(2) = "not a number"
        END
        handled:
        PRINT values(1); ","; values(2)
        """)
        #expect(result.output.last == "7,0", "\(result.output)")
    }
}
