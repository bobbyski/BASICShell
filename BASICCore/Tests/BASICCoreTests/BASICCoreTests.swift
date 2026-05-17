import Foundation
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

    @Test("Evaluates long string concatenation without recursive stack growth")
    func evaluatesLongStringConcatenation() {
        let host = TestHost()
        let session = BASICSession(host: host)

        let pieces = Array(repeating: "\"A\"", count: 600).joined(separator: " + ")
        session.program.loadSource("""
        let text$ = \(pieces)
        print len(text$)
        """)
        session.submit("run")

        #expect(host.output == ["600"])
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

    @Test("LET can declare typed aggregate variables without initializer")
    func letCanDeclareTypedAggregateVariablesWithoutInitializer() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        class FancyReport
            public Badge as string json name "badge" = "defaultBadge"
        end class

        let report as FancyReport
        print ToJsonString(report, false)

        let payload as dictionary
        payload("name") = "Ada"
        print payload("name")

        let scores(2) as integer
        scores(0) = 10
        scores(1) = 20
        scores(2) = scores(0) + scores(1)
        print scores(2)
        """)
        session.submit("run")

        #expect(host.output == ["{\"badge\":\"defaultBadge\"}", "Ada", "30"])
    }

    @Test("GLOBAL and LOCAL can declare scoped arrays")
    func globalAndLocalCanDeclareScopedArrays() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        option global-let
        global scores(0) as integer
        scores(0) = 1
        gosub Demo
        print scores(0)
        end

        Demo:
        local scores(0) as integer
        scores(0) = 7
        print scores(0)
        return
        """)
        session.submit("run")

        #expect(host.output == ["7", "1"])
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

    @Test("PRINT supports TAB and SPC")
    func printSupportsTabAndSpc() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("PRINT \"A\";SPC(3);\"B\";TAB(10);\"C\"")

        #expect(host.output == ["A   B    C"])
    }

    @Test("GW BASIC numeric intrinsics")
    func gwBasicNumericIntrinsics() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print ABS(-3)
        print CINT(2.6)
        print FIX(-2.6)
        print INT(-2.1)
        print SGN(-5),SGN(0),SGN(5)
        print SIN(0),COS(0),TAN(0)
        print ATN(0),EXP(0),LOG(1),SQR(9)
        """)
        session.submit("RUN")

        #expect(host.output == [
            "3",
            "3",
            "-2",
            "-3",
            "-1            0             1",
            "0             1             0",
            "0             1             0             3"
        ])
    }

    @Test("GW BASIC string intrinsics")
    func gwBasicStringIntrinsics() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print ASC("A")
        print INSTR("BANANA","NA"),INSTR(4,"BANANA","NA")
        print LEFT$("ABCDE",2),MID$("ABCDE",2,3),RIGHT$("ABCDE",2)
        print "X";SPACE$(3);"Y"
        print STR$(12)
        print STRING$(3,"A"),STRING$(2,66)
        print VAL(" -12.5ABC")
        """)
        session.submit("RUN")

        #expect(host.output == [
            "65",
            "3             5",
            "AB            BCD           DE",
            "X   Y",
            " 12",
            "AAA           BB",
            "-12.5"
        ])
    }

    @Test("RND and RANDOMIZE are repeatable with explicit seed")
    func rndAndRandomizeAreRepeatableWithExplicitSeed() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        randomize 123
        let a = RND(1)
        print RND(0) = a
        randomize 123
        print RND = a
        """)
        session.submit("RUN")

        #expect(host.output == ["1", "1"])
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

    @Test("Diagnostics collect multiple source syntax errors")
    func diagnosticsCollectMultipleSourceSyntaxErrors() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "ok"
        print @
        let x =
        """)

        let diagnostics = session.diagnostics()

        #expect(diagnostics.map(\.lineNumber) == [2, 3])
        #expect(diagnostics.allSatisfy { $0.severity == .error })
        #expect(diagnostics.map(\.message).allSatisfy { $0.hasPrefix("Syntax error:") })
    }

    @Test("Diagnostics report class and interface validation errors")
    func diagnosticsReportClassAndInterfaceValidationErrors() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        class Report
            function Summary$(count as integer) as string
                return "base"
            end function
        end class

        class FancyReport
            inherits Report
            overrides function Summary$(count as string) as string
                return count
            end function
        end class
        """)

        let diagnostics = session.diagnostics()

        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].lineNumber == 9)
        #expect(diagnostics[0].message == "Runtime error: CLASS FancyReport method Summary$ OVERRIDES signature does not match inherited method")
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

    @Test("SYSTEM statement prints command output")
    func systemStatementPrintsCommandOutput() {
        let host = TestHost()
        host.systemOutputs["printf hello"] = "hello"
        let session = BASICSession(host: host)

        session.submit("system \"printf hello\"")

        #expect(host.systemCommands == ["printf hello"])
        #expect(host.output == ["hello"])
    }

    @Test("SYSTEM$ function returns command output")
    func systemFunctionReturnsCommandOutput() {
        let host = TestHost()
        host.systemOutputs["printf hello"] = "hello"
        let session = BASICSession(host: host)

        session.submit("print \"result=\"; system$(\"printf hello\")")

        #expect(host.systemCommands == ["printf hello"])
        #expect(host.output == ["result=hello"])
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

    @Test("Execution control breaks at current line")
    func executionControlBreaksAtCurrentLine() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        host.breakAfterOutputCount = 1
        host.executionControl = control
        let session = BASICSession(host: host)

        session.program.loadSource("""
        10 print "tick": goto 10
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected break")
        } catch BASICError.breakRequested(let line) {
            #expect(line == 10)
        }
    }

    @Test("Execution control stops at source line breakpoint")
    func executionControlStopsAtSourceLineBreakpoint() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "before"
        print "break"
        print "after"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        }

        #expect(host.output == ["before"])
    }

    @Test("Execution control treats breakpoint file names as optional current-file metadata")
    func executionControlTreatsBreakpointFileNamesAsOptionalCurrentFileMetadata() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(fileName: "Demo.bas", lineNumber: 2, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "before"
        print "break"
        print "after"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(fileName: "Demo.bas", lineNumber: 2, statementNumber: 0))
        }

        #expect(host.output == ["before"])
    }

    @Test("Execution control stops at breakpoint inside FOR NEXT loop")
    func executionControlStopsAtBreakpointInsideForNextLoop() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        for i = 1 to 3
        print i
        next i
        print "done"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        }

        #expect(host.output == [])
    }

    @Test("Execution control uses physical source lines after blanks")
    func executionControlUsesPhysicalSourceLinesAfterBlanks() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 4, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "before"

        for i = 1 to 2
        print i
        next i
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 4, statementNumber: 0))
        }

        #expect(host.output == ["before"])
    }

    @Test("Execution control exposes GOSUB locals at breakpoint")
    func executionControlExposesGosubLocalsAtBreakpoint() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 6, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        gosub "SubDemo"
        end
        LABEL "SubDemo"
        option local-let
        let scoped as integer = 7
        print scoped
        return
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 6, statementNumber: 0))
        }

        #expect(host.output == [])
        #expect(session.debugCallStack.contains(where: { $0.kind == "GOSUB" }))
        #expect(session.debugLocalVariables.contains(where: { $0.name == "scoped" && $0.value == "7" }))
    }

    @Test("Debugger snapshots expand arrays and TYPE records")
    func debuggerSnapshotsExpandArraysAndTypeRecords() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 13, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        type Student
            Name as string * 20
            Age as integer
        end type
        dim scores(1) as integer
        scores(0) = 10
        scores(1) = 20
        dim students(1) as Student
        students(0).Name = "Ada"
        students(0).Age = 16
        students(1).Name = "Grace"
        students(1).Age = 17
        print "pause"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 13, statementNumber: 0))
        }

        let globals = session.debugGlobalVariables
        let scores = globals.first { $0.name == "scores" }
        #expect(scores?.typeName == "ARRAY OF INTEGER")
        #expect(scores?.children.map(\.name) == ["(0)", "(1)"])
        #expect(scores?.children.map(\.value) == ["10", "20"])

        let students = globals.first { $0.name == "students" }
        #expect(students?.typeName == "ARRAY OF Student")
        #expect(students?.children.count == 2)
        #expect(students?.children.first?.children.first { $0.name == "Name" }?.value == "Ada")
        #expect(students?.children.last?.children.first { $0.name == "Age" }?.value == "17")
    }

    @Test("Debugger snapshots expand dictionaries")
    func debuggerSnapshotsExpandDictionaries() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 5, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        dim scores as dictionary
        scores("Ada") = 98
        scores("Grace") = "A"
        scores("Zero") = false
        print "pause"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 5, statementNumber: 0))
        }

        let scores = session.debugGlobalVariables.first { $0.name == "scores" }
        #expect(scores?.typeName == "DICTIONARY")
        #expect(scores?.value == "3 entries")
        #expect(scores?.children.map(\.name) == ["\"Ada\"", "\"Grace\"", "\"Zero\""])
        #expect(scores?.children.map(\.value) == ["98", "A", "FALSE"])
    }

    @Test("JSON encoding uses opt-in aliases for class fields")
    func jsonEncodingUsesOptInAliasesForClassFields() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        class FancyReport
            public Badge as string json name "badge" = "defaultBadge"
            public myLocalVar as integer = 0
        end class
        dim report as FancyReport
        report = new FancyReport()
        print ToJsonString(report, false)
        report.Badge = "ready"
        print ToJsonString(report, false)
        """)
        session.submit("run")

        #expect(host.output == ["{\"badge\":\"defaultBadge\"}", "{\"badge\":\"ready\"}"])
    }

    @Test("JSON round trip supports dictionaries arrays and NULL")
    func jsonRoundTripSupportsDictionariesArraysAndNull() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        dim payload as dictionary
        payload("name") = "Ada"
        payload("missing") = NULL
        payload("score") = 98
        let json$ = ToJsonString(payload, false)
        print json$
        let decoded = FromJsonString(json$, true)
        print decoded("name")
        print decoded("missing")
        print decoded("score")
        let values = FromJsonString("[1,true,null]", true)
        print values(0)
        print values(1)
        print values(2)
        """)
        session.submit("run")

        #expect(host.output == [
            "{\"missing\":null,\"name\":\"Ada\",\"score\":98}",
            "Ada",
            "NULL",
            "98",
            "1",
            "TRUE",
            "NULL"
        ])
    }

    @Test("JSON can decode into typed records classes and arrays")
    func jsonCanDecodeIntoTypedRecordsClassesAndArrays() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        type Student
            Name as string json name "name" = "Unknown"
            Age as integer json name "age" = 0
            Grade as double json name "grade" = 0
            Scratch as string = "hidden"
        end type

        class FancyReport
            public Badge as string json name "badge" = "defaultBadge"
            public Count as integer json name "count" = 0
            public LocalOnly as string = "secret"
        end class

        let q$ = chr$(34)
        let student as Student
        student = FromJsonString("{" + q$ + "name" + q$ + ":" + q$ + "Ada" + q$ + "," + q$ + "age" + q$ + ":16," + q$ + "grade" + q$ + ":99.5," + q$ + "extra" + q$ + ":1}", true)
        print student.Name
        print student.Age
        print student.Grade
        print student.Scratch

        let report as FancyReport
        report = FromJsonString("{" + q$ + "badge" + q$ + ":" + q$ + "READY" + q$ + "," + q$ + "count" + q$ + ":7," + q$ + "LocalOnly" + q$ + ":" + q$ + "ignored" + q$ + "}", true)
        print report.Badge
        print report.Count
        print report.LocalOnly

        let scores(2) as integer
        scores = FromJsonString("[10,20,30]", true)
        print scores(2)
        """)
        session.submit("run")

        #expect(host.output == [
            "Ada",
            "16",
            "99.5",
            "hidden",
            "READY",
            "7",
            "secret",
            "30"
        ])
    }

    @Test("JSON typed decode reports type mismatch")
    func jsonTypedDecodeReportsTypeMismatch() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        type Student
            Name as string json name "name"
            Age as integer json name "age"
        end type

        let student as Student
        let q$ = chr$(34)
        student = FromJsonString("{" + q$ + "name" + q$ + ":" + q$ + "Ada" + q$ + "," + q$ + "age" + q$ + ":" + q$ + "sixteen" + q$ + "}", true)
        print student.Name
        """)
        session.submit("run")

        #expect(host.output == ["Runtime error: Type Mismatch"])
    }

    @Test("JSON decodes variable length arrays and LEN reports element count")
    func jsonDecodesVariableLengthArraysAndLenReportsElementCount() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        record Student
            Name as string json name "name"
        end record

        record Classroom
            Name as string json name "name"
            Students(*) as Student json name "students"
            StudentsByRowAndSeat(*, *) as Student json name "studentsByRowAndSeat"
        end record

        let q$ = chr$(34)
        let room as Classroom
        room = FromJsonString("{" + q$ + "name" + q$ + ":" + q$ + "OS" + q$ + "," + q$ + "students" + q$ + ":[{" + q$ + "name" + q$ + ":" + q$ + "Ada" + q$ + "},{" + q$ + "name" + q$ + ":" + q$ + "Grace" + q$ + "}]," + q$ + "studentsByRowAndSeat" + q$ + ":[[{"+ q$ + "name" + q$ + ":" + q$ + "Ada" + q$ + "}],[{" + q$ + "name" + q$ + ":" + q$ + "Grace" + q$ + "}]]}", true)
        print room.Name
        print len(room.Students)
        print room.Students(1).Name
        print len(room.StudentsByRowAndSeat)
        print room.StudentsByRowAndSeat(1, 0).Name
        print ToJsonString(room, false)

        let scores(*) as integer
        scores = FromJsonString("[10,20,30,40]", true)
        print len(scores)
        print scores(3)

        let grid(*, *) as integer
        grid = FromJsonString("[[1,2],[3,4]]", true)
        print len(grid)
        print grid(1, 1)
        """)
        session.submit("run")

        #expect(host.output == [
            "OS",
            "2",
            "Grace",
            "2",
            "Grace",
            "{\"name\":\"OS\",\"students\":[{\"name\":\"Ada\"},{\"name\":\"Grace\"}],\"studentsByRowAndSeat\":[[{\"name\":\"Ada\"}],[{\"name\":\"Grace\"}]]}",
            "4",
            "40",
            "4",
            "4"
        ])
    }

    @Test("Modern File class writes reads and decodes JSON")
    func modernFileClassWritesReadsAndDecodesJSON() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        record GradeReport
            Course as string json name "course"
            Scores(*) as integer json name "scores"
        end record

        let report as GradeReport
        report.Course = "Intro"
        report.Scores = FromJsonString("[90,95]", true)

        let output = File()
        output.open("grade-report.json", WRITE, JSON, true)
        output.writeJson(report, true)
        print output.size()
        output.close

        let input = File("grade-report.json", READ, JSON, false)
        let loaded as GradeReport
        loaded = input.json()
        input.close
        print loaded.Course
        print len(loaded.Scores)
        print loaded.Scores(1)

        let text = File("notes.txt", WRITE, TEXT, true)
        text.write("ABCDEF")
        print text.size()
        text.close

        let readback = File("notes.txt", READ, TEXT, false)
        print readback.read(3)
        print readback.read()
        readback.close
        """)
        session.submit("run")

        #expect(host.output == [
            "59",
            "Intro",
            "2",
            "95",
            "6",
            "ABC",
            "DEF"
        ])
    }

    @Test("Modern File class reports create and read errors")
    func modernFileClassReportsCreateAndReadErrors() {
        let existingHost = TestHost()
        existingHost.files["exists.txt"] = "already"
        let existingSession = BASICSession(host: existingHost)
        existingSession.program.loadSource("""
        let f = File("exists.txt", WRITE, TEXT, true)
        """)
        existingSession.submit("run")
        #expect(existingHost.output == ["Runtime error: File Already Exists"])

        let missingHost = TestHost()
        let missingSession = BASICSession(host: missingHost)
        missingSession.program.loadSource("""
        let f = File("missing.txt", READ, TEXT, false)
        """)
        missingSession.submit("run")
        #expect(missingHost.output == ["Runtime error: File Not Found"])
    }

    @Test("CD changes the base directory for BASIC file commands")
    func cdChangesBaseDirectoryForFileCommands() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("CD \"work\"")
        session.submit("10 PRINT \"HELLO\"")
        session.submit("SAVE \"hello.bas\"")
        session.submit("NEW")
        session.submit("LOAD \"hello.bas\"")
        session.submit("LIST")

        #expect(host.currentDirectory == "work")
        #expect(host.files["work/hello.bas"] == "10 PRINT \"HELLO\"")
        #expect(host.output == ["10 PRINT \"HELLO\""])
    }

    @Test("PROMPT command updates the session prompt template")
    func promptCommandUpdatesSessionPromptTemplate() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("PROMPT \"BASIC:%cwd%nl> \"")
        host.currentDirectory = "/tmp/aibasic"

        #expect(session.promptTemplate == "BASIC:%cwd%nl> ")
        #expect(session.prompt == "BASIC:/tmp/aibasic\n> ")

        session.submit("PROMPT \"${user}:${currentdir}> \"")
        #expect(session.prompt == "\(NSUserName()):/tmp/aibasic> ")
    }

    @Test("Debugger snapshots group inherited CLASS fields")
    func debuggerSnapshotsGroupInheritedClassFields() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 12, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        class Report
            public Title as string
        end class
        class FancyReport
            inherits Report
            public Badge as string
        end class
        dim report as FancyReport
        report = new FancyReport()
        report.Title = "Status"
        report.Badge = "READY"
        print "pause"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 12, statementNumber: 0))
        }

        let report = session.debugGlobalVariables.first { $0.name == "report" }
        #expect(report?.typeName == "FancyReport")
        #expect(report?.value == "2 fields")
        #expect(report?.children.map(\.name) == ["Report", "FancyReport"])
        #expect(report?.children.first { $0.name == "Report" }?.children.first { $0.name == "Title" }?.value == "Status")
        #expect(report?.children.first { $0.name == "FancyReport" }?.children.first { $0.name == "Badge" }?.value == "READY")
    }

    @Test("Execution can continue after breakpoint")
    func executionCanContinueAfterBreakpoint() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "before"
        print "break"
        print "after"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            control.ignoreBreakpointOnce(at: location)
        }

        try session.continueProgram(executionControl: control)

        #expect(host.output == ["before", "break", "after"])
    }

    @Test("Execution can step one statement")
    func executionCanStepOneStatement() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setMode(.stepInto)
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "one"
        print "two"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected step pause")
        } catch BASICError.stepComplete(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        }

        #expect(host.output == ["one"])
    }

    @Test("Execution steps through FOR NEXT loops")
    func executionStepsThroughForNextLoops() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setMode(.stepInto)
        let session = BASICSession(host: host)

        session.program.loadSource("""
        for i = 1 to 2
        print i
        next i
        print "done"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected pause after FOR")
        } catch BASICError.stepComplete(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
            #expect(session.debugCallStack.last?.name == "[main]")
        }

        do {
            try session.continueProgram(executionControl: control)
            Issue.record("Expected pause after PRINT")
        } catch BASICError.stepComplete(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 3, statementNumber: 0))
        }

        do {
            try session.continueProgram(executionControl: control)
            Issue.record("Expected pause after NEXT looping")
        } catch BASICError.stepComplete(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        }

        #expect(host.output == ["1"])
    }

    @Test("Execution can step over function calls")
    func executionCanStepOverFunctionCalls() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setMode(.stepInto)
        let session = BASICSession(host: host)

        session.program.loadSource("""
        function Add(a as integer, b as integer) as integer
            return a + b
        end function
        print Add(1, 2)
        print "after"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected first step pause")
        } catch BASICError.stepComplete(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 4, statementNumber: 0))
        }

        control.setMode(.stepOver(depth: session.debugCallDepth))

        do {
            try session.continueProgram(executionControl: control)
            Issue.record("Expected step-over pause")
        } catch BASICError.stepComplete(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 5, statementNumber: 0))
        }

        #expect(host.output == ["3"])
    }

    @Test("Execution can step out of GOSUB frames")
    func executionCanStepOutOfGosubFrames() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 6, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        gosub "SubDemo"
        print "after"
        end
        SubDemo:
            local x as integer = 7
            print "sub"
            return
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected subroutine breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 6, statementNumber: 0))
            #expect(session.debugCallDepth == 1)
            #expect(session.debugCallStack.first?.kind == "GOSUB")
            #expect(session.debugLocalVariables.first?.name == "x")
            control.ignoreBreakpointOnce(at: location)
        }

        control.setMode(.stepOut(depth: session.debugCallDepth))

        do {
            try session.continueProgram(executionControl: control)
            Issue.record("Expected step-out pause")
        } catch BASICError.stepComplete(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        }

        #expect(host.output == ["sub"])
    }

    @Test("Debugger exposes method stack frame and ME local")
    func debuggerExposesMethodStackFrameAndReceiverLocals() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 4, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        class Report
            Title as string
            function Summary$() as string
                return ME.Title
            end function
        end class
        dim report as Report
        report = new Report()
        report.Title = "Status"
        print report.Summary$()
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected method breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 4, statementNumber: 0))
            #expect(session.debugCallStack.first?.kind == "Method")
            #expect(session.debugCallStack.first?.name == "Report.Summary$")
            #expect(session.debugPauseDescription(for: .breakpoint(location)) == "Break at 4 in Method Report.Summary$")
            #expect(session.debugLocalVariables.contains(where: { $0.name == "ME" && $0.typeName == "Report" }))
            let meSnapshot = session.debugLocalVariables.first { $0.name == "ME" }
            #expect(meSnapshot?.children.contains(where: { $0.name == "Title" && $0.value == "Status" }) == true)
            control.ignoreBreakpointOnce(at: location)
        }

        try session.continueProgram(executionControl: control)
        #expect(host.output == ["Status"])
    }

    @Test("Debugger identifies constructor stack frames")
    func debuggerIdentifiesConstructorStackFrames() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 4, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        class Report
            Title as string
            function New(title as string)
                ME.Title = title
            end function
        end class
        dim report as Report
        report = new Report("Status")
        print report.Title
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected constructor breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 4, statementNumber: 0))
            #expect(session.debugCallStack.first?.kind == "Constructor")
            #expect(session.debugCallStack.first?.name == "Report.New")
            #expect(session.debugPauseDescription(for: .breakpoint(location)) == "Break at 4 in Constructor Report.New")
            #expect(session.debugLocalVariables.contains(where: { $0.name == "ME" && $0.typeName == "Report" }))
            control.ignoreBreakpointOnce(at: location)
        }

        try session.continueProgram(executionControl: control)
        #expect(host.output == ["Status"])
    }

    @Test("Debugger describes inherited and overridden method frames")
    func debuggerDescribesInheritedAndOverriddenMethodFrames() throws {
        let inheritedHost = TestHost()
        let inheritedControl = BASICExecutionControl()
        inheritedControl.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 4, statementNumber: 0))
        ])
        let inheritedSession = BASICSession(host: inheritedHost)

        inheritedSession.program.loadSource("""
        class Report
            function Label$() as string
                local baseValue as string = "BASE"
                print baseValue
                return baseValue
            end function
        end class
        class FancyReport
            inherits Report
        end class
        dim fancy as FancyReport
        fancy = new FancyReport()
        print fancy.Label$()
        """)

        do {
            try inheritedSession.runProgram(executionControl: inheritedControl)
            Issue.record("Expected inherited method breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 4, statementNumber: 0))
            let frame = inheritedSession.debugCallStack.first
            #expect(frame?.kind == "Method")
            #expect(frame?.name == "Report.Label$")
            #expect(frame?.declaringClassName == "Report")
            #expect(frame?.receiverClassName == "FancyReport")
            #expect(frame?.isOverride == false)
            inheritedControl.ignoreBreakpointOnce(at: location)
        }

        try inheritedSession.continueProgram(executionControl: inheritedControl)
        #expect(inheritedHost.output == ["BASE", "BASE"])

        let overrideHost = TestHost()
        let overrideControl = BASICExecutionControl()
        overrideControl.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 10, statementNumber: 0))
        ])
        let overrideSession = BASICSession(host: overrideHost)

        overrideSession.program.loadSource("""
        class Report
            function Summary$() as string
                return "BASE"
            end function
        end class
        class FancyReport
            inherits Report
            overrides function Summary$() as string
                local summaryValue as string = "DERIVED"
                print summaryValue
                return summaryValue
            end function
        end class
        dim fancy as FancyReport
        fancy = new FancyReport()
        print fancy.Summary$()
        """)

        do {
            try overrideSession.runProgram(executionControl: overrideControl)
            Issue.record("Expected overridden method breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 10, statementNumber: 0))
            let frame = overrideSession.debugCallStack.first
            #expect(frame?.kind == "Method")
            #expect(frame?.name == "FancyReport.Summary$")
            #expect(frame?.declaringClassName == "FancyReport")
            #expect(frame?.receiverClassName == "FancyReport")
            #expect(frame?.isOverride == true)
            overrideControl.ignoreBreakpointOnce(at: location)
        }

        try overrideSession.continueProgram(executionControl: overrideControl)
        #expect(overrideHost.output == ["DERIVED", "DERIVED"])
    }

    @Test("Debugger exposes locals for a deep mixed stack")
    func debuggerExposesLocalsForDeepMixedStack() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 26, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        gosub "Outer"
        end
        LABEL "Outer"
        option local-let
        let outerSubValue as integer = 40
        dim runner as Runner
        runner = new Runner()
        let result = runner.Start()
        return
        class Runner
            function Start() as integer
                local startValue as integer = 10
                return StandardFunction(ME)
            end function
            function MethodTwo() as integer
                local methodTwoValue as integer = 20
                return InnerFunction()
            end function
        end class
        function StandardFunction(r as Runner) as integer
            local standardValue as integer = 30
            return r.MethodTwo()
        end function
        function InnerFunction() as integer
            local innerValue as integer = 50
            print "pause"
            return innerValue
        end function
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected mixed stack breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 26, statementNumber: 0))
            #expect(session.debugCallStack.map(\.kind) == ["Function", "Method", "Function", "Method", "GOSUB", "Program"])
            #expect(session.debugCallStack.map(\.name) == ["InnerFunction", "Runner.MethodTwo", "StandardFunction", "Runner.Start", "Return", "[main]"])
            #expect(session.debugFrameLocalVariables.count == 6)
            #expect(session.debugFrameLocalVariables[0].contains(where: { $0.name == "innerValue" && $0.value == "50" }))
            #expect(session.debugFrameLocalVariables[1].contains(where: { $0.name == "methodTwoValue" && $0.value == "20" }))
            #expect(session.debugFrameLocalVariables[1].contains(where: { $0.name == "ME" && $0.typeName == "Runner" }))
            #expect(session.debugFrameLocalVariables[2].contains(where: { $0.name == "standardValue" && $0.value == "30" }))
            #expect(session.debugFrameLocalVariables[2].contains(where: { $0.name == "r" && $0.typeName == "Runner" }))
            #expect(session.debugFrameLocalVariables[3].contains(where: { $0.name == "startValue" && $0.value == "10" }))
            #expect(session.debugFrameLocalVariables[3].contains(where: { $0.name == "ME" && $0.typeName == "Runner" }))
            #expect(session.debugFrameLocalVariables[4].contains(where: { $0.name == "outerSubValue" && $0.value == "40" }))
            #expect(session.debugFrameLocalVariables[4].contains(where: { $0.name == "runner" && $0.typeName == "Runner" }))
            #expect(session.debugFrameLocalVariables[5].isEmpty)
            control.ignoreBreakpointOnce(at: location)
        }

        try session.continueProgram(executionControl: control)
        #expect(host.output == ["pause"])
    }

    @Test("Debugger exposes locals for selected GOSUB stack frames")
    func debuggerExposesLocalsForSelectedGosubStackFrames() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 10, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        gosub "Outer"
        end
        LABEL "Outer"
        option local-let
        let outerValue as integer = 7
        gosub "Inner"
        return
        LABEL "Inner"
        let innerValue as integer = 3
        print "pause"
        return
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected nested GOSUB breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 10, statementNumber: 0))
            #expect(session.debugCallStack.map(\.kind) == ["GOSUB", "GOSUB", "Program"])
            #expect(session.debugFrameLocalVariables.count == 3)
            #expect(session.debugFrameLocalVariables[0].contains(where: { $0.name == "innerValue" && $0.value == "3" }))
            #expect(session.debugFrameLocalVariables[1].contains(where: { $0.name == "outerValue" && $0.value == "7" }))
            #expect(session.debugFrameLocalVariables[2].isEmpty)
            control.ignoreBreakpointOnce(at: location)
        }

        try session.continueProgram(executionControl: control)
        #expect(host.output == ["pause"])
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

    @Test("DIM supports numeric and string arrays")
    func dimSupportsArrays() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        dim scores(2) as integer
        scores(0) = 10
        scores(1) = 20
        scores(2) = scores(0) + scores(1)
        print scores(2)
        dim names$(1)
        names$(0) = "Ada"
        names$(1) = names$(0) + " Lovelace"
        print names$(1)
        """)
        session.submit("run")

        #expect(host.output == ["30", "Ada Lovelace"])
    }

    @Test("DIM supports dictionary variables")
    func dimSupportsDictionaryVariables() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        dim scores as dictionary
        scores("Ada") = 98
        scores("Grace") = scores("Ada") + 1
        print scores("Ada")
        print scores("Grace")
        print scores("Missing")
        scores(42) = "answer"
        print scores("42")
        """)
        session.submit("run")

        #expect(host.output == ["98", "99", "", "answer"])
    }

    @Test("TYPE supports record variables")
    func typeSupportsRecordVariables() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        type Student
            Name as string * 20
            Age as integer
            Grade as single
        end type
        dim s as Student
        s.Name = "Grace"
        s.Age = 17
        s.Grade = 98.5
        print s.Name
        print s.Age
        print s.Grade
        """)
        session.submit("run")

        #expect(host.output == ["Grace", "17", "98.5"])
    }

    @Test("DIM supports arrays of TYPE records")
    func dimSupportsArraysOfRecords() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        type Student
            Name as string * 20
            Age as integer
        end type
        dim students(1) as Student
        students(0).Name = "Ada"
        students(0).Age = 16
        students(1).Name = "Grace"
        students(1).Age = students(0).Age + 1
        print students(0).Name
        print students(1).Name
        print students(1).Age
        """)
        session.submit("run")

        #expect(host.output == ["Ada", "Grace", "17"])
    }

    @Test("IMPORT loads functions without running imported top-level statements")
    func importLoadsFunctionsWithoutRunningTopLevelStatements() {
        let host = TestHost()
        host.files["math.bas"] = """
        print "SHOULD NOT RUN"
        function AddOne(value as integer) as integer
            return value + 1
        end function
        """
        let session = BASICSession(host: host)

        session.program.loadSource("""
        import "math.bas"
        print AddOne(4)
        """)
        session.submit("run")

        #expect(host.output == ["5"])
    }

    @Test("IMPORT directory recursively loads BAS files for classes and interfaces")
    func importDirectoryRecursivelyLoadsBasFilesForClassesAndInterfaces() {
        let host = TestHost()
        host.files["lib/interfaces.bas"] = """
        interface Printable
            function Summary$() as string
        end interface
        """
        host.files["lib/models/report.bas"] = """
        print "SHOULD NOT RUN"
        class Report
            implements Printable
            public Title as string

            function New(title as string)
                ME.Title = title
            end function

            function Summary$() as string
                return ME.Title
            end function
        end class
        """
        host.files["lib/readme.txt"] = "ignore me"
        let session = BASICSession(host: host)

        session.program.loadSource("""
        import "lib/"
        dim report as Report
        report = new Report("Imported")
        print report.Summary$()
        """)
        session.submit("run")

        #expect(host.output == ["Imported"])
    }

    @Test("IMPORT preserves file metadata for breakpoints")
    func importPreservesFileMetadataForBreakpoints() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(fileName: "lib/debug.bas", lineNumber: 3, statementNumber: 0))
        ])
        host.files["lib/debug.bas"] = """
        function HitMe() as integer
            print "before"
            print "break"
            return 1
        end function
        """
        let session = BASICSession(host: host)

        session.program.loadSource("""
        import "lib/debug.bas"
        print HitMe()
        print "after"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected imported breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(fileName: "lib/debug.bas", lineNumber: 3, statementNumber: 0))
        }

        #expect(host.output == ["before"])
    }

    @Test("IMPORT diagnostics report imported file names")
    func importDiagnosticsReportImportedFileNames() {
        let host = TestHost()
        host.files["lib/bad.bas"] = """
        @
        """
        let session = BASICSession(host: host)

        session.program.loadSource("""
        import "lib/bad.bas"
        print "root"
        """)
        let diagnostics = session.diagnostics()

        #expect(diagnostics.first?.fileName == "lib/bad.bas")
        #expect(diagnostics.first?.lineNumber == 1)
    }

    @Test("IMPORT resolves nested paths relative to importing file")
    func importResolvesNestedPathsRelativeToImportingFile() {
        let host = TestHost()
        host.files["lib/main.bas"] = """
        import "models/student.bas"
        """
        host.files["lib/models/student.bas"] = """
        class Student
            public Name as string
            function New(name as string)
                ME.Name = name
            end function
        end class
        """
        let session = BASICSession(host: host)

        session.program.loadSource("""
        import "lib/main.bas"
        dim student as Student
        student = new Student("Ada")
        print student.Name
        """)
        session.submit("run")

        #expect(host.output == ["Ada"])
    }

    @Test("IMPORT reports cycles")
    func importReportsCycles() {
        let host = TestHost()
        host.files["lib/a.bas"] = """
        import "b.bas"
        """
        host.files["lib/b.bas"] = """
        import "a.bas"
        """
        let session = BASICSession(host: host)

        session.program.loadSource("""
        import "lib/a.bas"
        print "never"
        """)
        let diagnostics = session.diagnostics()

        #expect(diagnostics.first?.message.contains("Import cycle detected") == true)
        #expect(diagnostics.first?.message.contains("lib/a.bas -> lib/b.bas -> lib/a.bas") == true)
    }

    @Test("DATA READ and RESTORE feed scalar variables")
    func dataReadAndRestoreFeedScalarVariables() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        data Ada, 18, TRUE
        read name$, score%, passed
        print name$, score%, passed
        restore
        read again$
        print again$
        """)
        session.submit("run")

        #expect(host.output == [
            "Ada           18            TRUE",
            "Ada"
        ])
    }

    @Test("READ can fill arrays and TYPE fields")
    func readCanFillArraysAndTypeFields() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        type Student
            Name as string
            Score as integer
        end type
        dim scores(2) as integer
        dim student as Student
        data 10, 20, 30, Grace, 94
        read scores(0), scores(1), scores(2), student.Name, student.Score
        print scores(0), scores(1), scores(2)
        print student.Name, student.Score
        """)
        session.submit("run")

        #expect(host.output == [
            "10            20            30",
            "Grace         94"
        ])
    }

    @Test("READ reports out of DATA")
    func readReportsOutOfData() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        data 1
        read a, b
        """)
        session.submit("run")

        #expect(host.output == ["Runtime error: Out of DATA"])
    }

    @Test("CLASS supports fields and NEW object construction")
    func classSupportsFieldsAndNewObjectConstruction() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        class Report
            public Title as string
            Count as integer
        end class

        dim report as Report
        report = new Report()
        report.Title = "May"
        report.Count = 12
        print report.Title
        print report.Count
        """)
        session.submit("run")

        #expect(host.output == ["May", "12"])
    }

    @Test("CLASS validates implemented interfaces")
    func classValidatesImplementedInterfaces() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        interface Printable
            function Title() as string
        end interface

        class Report
            implements Printable
            public Title as string
            function Title() as string
                return ME.Title
            end function
        end class

        dim report as Report
        report = new Report
        report.Title = "Quarterly"
        print report.Title()
        """)
        session.submit("run")

        #expect(host.output == ["Quarterly"])
    }

    @Test("INTERFACE inheritance requires inherited members")
    func interfaceInheritanceRequiresInheritedMembers() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        interface Named
            function Name$() as string
        end interface

        interface Printable
            inherits Named
            function Text$() as string
        end interface

        class Report
            implements Printable
            public Title as string

            function Name$() as string
                return ME.Title
            end function

            function Text$() as string
                return "Report: " + ME.Title
            end function
        end class

        dim report as Report
        report = new Report()
        report.Title = "Quarterly"
        print report.Name$()
        print report.Text$()
        """)
        session.submit("run")

        #expect(host.output == ["Quarterly", "Report: Quarterly"])
    }

    @Test("INTERFACE typed variables accept conforming objects and dispatch methods")
    func interfaceTypedVariablesAcceptConformingObjectsAndDispatchMethods() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        interface Printable
            function Text$() as string
        end interface

        class Report
            implements Printable
            public Title as string

            function New(title as string)
                ME.Title = title
            end function

            function Text$() as string
                return "Report: " + ME.Title
            end function
        end class

        dim item as Printable
        item = new Report("Quarterly")
        print item.Text$()
        """)
        session.submit("run")

        #expect(host.output == ["Report: Quarterly"])
    }

    @Test("INTERFACE typed variables dispatch explicit implementation mappings")
    func interfaceTypedVariablesDispatchExplicitImplementationMappings() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        interface Printable
            function Text$() as string
        end interface

        class Report
            implements Printable
            public Title as string

            function New(title as string)
                ME.Title = title
            end function

            function Render$() as string implements Printable.Text$
                return "Mapped: " + ME.Title
            end function
        end class

        dim item as Printable
        item = new Report("Quarterly")
        print item.Text$()
        """)
        session.submit("run")

        #expect(host.output == ["Mapped: Quarterly"])
    }

    @Test("INTERFACE typed variables expose only interface members")
    func interfaceTypedVariablesExposeOnlyInterfaceMembers() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        interface Printable
            function Text$() as string
        end interface

        class Report
            implements Printable
            function Text$() as string
                return "Report"
            end function
            function Internal$() as string
                return "Internal"
            end function
        end class

        dim item as Printable
        item = new Report()
        print item.Internal$()
        """)
        session.submit("run")

        #expect(host.output == ["Runtime error: INTERFACE Printable has no method Internal$"])
    }

    @Test("INTERFACE typed variables reject nonconforming objects")
    func interfaceTypedVariablesRejectNonconformingObjects() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        interface Printable
            function Text$() as string
        end interface

        class Report
            function Text$() as string
                return "Report"
            end function
        end class

        dim item as Printable
        item = new Report()
        """)
        session.submit("run")

        #expect(host.output == ["Type error: Cannot assign non-Printable object to item"])
    }

    @Test("INTERFACE rejects unknown inherited interfaces")
    func interfaceRejectsUnknownInheritedInterfaces() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        interface Printable
            inherits Missing
            function Text$() as string
        end interface

        class Report
            implements Printable
            function Text$() as string
                return "report"
            end function
        end class
        """)
        session.submit("run")

        #expect(host.output == ["Runtime error: INTERFACE Printable inherits unknown INTERFACE Missing"])
    }

    @Test("INTERFACE rejects inheritance cycles")
    func interfaceRejectsInheritanceCycles() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        interface A
            inherits B
            function Text$() as string
        end interface

        interface B
            inherits A
            function Name$() as string
        end interface

        class Report
            implements A
            function Text$() as string
                return "text"
            end function
            function Name$() as string
                return "name"
            end function
        end class
        """)
        session.submit("run")

        #expect(host.output == ["Runtime error: INTERFACE A has an inheritance cycle"])
    }

    @Test("CLASS supports explicit interface implementation mapping")
    func classSupportsExplicitInterfaceImplementationMapping() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        interface Printable
            function ToText$() as string
        end interface

        class Report
            implements Printable
            public Title as string

            function Text$() as string implements Printable.ToText$
                return ME.Title
            end function
        end class

        dim report as Report
        report = new Report()
        report.Title = "Mapped"
        print report.Text$()
        """)
        session.submit("run")

        #expect(host.output == ["Mapped"])
    }

    @Test("CLASS supports inheritance and OVERRIDES")
    func classSupportsInheritanceAndOverrides() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        class Report
            public Title as string
            function Summary$() as string
                return ME.Title
            end function
        end class

        class FancyReport
            inherits Report
            public Badge as string
            overrides function Summary$() as string
                return ME.Title + " " + ME.Badge
            end function
        end class

        dim report as FancyReport
        report = new FancyReport()
        report.Title = "Status"
        report.Badge = "READY"
        print report.Summary$()
        """)
        session.submit("run")

        #expect(host.output == ["Status READY"])
    }

    @Test("CLASS base variables dispatch overrides but expose base surface")
    func classBaseVariablesDispatchOverridesButExposeBaseSurface() {
        let overrideHost = TestHost()
        let overrideSession = BASICSession(host: overrideHost)

        overrideSession.program.loadSource("""
        class Report
            public Title as string
            function Summary$() as string
                return ME.Title
            end function
        end class

        class FancyReport
            inherits Report
            public Badge as string
            function New(title as string, badge as string)
                ME.Title = title
                ME.Badge = badge
            end function
            overrides function Summary$() as string
                return ME.Title + " " + ME.Badge
            end function
            function BadgeText$() as string
                return ME.Badge
            end function
        end class

        dim report as Report
        report = new FancyReport("Status", "READY")
        print report.Summary$()
        """)
        overrideSession.submit("run")

        #expect(overrideHost.output == ["Status READY"])

        let surfaceHost = TestHost()
        let surfaceSession = BASICSession(host: surfaceHost)

        surfaceSession.program.loadSource("""
        class Report
            function Summary$() as string
                return "Report"
            end function
        end class

        class FancyReport
            inherits Report
            function BadgeText$() as string
                return "READY"
            end function
        end class

        dim report as Report
        report = new FancyReport()
        print report.BadgeText$()
        """)
        surfaceSession.submit("run")

        #expect(surfaceHost.output == ["Runtime error: CLASS Report has no method BadgeText$"])
    }

    @Test("CLASS base variables expose only base fields")
    func classBaseVariablesExposeOnlyBaseFields() {
        let baseHost = TestHost()
        let baseSession = BASICSession(host: baseHost)

        baseSession.program.loadSource("""
        class Report
            public Title as string
        end class

        class FancyReport
            inherits Report
            public Badge as string
        end class

        dim report as Report
        report = new FancyReport()
        report.Title = "Status"
        print report.Title
        """)
        baseSession.submit("run")

        #expect(baseHost.output == ["Status"])

        let derivedHost = TestHost()
        let derivedSession = BASICSession(host: derivedHost)

        derivedSession.program.loadSource("""
        class Report
            public Title as string
        end class

        class FancyReport
            inherits Report
            public Badge as string
        end class

        dim report as Report
        report = new FancyReport()
        report.Badge = "READY"
        """)
        derivedSession.submit("run")

        #expect(derivedHost.output == ["Runtime error: CLASS Report has no field Badge"])
    }

    @Test("INTERFACE typed variables do not expose fields")
    func interfaceTypedVariablesDoNotExposeFields() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        interface Printable
            function Text$() as string
        end interface

        class Report
            implements Printable
            public Title as string
            function Text$() as string
                return ME.Title
            end function
        end class

        dim item as Printable
        item = new Report()
        print item.Title
        """)
        session.submit("run")

        #expect(host.output == ["Runtime error: INTERFACE Printable has no field Title"])
    }

    @Test("CLASS rejects OVERRIDES with mismatched signatures")
    func classRejectsOverridesWithMismatchedSignatures() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        class Report
            function Summary$(count as integer) as string
                return "base"
            end function
        end class

        class FancyReport
            inherits Report
            overrides function Summary$(count as string) as string
                return count
            end function
        end class

        dim report as FancyReport
        report = new FancyReport()
        print report.Summary$("bad")
        """)
        session.submit("run")

        #expect(host.output == ["Runtime error: CLASS FancyReport method Summary$ OVERRIDES signature does not match inherited method"])
    }

    @Test("CLASS requires OVERRIDES when replacing inherited methods")
    func classRequiresOverridesWhenReplacingInheritedMethods() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        class Report
            function Summary$() as string
                return "base"
            end function
        end class

        class FancyReport
            inherits Report
            function Summary$() as string
                return "child"
            end function
        end class

        dim report as FancyReport
        report = new FancyReport()
        print report.Summary$()
        """)
        session.submit("run")

        #expect(host.output == ["Runtime error: CLASS FancyReport method Summary$ overrides an inherited method; add OVERRIDES"])
    }

    @Test("CLASS constructors initialize objects and methods persist ME changes")
    func classConstructorsInitializeObjectsAndMethodsPersistMeChanges() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        class Report
            public Title as string

            function New(title as string)
                ME.Title = title
            end function

            function Rename$(title as string) as string
                ME.Title = title
                return ME.Title
            end function
        end class

        dim report as Report
        report = new Report("Initial")
        print report.Title
        print report.Rename$("Changed")
        print report.Title
        """)
        session.submit("run")

        #expect(host.output == ["Initial", "Changed", "Changed"])
    }

    @Test("CLASS enforces private fields outside the declaring class")
    func classEnforcesPrivateFieldsOutsideDeclaringClass() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        class Vault
            private Code as string
        end class

        dim vault as Vault
        vault = new Vault()
        vault.Code = "open"
        """)
        session.submit("run")

        #expect(host.output == ["Runtime error: Code is PRIVATE"])
    }

    @Test("CLASS allows protected base fields and methods from subclasses")
    func classAllowsProtectedBaseFieldsAndMethodsFromSubclasses() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        class BaseReport
            protected Code as string

            protected function CodeText$() as string
                return ME.Code
            end function
        end class

        class ChildReport
            inherits BaseReport

            function New(code as string)
                ME.Code = code
            end function

            function Reveal$() as string
                return ME.CodeText$()
            end function
        end class

        dim report as ChildReport
        report = new ChildReport("visible inside")
        print report.Reveal$()
        """)
        session.submit("run")

        #expect(host.output == ["visible inside"])
    }

    @Test("CLASS blocks protected fields and methods outside inheritance boundary")
    func classBlocksProtectedFieldsAndMethodsOutsideInheritanceBoundary() {
        let fieldHost = TestHost()
        let fieldSession = BASICSession(host: fieldHost)

        fieldSession.program.loadSource("""
        class BaseReport
            protected Code as string
        end class

        class ChildReport
            inherits BaseReport
        end class

        dim report as ChildReport
        report = new ChildReport()
        print report.Code
        """)
        fieldSession.submit("run")

        #expect(fieldHost.output == ["Runtime error: Code is PROTECTED"])

        let methodHost = TestHost()
        let methodSession = BASICSession(host: methodHost)

        methodSession.program.loadSource("""
        class BaseReport
            protected function CodeText$() as string
                return "hidden"
            end function
        end class

        class ChildReport
            inherits BaseReport
        end class

        dim report as ChildReport
        report = new ChildReport()
        print report.CodeText$()
        """)
        methodSession.submit("run")

        #expect(methodHost.output == ["Runtime error: CodeText$ is PROTECTED"])
    }

    @Test("CLASS blocks private methods outside the declaring class")
    func classBlocksPrivateMethodsOutsideDeclaringClass() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        class Vault
            private function Code$() as string
                return "open"
            end function
        end class

        dim vault as Vault
        vault = new Vault()
        print vault.Code$()
        """)
        session.submit("run")

        #expect(host.output == ["Runtime error: Code$ is PRIVATE"])
    }
}

