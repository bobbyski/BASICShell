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

    @Test("RUN clears direct-mode variables before starting")
    func runClearsVariables() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("let x = 5")
        session.program.loadSource("""
        print x
        let x = 9
        """)
        session.submit("RUN")
        session.submit("print x")

        #expect(host.output == ["0", "9"])
    }

    @Test("OPTION LOCAL-LET makes LET local inside GOSUB")
    func optionLocalLetMakesLetLocalInsideGosub() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        option local-let
        let x = 1
        gosub Demo
        print x
        end
        Demo:
        let x = 2
        print x
        return
        """)
        session.submit("RUN")

        #expect(host.output == ["2", "1"])
    }

    @Test("GLOBAL can be updated from local context")
    func globalCanBeUpdatedFromLocalContext() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        option local-let
        global total as integer = 0
        gosub AddOne
        print total
        end
        AddOne:
        local temp as integer = 1
        total = total + temp
        return
        """)
        session.submit("RUN")

        #expect(host.output == ["1"])
    }

    @Test("OPTION GLOBAL-LET keeps LET global")
    func optionGlobalLetKeepsLetGlobal() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        option global-let
        let x = 1
        gosub Demo
        print x
        end
        Demo:
        let x = 2
        return
        """)
        session.submit("RUN")

        #expect(host.output == ["2"])
    }

    @Test("AS type suffix conflicts are reported")
    func asTypeSuffixConflictsAreReported() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("global x$ as integer = 5")

        #expect(host.output == [
            """
            global x$ as integer = 5
                   ^
            Type error: suffix $ conflicts with AS INTEGER
            """
        ])
    }

    @Test("Boolean variables accept TRUE FALSE 0 and 1")
    func booleanVariables() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("global done as boolean = true")
        session.submit("print done")
        session.submit("done = 0")
        session.submit("print done")
        session.submit("done = 1")
        session.submit("print done + 1")

        #expect(host.output == ["TRUE", "FALSE", "2"])
    }

    @Test("Typed assignment rejects incompatible values")
    func typedAssignmentRejectsIncompatibleValues() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("global count as integer = 1.5")

        #expect(host.output == ["Type error: Cannot assign non-integer value to count"])
    }

    @Test("CHR zero uses data-backed string display and LEN counts characters")
    func chrZeroStringDisplayAndLen() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("print \"A\";chr$(0);\"B\"")
        session.submit("print len(\"A\" + chr$(0) + \"B\")")

        #expect(host.output == ["AB", "2"])
    }

    @Test("SELECT CASE supports values ranges comparisons and else")
    func selectCaseValuesRangesComparisonsAndElse() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        global n as integer = 8
        select case n
        case 1 to 5
        print "low"
        case 6, 7, 8
        print "match"
        case is > 10
        print "high"
        case else
        print "else"
        end select
        """)
        session.submit("RUN")

        #expect(host.output == ["match"])
    }

    @Test("SELECT CASE falls through to CASE ELSE")
    func selectCaseElse() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        global item$ as string = "zebra"
        select case item$
        case "apple", "banana"
        print "fruit"
        case "nuts" to "soup"
        print "pantry"
        case else
        print "other"
        end select
        """)
        session.submit("RUN")

        #expect(host.output == ["other"])
    }

    @Test("EXIT SELECT skips to END SELECT")
    func exitSelect() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        select case 1
        case 1
        print "before"
        exit select
        print "after"
        case else
        print "else"
        end select
        print "done"
        """)
        session.submit("RUN")

        #expect(host.output == ["before", "done"])
    }

    @Test("FOR NEXT loops with default step")
    func forNextDefaultStep() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        for i = 1 to 3
        print i
        next i
        """)
        session.submit("RUN")

        #expect(host.output == ["1", "2", "3"])
    }

    @Test("FOR NEXT supports STEP and negative STEP")
    func forNextStep() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        for i = 1 to 5 step 2
        print i
        next
        for j = 5 to 1 step -2
        print j
        next j
        """)
        session.submit("RUN")

        #expect(host.output == ["1", "3", "5", "5", "3", "1"])
    }

    @Test("FOR NEXT skips loops that do not enter")
    func forNextSkipsUnenteredLoops() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        for i = 5 to 1
        print i
        next i
        print "done"
        """)
        session.submit("RUN")

        #expect(host.output == ["done"])
    }

    @Test("FOR NEXT supports nested loops")
    func forNextNestedLoops() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        for i = 1 to 2
        for j = 1 to 2
        print i;",";j
        next j
        next i
        """)
        session.submit("RUN")

        #expect(host.output == ["1,1", "1,2", "2,1", "2,2"])
    }

    @Test("IF THEN ELSE supports inline statements")
    func ifThenElseInlineStatements() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        for i = 1 to 3
        if i = 2 then print "Two" else print "Not two"
        next i
        """)
        session.submit("RUN")

        #expect(host.output == ["Not two", "Two", "Not two"])
    }

    @Test("IF THEN still supports label targets")
    func ifThenStillSupportsLabelTargets() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        let i = 5
        if i = 5 then Five
        print "miss"
        end
        Five:
        print "hit"
        """)
        session.submit("RUN")

        #expect(host.output == ["hit"])
    }

    @Test("Block IF supports ELSEIF ELSE and END IF")
    func blockIfElseIfElseEndIf() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        for i = 1 to 3
        if i = 1 then
        print "one"
        elseif i = 2 then
        print "two"
        else
        print "other"
        end if
        next i
        """)
        session.submit("RUN")

        #expect(host.output == ["one", "two", "other"])
    }

    @Test("Block IF supports nested blocks")
    func blockIfNestedBlocks() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        let day = 4
        let hour = 12
        if day = 3 then
        if hour = 14 or hour = 15 then
        print "wednesday time"
        else
        print "wednesday other"
        end if
        elseif day = 4 then
        if hour = 12 then
        print "thursday time"
        else
        print "thursday other"
        end if
        else
        print "other day"
        end if
        """)
        session.submit("RUN")

        #expect(host.output == ["thursday time"])
    }

    @Test("Functions return typed values")
    func functionsReturnTypedValues() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print Add(2, 3)
        end

        function Add(a as integer, b as integer) as integer
            return a + b
        end function
        """)
        session.submit("RUN")

        #expect(host.output == ["5"])
    }

    @Test("Functions can return by assigning their name")
    func functionsReturnByNameAssignment() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print Title$()
        end

        function Title$() as string
            title$ = "AIBASIC"
        end function
        """)
        session.submit("RUN")

        #expect(host.output == ["AIBASIC"])
    }

    @Test("Functions default to VOID and are skipped in top-level flow")
    func functionsDefaultVoidAndAreSkipped() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "before"
        function SayIt(message as string)
            print message
        end function
        print "after"
        """)
        session.submit("RUN")

        #expect(host.output == ["before", "after"])
    }

    @Test("Recursive functions work")
    func recursiveFunctions() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print Fact(5)
        end

        function Fact(n as integer) as integer
            if n <= 1 then
                return 1
            else
                return n * Fact(n - 1)
            end if
        end function
        """)
        session.submit("RUN")

        #expect(host.output == ["120"])
    }

    @Test("Function parameters require explicit AS type")
    func functionParametersRequireExplicitTypes() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        function Bad(value)
        end function
        """)
        session.submit("RUN")

        #expect(host.output == [
            """
            function Bad(value)
                              ^
            Syntax error: Parameter value requires AS <type>
            """
        ])
    }

    @Test("VOID function cannot return a value")
    func voidFunctionCannotReturnValue() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print Bad()
        end

        function Bad()
            return 1
        end function
        """)
        session.submit("RUN")

        #expect(host.output == ["Runtime error: VOID function Bad cannot be used in an expression"])
    }

    @Test("Explicit VARIANT parameters keep runtime value kind")
    func variantParametersKeepRuntimeKind() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print Echo$("AIBASIC")
        print EchoNumber(7)
        end

        function Echo$(value as variant) as string
            return value
        end function

        function EchoNumber(value as variant) as integer
            return value
        end function
        """)
        session.submit("RUN")

        #expect(host.output == ["AIBASIC", "7"])
    }

    @Test("FOR NEXT works on colon-separated lines")
    func forNextOnColonSeparatedLine() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("10 for i=1 to 3:print \"i=\";i,i*2:next i")
        session.submit("20 for x=1 to 4:print x;:next x")
        session.submit("RUN")

        #expect(host.output == [
            "i=1           2",
            "i=2           4",
            "i=3           6",
            "1234"
        ])
    }

    @Test("PRINT trailing semicolon suppresses newline")
    func printTrailingSemicolonSuppressesNewline() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("10 for x=1 to 4:print x;:next x")
        session.submit("RUN")

        #expect(host.output == ["1234"])
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

    @Test("SAVE writes program and remembers file name")
    func saveWritesProgramAndRemembersFileName() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("10 print \"saved\"")
        session.submit("save \"demo.bas\"")
        session.submit("20 print \"again\"")
        session.submit("save")

        #expect(host.files["demo.bas"] == """
        10 print "saved"
        20 print "again"
        """)
    }

    @Test("LOAD remembers file name for later SAVE")
    func loadRemembersFileNameForSave() {
        let host = TestHost()
        host.files["demo.bas"] = "10 print \"loaded\""
        let session = BASICSession(host: host)

        session.submit("load \"demo.bas\"")
        session.submit("20 print \"updated\"")
        session.submit("save")

        #expect(host.files["demo.bas"] == """
        10 print "loaded"
        20 print "updated"
        """)
    }

    @Test("FILES lists current directory files")
    func filesListsCurrentDirectoryFiles() {
        let host = TestHost()
        host.files["zeta.bas"] = ""
        host.files["alpha.bas"] = ""
        let session = BASICSession(host: host)

        session.submit("files")

        #expect(host.output == ["alpha.bas\nzeta.bas"])
    }

    @Test("SAVE LOAD and FILES can run as program statements")
    func fileCommandsCanRunAsProgramStatements() {
        let host = TestHost()
        host.files["loadme.bas"] = "10 print \"loaded\""
        host.files["other.bas"] = ""
        let session = BASICSession(host: host)

        session.submit("10 files")
        session.submit("20 load \"loadme.bas\"")
        session.submit("30 save \"saved.bas\"")
        session.submit("RUN")

        #expect(host.output == ["loadme.bas\nother.bas"])
        #expect(host.files["saved.bas"] == "10 print \"loaded\"")
    }

    @Test("RUN can start at a line for safe SAVE shortcuts")
    func runCanStartAtLineForSaveShortcut() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("10 print \"do not run\"")
        session.submit("65535 save\"shortcut.bas\"")
        session.submit("RUN 65535")

        #expect(host.output == [])
        #expect(host.files["shortcut.bas"] == """
        10 print "do not run"
        65535 save"shortcut.bas"
        """)
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
    var pendingOutput = ""
    var hasPendingUnterminatedOutput = false
    var input: [String] = []
    var files: [String: String] = [:]
    var screenMode: BASICScreenMode?
    var pixels: [String: Int] = [:]
    var lines: [(Int, Int, Int, Int, Int)] = []

    func print(_ text: String, terminator: String) {
        pendingOutput += text
        if terminator.contains("\n") {
            output.append(pendingOutput)
            pendingOutput = ""
            hasPendingUnterminatedOutput = false
        } else if hasPendingUnterminatedOutput {
            output[output.count - 1] = pendingOutput
        } else {
            output.append(pendingOutput)
            hasPendingUnterminatedOutput = true
        }
    }

    func printLine(_ text: String) {
        if pendingOutput.isEmpty {
            output.append(text)
        } else {
            pendingOutput += text
            output[output.count - 1] = pendingOutput
            pendingOutput = ""
            hasPendingUnterminatedOutput = false
        }
    }

    func readLine(prompt: String) -> String? {
        input.isEmpty ? nil : input.removeFirst()
    }

    func loadTextFile(path: String) throws -> String {
        files[path] ?? ""
    }

    func saveTextFile(path: String, text: String) throws {
        files[path] = text
    }

    func listFiles() throws -> [String] {
        files.keys.sorted()
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
    var pendingOutput = ""
    var hasPendingUnterminatedOutput = false
    var files: [String: String] = [:]

    func print(_ text: String, terminator: String) {
        pendingOutput += text
        if terminator.contains("\n") {
            output.append(pendingOutput)
            pendingOutput = ""
            hasPendingUnterminatedOutput = false
        } else if hasPendingUnterminatedOutput {
            output[output.count - 1] = pendingOutput
        } else {
            output.append(pendingOutput)
            hasPendingUnterminatedOutput = true
        }
    }

    func printLine(_ text: String) {
        if pendingOutput.isEmpty {
            output.append(text)
        } else {
            pendingOutput += text
            output[output.count - 1] = pendingOutput
            pendingOutput = ""
            hasPendingUnterminatedOutput = false
        }
    }

    func readLine(prompt: String) -> String? {
        nil
    }

    func loadTextFile(path: String) throws -> String {
        files[path] ?? ""
    }

    func saveTextFile(path: String, text: String) throws {
        files[path] = text
    }

    func listFiles() throws -> [String] {
        files.keys.sorted()
    }
}
