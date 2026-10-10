//
//  BASICTimerTests.swift
//  BASICCoreTests
//
//  TIMER() is the seconds since local midnight, with the fraction, as VB and
//  QuickBASIC have it: what a program times itself with (the timing test in
//  demos/language compares the interpreter with WebAssembly by it). `timer`
//  without the parentheses stays an ordinary name, as programs use it.
//

import Foundation
import Testing
@testable import BASICCore

@Suite("TIMER()")
struct BASICTimerTests {
    private func run(_ source: String) -> [String] {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource(source)
        session.submit("RUN")
        return host.output
    }

    @Test("Seconds since local midnight, with the fraction")
    func sinceMidnight() throws {
        let midnight = Calendar.current.startOfDay(for: Date())
        let later = midnight.addingTimeInterval(3723.25)
        #expect(BASICInterpreter.secondsSinceMidnight(later) == 3723.25)
        #expect(BASICInterpreter.secondsSinceMidnight(midnight) == 0)
    }

    @Test("A program reads it as a number within the day, and it does not go back")
    func inAProgram() {
        let output = run("""
        first = TIMER()
        FOR i = 1 TO 1000 : NEXT i
        last = TIMER()
        IF first >= 0 AND first < 86400 THEN PRINT "in a day"
        IF last >= first OR last < 1 THEN PRINT "in order"
        """)
        #expect(output == ["in a day", "in order"])
    }

    @Test("`timer` without parentheses is still a name a program can use")
    func stillAName() {
        let output = run("""
        timer = 5
        timer = timer + 1
        PRINT timer
        """)
        #expect(output == ["6"])
    }
}