private final class TestHost: BASICFileHost, BASICGraphicsHost, BASICSystemHost {
    var output: [String] = []
    var pendingOutput = ""
    var hasPendingUnterminatedOutput = false
    var input: [String] = []
    var files: [String: String] = [:]
    var currentDirectory = "."
    var systemCommands: [String] = []
    var systemOutputs: [String: String] = [:]
    var breakAfterOutputCount: Int?
    weak var executionControl: BASICExecutionControl?
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
        requestBreakIfNeeded()
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
        requestBreakIfNeeded()
    }

    func readLine(prompt: String) -> String? {
        input.isEmpty ? nil : input.removeFirst()
    }

    func loadTextFile(path: String) throws -> String {
        files[resolvedPath(path)] ?? ""
    }

    func saveTextFile(path: String, text: String) throws {
        files[resolvedPath(path)] = text
    }

    func fileExists(path: String) throws -> Bool {
        files[resolvedPath(path)] != nil
    }

    func currentDirectoryPath() throws -> String {
        currentDirectory
    }

    func changeDirectory(path: String) throws {
        currentDirectory = resolvedPath(path)
    }

    func listFiles() throws -> [String] {
        let prefix = currentDirectory == "." ? "" : currentDirectory + "/"
        return files.keys
            .filter { prefix.isEmpty || $0.hasPrefix(prefix) }
            .map { prefix.isEmpty ? $0 : String($0.dropFirst(prefix.count)) }
            .sorted()
    }

    func listFiles(path: String) throws -> [String] {
        let prefix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/\\")) + "/"
        return files.keys
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    private func resolvedPath(_ path: String) -> String {
        if path.hasPrefix("/") || currentDirectory == "." {
            return path
        }
        return currentDirectory + "/" + path
    }

    func runSystemCommand(_ command: String) throws -> String {
        systemCommands.append(command)
        return systemOutputs[command] ?? ""
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

    private func requestBreakIfNeeded() {
        guard let breakAfterOutputCount, output.count >= breakAfterOutputCount else { return }
        executionControl?.requestBreak()
    }
}

private final class TextOnlyHost: BASICFileHost {
    var output: [String] = []
    var pendingOutput = ""
    var hasPendingUnterminatedOutput = false
    var files: [String: String] = [:]
    var currentDirectory = "."

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
        files[resolvedPath(path)] ?? ""
    }

    func saveTextFile(path: String, text: String) throws {
        files[resolvedPath(path)] = text
    }

    func fileExists(path: String) throws -> Bool {
        files[resolvedPath(path)] != nil
    }

    func currentDirectoryPath() throws -> String {
        currentDirectory
    }

    func changeDirectory(path: String) throws {
        currentDirectory = resolvedPath(path)
    }

    func listFiles() throws -> [String] {
        let prefix = currentDirectory == "." ? "" : currentDirectory + "/"
        return files.keys
            .filter { prefix.isEmpty || $0.hasPrefix(prefix) }
            .map { prefix.isEmpty ? $0 : String($0.dropFirst(prefix.count)) }
            .sorted()
    }

    func listFiles(path: String) throws -> [String] {
        let prefix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/\\")) + "/"
        return files.keys
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    private func resolvedPath(_ path: String) -> String {
        if path.hasPrefix("/") || currentDirectory == "." {
            return path
        }
        return currentDirectory + "/" + path
    }
}
