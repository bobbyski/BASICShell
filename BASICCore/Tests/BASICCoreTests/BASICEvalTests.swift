import Foundation
import Testing
@testable import BASICCore

/// `EVAL(s$)` in the interpreter (BBC_ADINS.md A10, Bobby's ruling B8):
/// an expression in a string, in the current scope, pure unless
/// `OPTION EVAL FULL`, its syntax errors trappable as ERR 2.
@Suite("EVAL")
struct BASICEvalTests {
    private func run(_ source: String) -> [String] {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource(source)
        session.submit("RUN")
        return host.output
    }

    @Test("a formula over the program's variables, numbers and strings")
    func formulas() {
        #expect(run("X = 3: PRINT EVAL(\"X * 2 + 1\")") == ["7"])
        #expect(run("Q$ = CHR$(34): A$ = \"ab\": PRINT EVAL(\"A$ + \" + Q$ + \"c\" + Q$)") == ["abc"])
        #expect(run("PRINT EVAL(\"2 = 2\"); EVAL(\"2 > 3\")") == run("PRINT 2 = 2; 2 > 3"), "= compares, as in VBScript")
        #expect(run("DIM V(3): V(2) = 5: PRINT EVAL(\"V(2) * 2\")") == ["10"])
    }

    @Test("BBC's computed-name trick reads the variable the string names")
    func computedNames() {
        #expect(run("SCORE1 = 10: SCORE2 = 20: FOR I = 1 TO 2: PRINT EVAL(\"SCORE\" + MID$(STR$(I), 2)): NEXT I") == ["10", "20"])
    }

    @Test("a FUNCTION's locals, and the program's own FUNCTIONs")
    func scopeAndFunctions() {
        let output = run("""
        FUNCTION Square(N AS DOUBLE) AS DOUBLE
          RETURN N * N
        END FUNCTION
        FUNCTION Plot(X AS DOUBLE, F$ AS STRING) AS DOUBLE
          LOCAL K = 10
          RETURN EVAL(F$)
        END FUNCTION
        PRINT Plot(3, "Square(X) + K")
        """)
        #expect(output == ["19"])
    }

    @Test("a string that does not parse is ERR 2 on the EVAL's line, which ON ERROR traps")
    func syntaxErrorsAreTrappable() {
        let output = run("""
        10 ON ERROR GOTO 100
        20 X = EVAL("2 +")
        30 PRINT "after"
        40 END
        100 PRINT "ERR"; ERR; "ERL"; ERL
        110 RESUME NEXT
        """)
        #expect(output == ["ERR2ERL20", "after"])
        #expect(run("X = EVAL(\"(1\")").joined().contains("Syntax error in EVAL"))
    }

    @Test("pure by default; OPTION EVAL FULL opens the rest, and AWAIT never")
    func purity() {
        #expect(run("Q$ = CHR$(34): PRINT EVAL(\"SYSTEM$(\" + Q$ + \"ls\" + Q$ + \")\")").joined().contains("EVAL cannot use SYSTEM$ without OPTION EVAL FULL"))
        #expect(run("PRINT EVAL(\"INKEY$\")").joined().contains("EVAL cannot use INKEY$ without OPTION EVAL FULL"))
        #expect(run("Q$ = CHR$(34): SETENV \"EVALTEST\", \"yes\": PRINT EVAL(\"ENVIRON$(\" + Q$ + \"EVALTEST\" + Q$ + \")\")").joined().contains("without OPTION EVAL FULL"))
        #expect(run("OPTION EVAL FULL: Q$ = CHR$(34): SETENV \"EVALTEST\", \"yes\": PRINT EVAL(\"ENVIRON$(\" + Q$ + \"EVALTEST\" + Q$ + \")\")") == ["yes"])
        #expect(run("OPTION EVAL FULL: OPTION EVAL PURE: PRINT EVAL(\"PWD$\")").joined().contains("without OPTION EVAL FULL"))
        #expect(run("OPTION EVAL FULL: X = EVAL(\"AWAIT 1\")").joined().contains("EVAL cannot AWAIT"))
        #expect(run("Q$ = CHR$(34): PRINT EVAL(\"LEN(\" + Q$ + \"abc\" + Q$ + \") + SQR(16) + LN(1)\")") == ["7"])
    }
}
