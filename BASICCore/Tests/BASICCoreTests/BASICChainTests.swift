import Testing
@testable import BASICCore

/// `CHAIN`, `COMMON`, `RUN file$ [, R]` and `LOAD file$, R` (BBC_ADINS.md A7).
///
/// Each test runs a first program from the session and lets it hand off to
/// programs kept in `TestHost.files`, then reads what reached the output.
@Suite("CHAIN")
struct BASICChainTests {
    /// Runs `main` with the other programs available as files.
    private func run(_ main: String, files: [String: String]) -> [String] {
        let host = TestHost()
        for (name, text) in files { host.files[name] = text }
        let session = BASICSession(host: host)
        session.program.loadSource(main)
        session.submit("RUN")
        return host.output
    }

    @Test("CHAIN carries what COMMON names, and nothing else")
    func commonVariablesSurvive() {
        let output = run("""
        COMMON A, B$, C()
        DIM C(3)
        A = 42: B$ = "kept": C(1) = 7: D = 99
        CHAIN "next.bas"
        PRINT "never"
        """, files: ["next.bas": "PRINT A; B$; C(1); D"])
        #expect(output == ["42kept70"])
    }

    @Test("CHAIN with ALL carries every variable")
    func allVariablesSurvive() {
        let output = run("""
        A = 1: B$ = "b"
        CHAIN "next.bas", , ALL
        """, files: ["next.bas": "PRINT A; B$"])
        #expect(output == ["1b"])
    }

    @Test("CHAIN starts at a line number, a computed one, or a label")
    func chainStartsWhereItIsTold() {
        let numbered = "100 PRINT \"one hundred\"\n200 PRINT \"two hundred\""
        #expect(run("CHAIN \"next.bas\", 200", files: ["next.bas": numbered]) == ["two hundred"])
        #expect(run("L = 100: CHAIN \"next.bas\", L + 100", files: ["next.bas": numbered]) == ["two hundred"])
        let labeled = "PRINT \"top\"\nLater:\nPRINT \"later\""
        #expect(run("CHAIN \"next.bas\", Later", files: ["next.bas": labeled]) == ["later"])
    }

    @Test("GW's .BAS is assumed when the name has none")
    func basExtensionIsAssumed() {
        #expect(run("CHAIN \"next\"", files: ["next.bas": "PRINT \"found\""]) == ["found"])
    }

    @Test("a program that isn't there is an error ON ERROR can trap")
    func missingProgramIsTrappable() {
        let output = run("""
        10 ON ERROR GOTO 100
        20 CHAIN "absent.bas"
        30 END
        100 PRINT "trapped"
        """, files: [:])
        #expect(output == ["trapped"])
    }

    @Test("CHAIN keeps files open, RUN f$ closes them, RUN f$, R keeps them")
    func openFilesFollowTheTable() {
        let writer = """
        OPEN "log.txt" FOR OUTPUT AS #1
        PRINT #1, "first"
        """
        let continues = """
        PRINT #1, "second"
        CLOSE #1
        OPEN "log.txt" FOR INPUT AS #2
        LINE INPUT #2, A$: LINE INPUT #2, B$
        PRINT A$; "+"; B$
        """
        #expect(run(writer + "\nCHAIN \"next.bas\"", files: ["next.bas": continues]) == ["first+second"])
        #expect(run(writer + "\nRUN \"next.bas\", R", files: ["next.bas": continues]) == ["first+second"])
        #expect(run(writer + "\nLOAD \"next.bas\", R", files: ["next.bas": continues]) == ["first+second"])
        let closed = run(writer + "\nRUN \"next.bas\"", files: ["next.bas": "PRINT #1, \"again\""])
        #expect(closed.last?.contains("Bad file number") == true)
    }

    @Test("RUN f$ carries no variables, even ones COMMON names")
    func runCarriesNothing() {
        #expect(run("COMMON A\nA = 5\nRUN \"next.bas\"", files: ["next.bas": "PRINT A"]) == ["0"])
    }

    @Test("the next program starts fresh: GOSUB, ON ERROR and DATA")
    func stacksAndTrapsReset() {
        let output = run("""
        10 ON ERROR GOTO 100
        20 GOSUB 50
        30 END
        50 CHAIN "next.bas"
        100 PRINT "old handler"
        """, files: ["next.bas": "READ X: PRINT X\nDATA 5\nRETURN"])
        #expect(output.first == "5")
        #expect(output.last?.contains("RETURN without GOSUB") == true)
    }

    @Test("CHAIN from inside a FUNCTION is refused")
    func chainInsideFunctionIsRefused() {
        let output = run("""
        FUNCTION Hop() AS DOUBLE
          CHAIN "next.bas"
          RETURN 0
        END FUNCTION
        X = Hop()
        """, files: ["next.bas": "PRINT \"arrived\""])
        #expect(output.last?.contains("inside a FUNCTION") == true)
    }

    @Test("CHAIN MERGE and DELETE are refused by name")
    func mergeAndDeleteAreRefused() {
        #expect(run("CHAIN MERGE \"next.bas\"", files: [:]).joined().contains("CHAIN MERGE is not supported yet"))
        #expect(run("CHAIN \"next.bas\", 10, ALL, DELETE 10-20", files: [:]).joined().contains("DELETE is not supported yet"))
    }

    @Test("a plain LOAD in a program still swaps the stored program and carries on")
    func plainLoadKeepsItsMeaning() {
        let host = TestHost()
        host.files["loadme.bas"] = "10 PRINT \"loaded\""
        let session = BASICSession(host: host)
        session.program.loadSource("10 LOAD \"loadme.bas\"\n20 PRINT \"still here\"")
        session.submit("RUN")
        #expect(host.output == ["still here"])
    }
}
