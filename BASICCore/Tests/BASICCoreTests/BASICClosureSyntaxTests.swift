import Foundation
import Testing
@testable import BASICCore

/// Closure syntax in the interpreter (Documents/CLOSURES.md, Phase 3): a
/// multi-line closure wherever an expression goes, VOID closures, nesting.
@Suite("Closure syntax")
struct BASICClosureSyntaxTests {
    private func run(_ source: String) -> [String] {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource(source)
        session.submit("RUN")
        return host.output
    }

    /// `BASICCompiler/Tests/Programs/closure-syntax.bas`, which a `basicc`
    /// binary must print the same.
    @Test("the syntax conformance program prints what basicc prints")
    func conformanceProgram() {
        #expect(run("""
            ' Closure syntax (Documents/CLOSURES.md, Phase 3): a multi-line closure
            ' wherever an expression goes, VOID closures, nesting, VARIANT results.
            FUNCTION TYPE Unary(x AS INTEGER) AS INTEGER
            FUNCTION TYPE Action() AS VOID
            TYPE Holder
              F AS Unary
            END TYPE

            FUNCTION Apply(f AS Unary, n AS INTEGER) AS INTEGER
              RETURN f(n)
            END FUNCTION

            FUNCTION Twice(a AS Action) AS VOID
              a()
              a()
            END FUNCTION

            FUNCTION Hello() AS VOID
              PRINT "HELLO"
            END FUNCTION

            FUNCTION MakeAdder(n AS INTEGER) AS Unary
              RETURN FUNCTION(x AS INTEGER) AS INTEGER
                RETURN x + n
              END FUNCTION
            END FUNCTION

            ' An argument, the call going on after END FUNCTION.
            PRINT "APPLY"; Apply(FUNCTION(x AS INTEGER) AS INTEGER
              LOCAL y AS INTEGER = x * 2
              RETURN y + 1
            END FUNCTION, 5)

            ' A VOID closure: no AS on the multi-line form.
            count = 0
            Twice(FUNCTION()
              count = count + 1
            END FUNCTION)
            PRINT "COUNT"; count

            ' AS VOID on the one-line form runs a call.
            DIM greet AS Action
            greet = FUNCTION() AS VOID = Hello()
            greet()

            ' After RETURN.
            add5 = MakeAdder(5)
            PRINT "ADDER"; add5(10)

            ' Assigned to a field.
            DIM h AS Holder
            h.F = FUNCTION(x AS INTEGER) AS INTEGER
              RETURN x * 10
            END FUNCTION
            PRINT "FIELD"; h.F(4)

            ' Nested.
            outer = FUNCTION(a AS INTEGER) AS INTEGER
              inner = FUNCTION(b AS INTEGER) AS INTEGER
                RETURN a * b
              END FUNCTION
              RETURN inner(3) + 1
            END FUNCTION
            PRINT "NESTED"; outer(7)

            ' VARIANT results.
            pick = FUNCTION(n AS INTEGER) = n * 2
            PRINT "VARIANT"; pick(21)
            mixed = FUNCTION(n AS INTEGER) AS VARIANT
              IF n > 0 THEN RETURN "POSITIVE"
              RETURN n
            END FUNCTION
            PRINT "MIXED "; mixed(1); mixed(-2)
            """) == ["APPLY11", "COUNT2", "HELLO", "ADDER15", "FIELD40", "NESTED22", "VARIANT42", "MIXED POSITIVE-2"])
    }

    @Test("a multi-line closure needs its END FUNCTION, and nothing but a comment may follow one that ends an assignment")
    func endFunction() {
        #expect(run("f = FUNCTION(x AS INTEGER) AS INTEGER\n  RETURN x\n").joined().contains("without END FUNCTION"))
        #expect(run("f = FUNCTION(x AS INTEGER) AS INTEGER\n  RETURN x\nEND FUNCTION, 3").joined().contains("Unexpected text after END FUNCTION"))
        #expect(run("f = FUNCTION(x AS INTEGER) AS INTEGER\n  RETURN x * 2\nEND FUNCTION ' doubles\nPRINT f(4)") == ["8"])
    }

    /// `BASICCompiler/Tests/Programs/closure-async.bas` (CLOSURES.md 3.9,
    /// 3.10), which a `basicc` binary must print the same.
    @Test("the async closure conformance program prints what basicc prints")
    func asyncConformanceProgram() {
        #expect(run("""
            ' Async closures (Documents/CLOSURES.md 3.9, 3.10): ASYNC FUNCTION(...)
            ' makes a closure whose call starts a task, as an ASYNC FUNCTION's does,
            ' and an ASYNC FUNCTION TYPE variable holds one.
            ASYNC FUNCTION TYPE Loader(n AS INTEGER) AS STRING
            FUNCTION TYPE Plain(n AS INTEGER) AS STRING

            DIM loader AS Loader
            loader = ASYNC FUNCTION(n AS INTEGER) AS STRING
              RETURN "LOADED" + STR$(n)
            END FUNCTION
            t = loader(7)
            PRINT AWAIT t

            quick = ASYNC FUNCTION(x AS INTEGER) AS INTEGER = x * 2
            PRINT "QUICK"; AWAIT quick(21)

            ' A task sees the globals as they were when it started, as an ASYNC
            ' FUNCTION's does, and keeps what it assigns to them...
            counter = 10
            bump = ASYNC FUNCTION() AS INTEGER
              counter = counter + 1
              RETURN counter
            END FUNCTION
            PRINT "BUMPED"; AWAIT bump(); counter

            ' ...and shares the locals its closure shares.
            ASYNC FUNCTION TYPE Adder() AS INTEGER
            FUNCTION Tally() AS INTEGER
              LOCAL n AS INTEGER = 0
              LOCAL inc AS Adder
              inc = ASYNC FUNCTION() AS INTEGER
                n = n + 5
                RETURN n
              END FUNCTION
              x = AWAIT inc()
              RETURN n
            END FUNCTION
            PRINT "TALLY"; Tally()

            ' An async closure is not a plain function type's, nor the other way round.
            ON ERROR GOTO Trapped
            DIM v AS VARIANT
            v = loader
            DIM plain AS Plain
            plain = v
            PRINT "AFTER PLAIN"
            v = FUNCTION(n AS INTEGER) AS STRING = "SYNC"
            loader = v
            PRINT "AFTER LOADER"
            END

            Trapped:
              PRINT "TRAPPED"; ERR
              RESUME NEXT
            """) == ["LOADED 7", "QUICK42", "BUMPED1110", "TALLY5", "TRAPPED13", "AFTER PLAIN", "TRAPPED13", "AFTER LOADER"])
    }

    @Test("a closure running as a task shows its task in the debugger, with its name and where it was made")
    func debuggerShowsTasks() throws {
        let control = BASICExecutionControl()
        control.setBreakpoints([BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 6, statementNumber: 0))])
        let session = BASICSession(host: TestHost())
        session.program.loadSource("""
        slow = ASYNC FUNCTION() AS INTEGER
          n = AWAIT SLEEP(500)
          RETURN 1
        END FUNCTION
        t = slow()
        yield
        """)
        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint {}
        let slow = try #require(session.debugGlobalVariables.first { $0.name == "slow" })
        #expect(slow.children.contains { $0.name == "Name" && $0.value == "[anonymous closure]" })
        #expect(slow.children.contains { $0.name == "Made At" && $0.value == "line 1" })
        #expect(slow.children.contains { $0.name == "Signature" && $0.value.hasPrefix("ASYNC ") })
        #expect(slow.children.contains { $0.name == "Running As" && $0.value.hasPrefix("task #") })
    }

    @Test("a breakpoint inside a closure's body stops there, with the closure's locals and frame, and Continue goes on (4.6)")
    func breakpointInClosureBody() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        let control = BASICExecutionControl()
        let inBody = BASICBreakpointLocation(lineNumber: 4, statementNumber: 0)
        control.setBreakpoints([BASICBreakpoint(location: inBody)])
        session.program.loadSource("""
        total = 0
        add = FUNCTION(n AS INTEGER) AS INTEGER
          LOCAL doubled AS INTEGER = n * 2
          total = total + doubled
          RETURN total
        END FUNCTION
        x = add(5)
        PRINT x
        """)
        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == inBody)
        }
        #expect(session.debugLocalVariables.contains { $0.name == "doubled" && $0.value == "10" })
        #expect(session.debugLocalVariables.contains { $0.name == "n" && $0.value == "5" })
        #expect(session.debugCallStack.contains { $0.name == "add" })
        control.ignoreBreakpointOnce(at: inBody)
        try session.continueProgram(executionControl: control)
        #expect(host.output == ["10"])
    }

    /// `BASICCompiler/Tests/Programs/closure-error.bas`: an error in a
    /// closure's body is placed on its own line, in both engines (4.9).
    @Test("an error inside a closure's body is placed on its line, as basicc places it")
    func errorInClosureBody() {
        #expect(run("""
            ' A runtime error inside a closure's body is placed on its own line, in
            ' both engines, as one in a FUNCTION is (Documents/CLOSURES.md 4.9).
            divide = FUNCTION(x AS INTEGER) AS INTEGER
              LOCAL y AS INTEGER = 0
              RETURN x / y
            END FUNCTION
            PRINT "BEFORE"
            PRINT divide(1)
            """) == ["BEFORE", "  RETURN x / y\n  ^\nRuntime error: Division by zero at 5"])
    }
}
