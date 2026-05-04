import Testing
@testable import BASICCore

@Suite("BASICCore")
struct BASICCoreTests {
    @Test("Runs arithmetic and looping programs")
    func runsProgram() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("10 LET X = 1")
        session.submit("20 PRINT X")
        session.submit("30 LET X = X + 1")
        session.submit("40 IF X <= 3 THEN 20")
        session.submit("50 END")
        session.submit("RUN")

        #expect(host.output == ["1", "2", "3"])
    }

    @Test("Supports immediate statements")
    func immediateStatements() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("PRINT \"HELLO\"")

        #expect(host.output == ["HELLO"])
    }

    @Test("Colon separates statements")
    func colonStatementSeparator() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("CLS:PRINT \"HELLO\"")

        #expect(host.output == ["\u{001B}[2J\u{001B}[H", "HELLO"])
    }

    @Test("REM ignores the rest of the line")
    func remIgnoresRestOfLine() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "start"
        rem print "x: ";x
        print "done"
        """)
        session.submit("RUN")

        #expect(host.output == ["start", "done"])
    }

    @Test("Comment aliases ignore the rest of the line")
    func commentAliasesIgnoreRestOfLine() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "start"
        ' print "apostrophe"
        # print "hash"
        // print "slash"
        print "done" ' trailing apostrophe comment
        print "ok" // trailing slash comment
        """)
        session.submit("RUN")

        #expect(host.output == ["start", "done", "ok"])
    }

    @Test("Hash comments are only recognized at the start of a physical line")
    func hashCommentsOnlyStartPhysicalLines() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("PRINT \"ok\": # not a trailing comment")

        #expect(host.output == [
            """
            PRINT "ok": # not a trailing comment
                        ^
            Syntax error: Unexpected character #
            """
        ])
    }

    @Test("Trailing backslash joins physical lines")
    func trailingBackslashJoinsPhysicalLines() {
        let host = TestHost()
        let program = BASICProgram()

        program.loadSource("""
        print "A"; \\
        "B"
        print \\
        "C"
        """)

        let session = BASICSession(host: host)
        session.program.loadSource(program.listing())
        session.submit("RUN")

        #expect(host.output == ["AB", "C"])
    }

    @Test("PRINT supports comma tabs and semicolon joins")
    func printSeparators() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("PRINT \"x=\";5")
        session.submit("PRINT \"A\",\"B\"")

        #expect(host.output == ["x=5", "A             B"])
    }

    @Test("Syntax errors include source and caret context")
    func syntaxErrorContext() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("10 PRINT \"OK\"")
        session.submit("20 skdjfhs fhkdsfhsdfk")
        session.submit("RUN")

        #expect(host.output == [
            """
            skdjfhs fhkdsfhsdfk
                    ^
            Syntax error: Expected =
            """
        ])
    }

    @Test("Graphics commands explain they require BASICStudio on text-only hosts")
    func studioOnlyGraphicsError() {
        let host = TextOnlyHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        screen 1
        pset (2,3), 2
        """)
        session.submit("RUN")

        #expect(host.output == ["Unsupported feature: you must run this program in BASICStudio"])
    }

    @Test("Stores and lists numbered lines")
    func listing() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("20 PRINT 2")
        session.submit("10 PRINT 1")
        session.submit("LIST")

        #expect(host.output == ["10 PRINT 1\n20 PRINT 2"])
    }

    @Test("Runs unnumbered programs with labels")
    func unnumberedLabels() throws {
        let host = TestHost()
        let program = BASICProgram()
        program.loadSource("""
        let Count = 1
        LoopStart: print Count
        Count = Count + 1
        if Count <= 3 then LoopStart
        end
        """)

        try BASICInterpreter(program: program, host: host).run()

        #expect(host.output == ["1", "2", "3"])
    }

    @Test("Supports LABEL statement and GOSUB labels")
    func labelStatementAndGosub() throws {
        let host = TestHost()
        let program = BASICProgram()
        program.loadSource("""
        GoSub "SayIt"
        end
        LABEL "SayIt"
        print "ok"
        return
        """)

        try BASICInterpreter(program: program, host: host).run()

        #expect(host.output == ["ok"])
    }

    @Test("Listing preserves user casing")
    func listingPreservesCase() {
        let host = TestHost()
        let program = BASICProgram()
        program.loadSource("""
        10 print MixedCase
        MyLabel: LeT MixedCase = 42
        """)
        let session = BASICSession(host: host)
        session.program.loadSource(program.listing())
        session.submit("LIST")

        #expect(host.output == ["10 print MixedCase\nMyLabel: LeT MixedCase = 42"])
    }

    @Test("LOAD supports line-number-free source")
    func loadLineNumberFreeSource() {
        let host = TestHost()
        host.files["demo.bas"] = """
        let X = 7
        Print X
        """
        let session = BASICSession(host: host)

        session.submit("load \"demo.bas\"")
        session.submit("run")

        #expect(host.output == ["7"])
    }

    @Test("Loaded source ignores shebang")
    func shebangSource() throws {
        let host = TestHost()
        let program = BASICProgram()
        program.loadSource("""
        #!/usr/bin/env aibasic
        Start: print "script"
        end
        """)

        try BASICInterpreter(program: program, host: host).run()

        #expect(host.output == ["script"])
    }

    @Test("Graphics statements call the host")
    func graphicsStatements() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        screen 1
        pset (2,3), 2
        print point(2,3)
        preset (2,3)
        print point(2,3)
        line (0,0)-(4,4), 3
        """)
        session.submit("run")

        #expect(host.screenMode?.number == 1)
        #expect(host.output == ["2", "0"])
        #expect(host.lines.count == 1)
        #expect(host.lines.first?.0 == 0)
        #expect(host.lines.first?.1 == 0)
        #expect(host.lines.first?.2 == 4)
        #expect(host.lines.first?.3 == 4)
        #expect(host.lines.first?.4 == 3)
    }
}

private final class TestHost: BASICFileHost, BASICGraphicsHost {
    var output: [String] = []
    var input: [String] = []
    var files: [String: String] = [:]
    var screenMode: BASICScreenMode?
    var pixels: [String: Int] = [:]
    var lines: [(Int, Int, Int, Int, Int)] = []

    func printLine(_ text: String) {
        output.append(text)
    }

    func readLine(prompt: String) -> String? {
        input.isEmpty ? nil : input.removeFirst()
    }

    func loadTextFile(path: String) throws -> String {
        files[path] ?? ""
    }

    func setScreenMode(_ mode: BASICScreenMode) {
        screenMode = mode
        pixels.removeAll()
    }

    func setGraphicsColor(_ color: Int) {}

    func clearGraphics(color: Int?) {
        pixels.removeAll()
    }

    func setPixel(x: Int, y: Int, color: Int) {
        pixels["\(x),\(y)"] = color
    }

    func getPixel(x: Int, y: Int) -> Int {
        pixels["\(x),\(y)"] ?? 0
    }

    func drawLine(x1: Int, y1: Int, x2: Int, y2: Int, color: Int) {
        lines.append((x1, y1, x2, y2, color))
    }
}

private final class TextOnlyHost: BASICFileHost {
    var output: [String] = []
    var files: [String: String] = [:]

    func printLine(_ text: String) {
        output.append(text)
    }

    func readLine(prompt: String) -> String? {
        nil
    }

    func loadTextFile(path: String) throws -> String {
        files[path] ?? ""
    }
}
