//
//  BASICErrorLocationTests.swift
//  BASICCoreTests
//
//  A runtime error from a running program says where it happened (BASIC-9):
//  the failing statement's source line, a caret under where the statement
//  starts, and the message with the line ERL reports.
//

import Foundation
import Testing
@testable import BASICCore

@Suite("Runtime error locations")
struct BASICErrorLocationTests {
    private func run(_ source: String) -> [String] {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource(source)
        session.submit("RUN")
        return host.output
    }

    @Test("An error inside a function is placed at the statement that failed, not the call")
    func insideAFunction() {
        let output = run("""
        FUNCTION Inner(x AS INTEGER) AS INTEGER
            RETURN 10 / x
        END FUNCTION
        PRINT "BEFORE"
        y = Inner(0)
        """)
        #expect(output == ["BEFORE", "    RETURN 10 / x\n    ^\nRuntime error: Division by zero at 2"])
    }

    @Test("On a line of several statements, the caret is under the one that failed")
    func compoundLine() {
        let output = run("""
        10 PRINT "A"
        20 X = 1 : Y = X / 0
        """)
        #expect(output.last == "X = 1 : Y = X / 0\n        ^\nRuntime error: Division by zero at 20")
    }

    @Test("A tab before the statement stays a tab before the caret")
    func tabs() {
        let output = run("FUNCTION F() AS INTEGER\n\tRETURN 1 / 0\nEND FUNCTION\nPRINT F()")
        #expect(output.last == "\tRETURN 1 / 0\n\t^\nRuntime error: Division by zero at 2")
    }

    @Test("ERL is the line of the statement that failed, inside whatever function")
    func erlIsTheInnerLine() {
        let output = run("""
        ON ERROR GOTO Handler
        FUNCTION Inner(x AS INTEGER) AS INTEGER
            RETURN 10 / x
        END FUNCTION
        y = Inner(0)
        END
        Handler:
        PRINT "ERL"; ERL; "ERR"; ERR
        END
        """)
        #expect(output.joined().filter { $0 != " " } == "ERL3ERR11")
    }

    @Test("A direct command has no program line, so its error stays bare")
    func directMode() {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.submit("PRINT 1 / 0")
        #expect(host.output == ["Runtime error: Division by zero"])
    }

    @Test("A type error is placed the same way")
    func typeError() {
        let output = run("""
        DIM n AS INTEGER
        n = "text"
        """)
        #expect(output.last?.hasPrefix("n = \"text\"\n^\nType error:") == true, "\(output)")
        #expect(output.last?.hasSuffix(" at 2") == true, "\(output)")
    }
}
