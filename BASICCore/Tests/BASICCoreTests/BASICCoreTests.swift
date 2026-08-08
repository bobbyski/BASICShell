import Foundation
import Testing
@testable import BASICCore

private final class ThreadSafeStringLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private final class ThreadSafeValueBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    func store(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

private final class ConcurrentOutputProbeHost: BASICHost, @unchecked Sendable {
    private let lock = NSLock()
    private var activeWrites = 0
    private var highestActiveWriteCount = 0
    private var capturedLines: [String] = []

    var maximumConcurrentWrites: Int {
        lock.lock()
        defer { lock.unlock() }
        return highestActiveWriteCount
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return capturedLines
    }

    func print(_ text: String, terminator: String) {
        recordWrite(text + terminator)
    }

    func printLine(_ text: String) {
        recordWrite(text + "\n")
    }

    func readLine(prompt: String) -> String? {
        nil
    }

    private func recordWrite(_ text: String) {
        lock.lock()
        activeWrites += 1
        highestActiveWriteCount = max(highestActiveWriteCount, activeWrites)
        lock.unlock()

        Thread.sleep(forTimeInterval: 0.002)

        lock.lock()
        capturedLines.append(text)
        activeWrites -= 1
        lock.unlock()
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class ProcessObserverProbe: BASICForegroundProcessObserver {
    private(set) var started: [BASICForegroundProcessSnapshot] = []
    private(set) var ended: [BASICForegroundProcessSnapshot] = []

    func foregroundProcessStarted(_ process: BASICForegroundProcessSnapshot) {
        started.append(process)
    }

    func foregroundProcessEnded(_ process: BASICForegroundProcessSnapshot) {
        ended.append(process)
    }
}

private func repositoryRootURL() -> URL {
    URL(fileURLWithPath: String(#filePath))
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func sharedDemoSource(named name: String) throws -> String {
    let url = repositoryRootURL()
        .appendingPathComponent("basicPrograms/demos")
        .appendingPathComponent(name)
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite("BASICCore", .serialized)
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

    @Test("Strings support alternate quotes triple quotes and interpolation")
    func stringsSupportAlternateQuotesTripleQuotesAndInterpolation() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource(#"""
        name$ = 'Ada'
        n = 4
        print 'single " quote'
        print `backtick " and ' quotes`
        print $"Hello ${name$} ${n + 1}"
        print "Plain ${name$}"
        block$ = $"""Hello ${name$}
        count ${n + 2}"""
        print block$
        option stringsub on
        print "Plain ${name$}"
        text$ = """line "one"
        line 'two'
        line `three`"""
        print text$
        """#)

        try session.runProgramInForeground()

        #expect(host.output == [
            "single \" quote",
            "backtick \" and ' quotes",
            "Hello Ada 5",
            "Plain ${name$}",
            "Hello Ada\ncount 6",
            "Plain Ada",
            "line \"one\"\nline 'two'\nline `three`"
        ])
    }

    @Test("Scripts expose path and arguments")
    func scriptsExposePathAndArguments() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.setScriptContext(path: "/tmp/demo.bas", arguments: ["alpha", "beta gamma"])
        session.program.loadSource("""
        PRINT SCRIPT$
        PRINT ARGC
        FOR i = 0 TO ARGC - 1
            PRINT ARGV$(i)
        NEXT i
        """, fileName: "/tmp/demo.bas")

        try session.runProgramInForeground()

        #expect(host.output == ["/tmp/demo.bas", "2", "alpha", "beta gamma"])

        host.output.removeAll()
        session.setScriptContext(path: "/tmp/empty.bas", arguments: [])

        try session.runProgramInForeground()

        #expect(host.output == ["/tmp/empty.bas", "0"])
    }

    @Test("Completion engine finds command and symbol candidates")
    func completionEngineFindsCommandAndSymbolCandidates() {
        let commandContext = BASICCompletionEngine.context(buffer: "pr", cursor: 2)
        #expect(commandContext.token == "pr")
        #expect(commandContext.startOffset == 0)
        #expect(commandContext.isCommandPosition)

        let commandCandidates = BASICCompletionEngine.candidates(
            for: commandContext,
            pathCandidates: [],
            commandWords: ["PRINT", "PROMPT", "grep"],
            symbolWords: ["ProcessItem"]
        )
        #expect(commandCandidates == ["PRINT", "ProcessItem", "PROMPT"])

        let symbolContext = BASICCompletionEngine.context(buffer: "goto Ma", cursor: 7)
        #expect(symbolContext.token == "Ma")
        #expect(symbolContext.startOffset == 5)
        #expect(!symbolContext.isCommandPosition)

        let symbolCandidates = BASICCompletionEngine.candidates(
            for: symbolContext,
            pathCandidates: [],
            commandWords: ["MAKE"],
            symbolWords: ["MainLoop", "MaybeDone"]
        )
        #expect(symbolCandidates == ["MainLoop", "MaybeDone"])
        #expect(BASICCompletionEngine.commonPrefix(symbolCandidates) == "Ma")
    }

    @Test("Completion engine extracts BASIC program symbols")
    func completionEngineExtractsBASICProgramSymbols() {
        let program = BASICProgram()
        program.loadSource("""
        Start:
        label Done
        function Add%(left as integer, right as integer) as integer
        end function
        function type Callback
        def LegacyFn()
        class Widget
        end class
        interface Renderable
        end interface
        type Point
        end type
        dim total%, name$ as string
        global appState as string
        local tempValue as integer
        let currentScore = 0
        """)

        let words = BASICCompletionEngine.programSymbolWords(in: program)

        #expect(words.contains("Start"))
        #expect(words.contains("Done"))
        #expect(words.contains("Add%"))
        #expect(words.contains("Callback"))
        #expect(!words.contains("TYPE"))
        #expect(words.contains("LegacyFn"))
        #expect(words.contains("Widget"))
        #expect(words.contains("Renderable"))
        #expect(words.contains("Point"))
        #expect(words.contains("total%"))
        #expect(words.contains("name$"))
        #expect(words.contains("appState"))
        #expect(words.contains("tempValue"))
        #expect(words.contains("currentScore"))
    }

    @Test("Direct mode question mark aliases PRINT")
    func directModeQuestionMarkAliasesPrint() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("? \"HELLO\"")
        session.submit("?\"WORLD\"")
        session.submit("? 2 + 3")

        #expect(host.output == ["HELLO", "WORLD", "5"])
    }

    @Test("Chained string addition prints once")
    func chainedStringAdditionPrintsOnce() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("PRINT \"A\" + \"B\" + \"C\"")

        #expect(host.output == ["ABC"])
    }

    @Test("Exposes host environment variables and file existence")
    func hostEnvironmentVariablesAndFileExists() {
        let host = TestHost()
        host.currentDirectory = "/tmp/aibasic"
        host.columns = 132
        host.rows = 43
        host.files["/tmp/aibasic/posdata/storeinfo.json"] = "{}"
        let session = BASICSession(host: host)

        session.submit("print currentdir$")
        session.submit("print screenwidth, screenheight")
        session.submit("print fileexists(\"posdata/storeinfo.json\")")
        session.submit("locate 3, 12")

        #expect(host.output == ["/tmp/aibasic", "132           43", "1"])
        #expect(host.locations.count == 1)
        #expect(host.locations.first?.0 == 3)
        #expect(host.locations.first?.1 == 12)
    }

    @Test("Deep left-associative binary chains evaluate without exhausting the Swift stack")
    func deepLeftAssociativeBinaryChainsEvaluateWithoutStackOverflow() {
        let host = TestHost()
        let session = BASICSession(host: host)
        let chain = Array(repeating: "CHR$(65)", count: 2_000).joined(separator: " + ")

        session.submit("PRINT LEN(" + chain + ") > 1999")

        #expect(host.output == ["1"])
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

        #expect(host.output == ["AB", "3"])
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

    @Test("Computed GOTO selects one based target")
    func computedGotoSelectsOneBasedTarget() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        let choice = 2
        goto First, Second, Third on choice
        print "miss"
        end
        First:
        print "first"
        end
        Second:
        print "second"
        end
        Third:
        print "third"
        """)
        session.submit("RUN")

        #expect(host.output == ["second"])
    }

    @Test("ON GOTO selects one based target")
    func onGotoSelectsOneBasedTarget() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        choice = 3
        on choice goto First, Second, Third
        print "miss"
        end
        First:
        print "first"
        end
        Second:
        print "second"
        end
        Third:
        print "third"
        """)
        session.submit("RUN")

        #expect(host.output == ["third"])
    }

    @Test("ON GOTO falls through when selector is out of range")
    func onGotoFallsThroughWhenSelectorIsOutOfRange() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        choice = 0
        on choice goto First, Second
        print "fallthrough"
        end
        First:
        print "first"
        Second:
        print "second"
        """)
        session.submit("RUN")

        #expect(host.output == ["fallthrough"])
    }

    @Test("ON event CALL registers VTG event handlers")
    func onEventCallRegistersVTGEventHandlers() throws {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        on resize call ResizeChanged
        on mouse up call MouseUp
        on gamepad button call GamepadButton
        end

        function ResizeChanged(event as variant)
        end function

        function MouseUp(event as variant)
        end function

        function GamepadButton(event as variant)
        end function
        """)

        try session.runProgram()

        #expect(session.eventHandlers == [
            BASICEventHandlerRegistration(selector: BASICEventSelector(type: "GAMEPAD", subtype: "BUTTON"), handlerName: "GamepadButton", normalizedHandlerName: "GAMEPADBUTTON"),
            BASICEventHandlerRegistration(selector: BASICEventSelector(type: "MOUSE", subtype: "UP"), handlerName: "MouseUp", normalizedHandlerName: "MOUSEUP"),
            BASICEventHandlerRegistration(selector: BASICEventSelector(type: "RESIZE"), handlerName: "ResizeChanged", normalizedHandlerName: "RESIZECHANGED")
        ])
    }

    @Test("ON event CALL requires a defined handler")
    func onEventCallRequiresDefinedHandler() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        on mouse move call MissingHandler
        """)
        session.submit("RUN")

        #expect(host.output == ["Runtime error: Function MissingHandler is not defined"])
    }

    @Test("ON event CALL rejects async handlers for the MVP policy")
    func onEventCallRejectsAsyncHandlersForMVPPolicy() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        on resize call ResizeChanged
        end

        async function ResizeChanged(event as BASICResizeEvent)
        end function
        """)
        session.submit("RUN")

        #expect(host.output == ["Runtime error: Event handler ResizeChanged must be synchronous"])
    }

    @Test("ON timer event rejects async handlers for the MVP policy")
    func onTimerEventRejectsAsyncHandlersForMVPPolicy() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        let timer = SecondsTimer(1)
        on timer call TimerTick
        end

        async function TimerTick(event as BASICTimerEvent)
        end function
        """)
        session.submit("RUN")

        #expect(host.output == ["Runtime error: Event handler TimerTick must be synchronous"])
    }

    @Test("Host resize and mouse events dispatch through shared event loop")
    func hostResizeAndMouseEventsDispatchThroughSharedEventLoop() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        let control = BASICExecutionControl()
        let pauseAtYield = BASICBreakpointLocation(lineNumber: 4, statementNumber: 0)
        control.setBreakpoints([BASICBreakpoint(location: pauseAtYield)])

        session.program.loadSource("""
        on resize call ResizeChanged
        on mouse up call MouseUp
        print "ready"
        yield
        print "done"

        function ResizeChanged(event as variant)
            print "resize=" + str$(int(event("width"))) + "x" + str$(int(event("height")))
        end function

        function MouseUp(event as variant)
            print "mouse=" + str$(int(event("button"))) + "," + str$(int(event("x"))) + "," + str$(int(event("y"))) + "," + str$(int(event("buttons"))) + "," + event("hitId") + "," + event("target")
        end function
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint before event drain")
        } catch BASICError.breakpoint(let location) {
            #expect(location == pauseAtYield)
        }

        session.postResizeEvent(width: 80, height: 24)
        session.postMouseEvent(subtype: "up", x: 12, y: 34, button: 1, buttons: 0, duration: 0.25, hitID: "ok-button", target: "submit")

        control.ignoreBreakpointOnce(at: pauseAtYield)
        try session.continueProgram(executionControl: control)

        #expect(host.output == [
            "ready",
            "resize= 80x 24",
            "mouse= 1, 12, 34, 0,ok-button,submit",
            "done"
        ])
    }

    @Test("Mouse type-only handler receives subtype events")
    func mouseTypeOnlyHandlerReceivesSubtypeEvents() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        let control = BASICExecutionControl()
        let pauseAtYield = BASICBreakpointLocation(lineNumber: 3, statementNumber: 0)
        control.setBreakpoints([BASICBreakpoint(location: pauseAtYield)])

        session.program.loadSource("""
        on mouse call AnyMouse
        print "ready"
        yield
        print "done"

        function AnyMouse(event as variant)
            print event("type") + ":" + event("subtype") + ":" + str$(int(event("button")))
        end function
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint before event drain")
        } catch BASICError.breakpoint(let location) {
            #expect(location == pauseAtYield)
        }

        session.postMouseEvent(subtype: "move", x: 5, y: 6, button: 0, buttons: 0, duration: 0)

        control.ignoreBreakpointOnce(at: pauseAtYield)
        try session.continueProgram(executionControl: control)

        #expect(host.output == [
            "ready",
            "MOUSE:MOVE: 0",
            "done"
        ])
    }

    @Test("Host events can dispatch typed BASIC event objects")
    func hostEventsCanDispatchTypedBASICEventObjects() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        let control = BASICExecutionControl()
        let pauseAtYield = BASICBreakpointLocation(lineNumber: 4, statementNumber: 0)
        control.setBreakpoints([BASICBreakpoint(location: pauseAtYield)])

        session.program.loadSource("""
        on resize call ResizeChanged
        on mouse up call MouseUp
        print "ready"
        yield
        print "done"

        function ResizeChanged(event as BASICResizeEvent)
            print event.Type + ":" + str$(event.Width) + "x" + str$(event.Height)
        end function

        function MouseUp(event as BASICMouseEvent)
            print event.Type + ":" + event.Subtype + ":" + str$(event.Button) + "," + str$(event.X) + "," + str$(event.Y) + "," + str$(event.Buttons) + "," + event.HitId + "," + event.Target
        end function
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint before event drain")
        } catch BASICError.breakpoint(let location) {
            #expect(location == pauseAtYield)
        }

        session.postResizeEvent(width: 1024, height: 768)
        session.postMouseEvent(subtype: "up", x: 22, y: 33, button: 2, buttons: 0, duration: 0.5, hitID: "menu-file", target: "FileMenu")

        control.ignoreBreakpointOnce(at: pauseAtYield)
        try session.continueProgram(executionControl: control)

        #expect(host.output == [
            "ready",
            "RESIZE: 1024x 768",
            "MOUSE:UP: 2, 22, 33, 0,menu-file,FileMenu",
            "done"
        ])
    }

    @Test("Gamepad events can dispatch typed BASIC gamepad objects")
    func gamepadEventsCanDispatchTypedBASICGamepadObjects() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        let control = BASICExecutionControl()
        let pauseAtYield = BASICBreakpointLocation(lineNumber: 3, statementNumber: 0)
        control.setBreakpoints([BASICBreakpoint(location: pauseAtYield)])

        session.program.loadSource("""
        on gamepad button call GamepadButton
        print "ready"
        yield
        print "done"

        function GamepadButton(event as BASICGamepadEvent)
            print event.Type + ":" + event.Subtype + ":" + str$(event.Controller) + ":" + event.Control + ":" + str$(event.Value)
        end function
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint before event drain")
        } catch BASICError.breakpoint(let location) {
            #expect(location == pauseAtYield)
        }

        session.postGamepadEvent(subtype: "button", controller: 2, control: "A", value: 1)

        control.ignoreBreakpointOnce(at: pauseAtYield)
        try session.continueProgram(executionControl: control)

        #expect(host.output == [
            "ready",
            "GAMEPAD:BUTTON: 2:A: 1",
            "done"
        ])
    }

    @Test("OPTION MOUSE OFF suppresses host mouse events")
    func optionMouseOffSuppressesHostMouseEvents() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        let control = BASICExecutionControl()
        let pauseAtYield = BASICBreakpointLocation(lineNumber: 4, statementNumber: 0)
        control.setBreakpoints([BASICBreakpoint(location: pauseAtYield)])

        session.program.loadSource("""
        option mouse off
        on mouse up call MouseUp
        print "ready"
        yield
        print "done"

        function MouseUp(event as BASICMouseEvent)
            print "MOUSE:" + event.Subtype
        end function
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint before event drain")
        } catch BASICError.breakpoint(let location) {
            #expect(location == pauseAtYield)
        }

        #expect(session.acceptsHostInputEvent(type: "MOUSE", subtype: "UP") == false)
        session.postMouseEvent(subtype: "up", x: 1, y: 2, button: 0, buttons: 0, duration: 0)

        control.ignoreBreakpointOnce(at: pauseAtYield)
        try session.continueProgram(executionControl: control)

        #expect(host.output == [
            "ready",
            "done"
        ])
    }

    @Test("OPTION MOUSE AUTO re-enables registered host mouse events")
    func optionMouseAutoReenablesRegisteredHostMouseEvents() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        let control = BASICExecutionControl()
        let pauseAtYield = BASICBreakpointLocation(lineNumber: 5, statementNumber: 0)
        control.setBreakpoints([BASICBreakpoint(location: pauseAtYield)])

        session.program.loadSource("""
        option mouse off
        option mouse auto
        on mouse up call MouseUp
        print "ready"
        yield
        print "done"

        function MouseUp(event as BASICMouseEvent)
            print "MOUSE:" + event.Subtype + ":" + str$(event.X)
        end function
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint before event drain")
        } catch BASICError.breakpoint(let location) {
            #expect(location == pauseAtYield)
        }

        #expect(session.acceptsHostInputEvent(type: "MOUSE", subtype: "UP") == true)
        session.postMouseEvent(subtype: "up", x: 7, y: 8, button: 0, buttons: 0, duration: 0)

        control.ignoreBreakpointOnce(at: pauseAtYield)
        try session.continueProgram(executionControl: control)

        #expect(host.output == [
            "ready",
            "MOUSE:UP: 7",
            "done"
        ])
    }

    @Test("OPTION GAMEPAD OFF suppresses host gamepad events")
    func optionGamepadOffSuppressesHostGamepadEvents() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        let control = BASICExecutionControl()
        let pauseAtYield = BASICBreakpointLocation(lineNumber: 4, statementNumber: 0)
        control.setBreakpoints([BASICBreakpoint(location: pauseAtYield)])

        session.program.loadSource("""
        option gamepad off
        on gamepad button call GamepadButton
        print "ready"
        yield
        print "done"

        function GamepadButton(event as BASICGamepadEvent)
            print "GAMEPAD:" + event.Control
        end function
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint before event drain")
        } catch BASICError.breakpoint(let location) {
            #expect(location == pauseAtYield)
        }

        #expect(session.acceptsHostInputEvent(type: "GAMEPAD", subtype: "BUTTON") == false)
        session.postGamepadEvent(subtype: "button", controller: 1, control: "A", value: 1)

        control.ignoreBreakpointOnce(at: pauseAtYield)
        try session.continueProgram(executionControl: control)

        #expect(host.output == [
            "ready",
            "done"
        ])
    }

    @Test("Frame events can dispatch variant and typed BASIC frame objects")
    func frameEventsCanDispatchVariantAndTypedBASICFrameObjects() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        let control = BASICExecutionControl()
        let pauseAtYield = BASICBreakpointLocation(lineNumber: 4, statementNumber: 0)
        control.setBreakpoints([BASICBreakpoint(location: pauseAtYield)])

        session.program.loadSource("""
        on frame started call FrameStarted
        on frame rejected call FrameRejected
        print "ready"
        yield
        print "done"

        function FrameStarted(event as BASICFrameEvent)
            print event.Type + ":" + event.Subtype + ":" + event.FrameID + ":" + event.FrameType + ":" + str$(event.Timeout) + ":" + event.Target
        end function

        function FrameRejected(event as variant)
            print event("type") + ":" + event("subtype") + ":" + event("frameID") + ":" + event("reason")
        end function
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint before event drain")
        } catch BASICError.breakpoint(let location) {
            #expect(location == pauseAtYield)
        }

        session.postFrameEvent(subtype: "started", frameID: "frame-a", frameType: "frameStarted", timeoutMilliseconds: 250, rawResponse: "raw-start")
        session.postFrameEvent(subtype: "rejected", frameID: "frame-b", frameType: "frameRejected", reason: "busy", rawResponse: "raw-reject")

        control.ignoreBreakpointOnce(at: pauseAtYield)
        try session.continueProgram(executionControl: control)

        #expect(host.output == [
            "ready",
            "FRAME:STARTED:frame-a:frameStarted: 250:frame-a",
            "FRAME:REJECTED:frame-b:busy",
            "done"
        ])
    }

    @Test("Route and network events can dispatch typed BASIC objects")
    func routeAndNetworkEventsCanDispatchTypedBASICObjects() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        let control = BASICExecutionControl()
        let pauseAtYield = BASICBreakpointLocation(lineNumber: 4, statementNumber: 0)
        control.setBreakpoints([BASICBreakpoint(location: pauseAtYield)])

        session.program.loadSource("""
        on route request call RouteRequest
        on network completed call NetworkCompleted
        print "ready"
        yield
        print "done"

        function RouteRequest(event as BASICRouteEvent)
            print event.Type + ":" + event.Subtype + ":" + event.Method + ":" + event.Path + ":" + event.Route + ":" + event.Target + ":" + str$(event.Status)
        end function

        function NetworkCompleted(event as BASICNetworkEvent)
            print event.Type + ":" + event.Subtype + ":" + event.Operation + ":" + event.Url + ":" + str$(event.Status) + ":" + str$(event.Bytes) + ":" + event.RequestID
        end function
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint before event drain")
        } catch BASICError.breakpoint(let location) {
            #expect(location == pauseAtYield)
        }

        session.postRouteEvent(
            subtype: "request",
            requestID: "req-1",
            method: "get",
            path: "/parts/42",
            route: "/parts/:id",
            query: "verbose=true",
            status: 200
        )
        session.postNetworkEvent(
            subtype: "completed",
            operation: "GET",
            url: "https://example.test/parts/42",
            status: 200,
            bytes: 512,
            requestID: "req-1"
        )

        control.ignoreBreakpointOnce(at: pauseAtYield)
        try session.continueProgram(executionControl: control)

        #expect(host.output == [
            "ready",
            "ROUTE:REQUEST:GET:/parts/42:/parts/:id:/parts/:id: 200",
            "NETWORK:COMPLETED:GET:https://example.test/parts/42: 200: 512:req-1",
            "done"
        ])
    }

    @Test("Event base class handlers receive typed subtype objects")
    func eventBaseClassHandlersReceiveTypedSubtypeObjects() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        let control = BASICExecutionControl()
        let pauseAtYield = BASICBreakpointLocation(lineNumber: 8, statementNumber: 0)
        control.setBreakpoints([BASICBreakpoint(location: pauseAtYield)])

        session.program.loadSource("""
        on resize call AnyEvent
        on mouse up call AnyEvent
        on gamepad button call AnyEvent
        on frame committed call AnyEvent
        on route request call AnyEvent
        on network failed call AnyEvent
        print "ready"
        yield
        print "done"

        function AnyEvent(event as BASICEvent)
            print event.Type + ":" + event.Subtype
        end function
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint before event drain")
        } catch BASICError.breakpoint(let location) {
            #expect(location == pauseAtYield)
        }

        session.postResizeEvent(width: 640, height: 480)
        session.postMouseEvent(subtype: "up", x: 4, y: 5, button: 1, buttons: 0, duration: 0)
        session.postGamepadEvent(subtype: "button", controller: 1, control: "B", value: 1)
        session.postFrameEvent(subtype: "committed", frameID: "frame-c", frameType: "frameCommitted")
        session.postRouteEvent(subtype: "request", requestID: "req-2", method: "POST", path: "/jobs", route: "/jobs")
        session.postNetworkEvent(subtype: "failed", operation: "POST", url: "https://example.test/jobs", error: "timeout", requestID: "req-2")

        control.ignoreBreakpointOnce(at: pauseAtYield)
        try session.continueProgram(executionControl: control)

        #expect(host.output == [
            "ready",
            "RESIZE:",
            "MOUSE:UP",
            "GAMEPAD:BUTTON",
            "FRAME:COMMITTED",
            "ROUTE:REQUEST",
            "NETWORK:FAILED",
            "done"
        ])
    }

    @Test("Typed event handlers reject incompatible event objects")
    func typedEventHandlersRejectIncompatibleEventObjects() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        let control = BASICExecutionControl()
        let pauseAtYield = BASICBreakpointLocation(lineNumber: 3, statementNumber: 0)
        control.setBreakpoints([BASICBreakpoint(location: pauseAtYield)])

        session.program.loadSource("""
        on resize call MouseOnly
        print "ready"
        yield
        print "done"

        function MouseOnly(event as BASICMouseEvent)
            print event.X
        end function
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint before event drain")
        } catch BASICError.breakpoint(let location) {
            #expect(location == pauseAtYield)
        }

        session.postResizeEvent(width: 640, height: 480)

        control.ignoreBreakpointOnce(at: pauseAtYield)
        try session.continueProgram(executionControl: control)

        #expect(host.output == [
            "ready",
            "Runtime error: Type Mismatch",
            "done"
        ])
    }

    @Test("Typed event demo starts and exits under mock host")
    func typedEventDemoStartsAndExitsUnderMockHost() throws {
        let host = TestHost()
        host.keys = ["Q"]
        let session = BASICSession(host: host)
        session.program.loadSource(
            try sharedDemoSource(named: "typed-events.bas"),
            fileName: "basicPrograms/demos/typed-events.bas"
        )

        try session.runProgram()

        #expect(host.output == [
            "TYPED EVENT TEST",
            "Resize, mouse down/up, scroll, or press F to print typed event payloads.",
            "Press Q to exit.",
            "Typed event test done."
        ])
    }

    @Test("Event dashboard demo parses with gamepad handlers")
    func eventDashboardDemoParsesWithGamepadHandlers() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource(
            try sharedDemoSource(named: "event-dashboard.bas"),
            fileName: "basicPrograms/demos/event-dashboard.bas"
        )

        #expect(session.diagnostics().isEmpty)
    }

    @Test("Mouse scroll events expose variant and typed delta fields")
    func mouseScrollEventsExposeVariantAndTypedDeltaFields() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        let control = BASICExecutionControl()
        let pauseAtYield = BASICBreakpointLocation(lineNumber: 4, statementNumber: 0)
        control.setBreakpoints([BASICBreakpoint(location: pauseAtYield)])

        session.program.loadSource("""
        on mouse scroll call MouseScroll
        on mouse down call MouseDown
        print "ready"
        yield
        print "done"

        function MouseScroll(event as BASICMouseEvent)
            print event.Type + ":" + event.Subtype + ":" + str$(event.DeltaX) + "," + str$(event.DeltaY)
        end function

        function MouseDown(event as variant)
            print event("subtype") + ":" + str$(int(event("deltaX"))) + "," + str$(int(event("deltaY")))
        end function
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint before event drain")
        } catch BASICError.breakpoint(let location) {
            #expect(location == pauseAtYield)
        }

        session.postMouseEvent(subtype: "scroll", x: 40, y: 41, button: 0, buttons: 0, duration: 0, deltaX: 2, deltaY: -3)
        session.postMouseEvent(subtype: "down", x: 10, y: 11, button: 1, buttons: 1, duration: 0)

        control.ignoreBreakpointOnce(at: pauseAtYield)
        try session.continueProgram(executionControl: control)

        #expect(host.output == [
            "ready",
            "MOUSE:SCROLL: 2,-3",
            "DOWN: 0, 0",
            "done"
        ])
    }

    @Test("SecondsTimer handlers can receive typed timer events")
    func secondsTimerHandlersCanReceiveTypedTimerEvents() throws {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        global done as boolean = false
        let timer = SecondsTimer(0.01)
        timer.repeating = false
        on timer gosub TimerTick
        timer.start()
        MainLoop:
            if done then Finished
            yield
            goto MainLoop

        function TimerTick(event as BASICTimerEvent)
            print event.Type + ":" + str$(event.TimerID) + ":" + str$(event.Sequence) + ":" + str$(event.Interval)
            done = true
        end function

        Finished:
            print "done"
            end
        """)

        try session.runProgram()

        #expect(host.output == [
            "TIMER: 1: 1: 10",
            "done"
        ])
    }

    @Test("DATE$ and TIME$ return BASIC clock strings")
    func dateAndTimeReturnClockStrings() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("print len(date$()); \",\"; len(time$())")

        #expect(host.output == ["10,8"])
    }

    @Test("ON ERROR GOTO traps runtime errors and RESUME NEXT continues")
    func onErrorGotoTrapsRuntimeErrorsAndResumeNextContinues() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        on error goto Handler
        print 10 / 0
        print "after"
        end
        Handler:
            print "ERR", ERR
            print "ERL", ERL
            resume next
        """)
        session.submit("RUN")

        #expect(host.output == [
            "ERR           11",
            "ERL           2",
            "after"
        ])
    }

    @Test("ERROR statement sets ERR and ERL in handler")
    func errorStatementSetsErrAndErlInHandler() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        on error goto Handler
        error 42
        end
        Handler:
            print "ERR", ERR
            print "ERL", ERL
            end
        """)
        session.submit("RUN")

        #expect(host.output == [
            "ERR           42",
            "ERL           2"
        ])
    }

    @Test("ON ERROR GOTO zero disables runtime error trapping")
    func onErrorGotoZeroDisablesRuntimeErrorTrapping() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        on error goto Handler
        on error goto 0
        print 10 / 0
        Handler:
            print "handled"
        """)
        session.submit("RUN")

        #expect(host.output == ["Runtime error: Division by zero"])
    }

    @Test("ERR and ERL remain visible after unhandled runtime errors")
    func errAndErlRemainVisibleAfterUnhandledRuntimeErrors() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "before"
        print 10 / 0
        print "after"
        """)
        session.submit("RUN")
        session.submit("?ERR")
        session.submit("?ERL")

        #expect(host.output == [
            "before",
            "Runtime error: Division by zero",
            "11",
            "2"
        ])
    }

    @Test("Breakpoint in ON ERROR handler stops after trapped runtime error")
    func breakpointInOnErrorHandlerStopsAfterTrappedRuntimeError() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 5, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        on error goto Handler
        print 10 / 0
        print "after"
        end
        Handler:
            print "handled"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint in error handler")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 5, statementNumber: 0))
        }

        #expect(host.output.isEmpty)
    }

    @Test("ON GOSUB selects one based target and returns")
    func onGosubSelectsOneBasedTargetAndReturns() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        choice = 2
        on choice gosub First, Second, Third
        print "back"
        end
        First:
        print "first"
        return
        Second:
        print "second"
        return
        Third:
        print "third"
        return
        """)
        session.submit("RUN")

        #expect(host.output == ["second", "back"])
    }

    @Test("PAUSE prompts and continues")
    func pausePromptsAndContinues() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "before"
        pause
        print "after"
        """)
        session.submit("RUN")

        #expect(host.output == ["before", "PAUSE", "after"])
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

    @Test("Standalone function calls execute and discard return values")
    func standaloneFunctionCallsExecuteAndDiscardReturnValues() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        SayIt("hello")
        Add(2, 3)
        print "done"
        end

        function SayIt(message as string)
            print message
        end function

        function Add(a as integer, b as integer) as integer
            print a + b
            return a + b
        end function
        """)
        session.submit("RUN")

        #expect(host.output == ["hello", "5", "done"])
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

    @Test("LOG renders print lists when enabled and is ignored when disabled")
    func logStatementUsesLoggingHost() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("LOG INFO, \"x=\"; 5, \"done\";")

        #expect(host.logs.count == 1)
        #expect(host.logs.first?.level == "INFO")
        #expect(host.logs.first?.issuer == "U")
        #expect(host.logs.first?.module == "Immediate")
        #expect(host.logs.first?.text == "x=5           done")
        #expect(host.output.isEmpty)

        host.isBASICLoggingEnabled = false
        session.submit("LOG WARN, \"ignored\"; system$(\"printf nope\")")

        #expect(host.logs.count == 1)
        #expect(host.systemCommands.isEmpty)
    }

    @Test("MODULE overrides the BASIC log module")
    func moduleStatementOverridesLogModule() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        module "Checkout"
        log target, "enter menu"
        """, fileName: "pos.bas")
        session.submit("run")

        #expect(host.logs.count == 1)
        #expect(host.logs.first?.level == "target")
        #expect(host.logs.first?.module == "Checkout")
    }

    @Test("LOG defaults module to source file name")
    func logDefaultsModuleToSourceFile() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        log debug, "from file"
        """, fileName: "/tmp/poslib/mainmenu.bas")
        session.submit("run")

        #expect(host.logs.count == 1)
        #expect(host.logs.first?.module == "mainmenu.bas")
    }

    @Test("LINE INPUT reads a full string")
    func lineInputReadsFullString() {
        let host = TestHost()
        host.input = ["Ada, Grace, Katherine"]
        let session = BASICSession(host: host)

        session.program.loadSource("""
        line input "Names: "; names$
        print names$
        """)
        session.submit("RUN")

        #expect(host.output == ["Ada, Grace, Katherine"])
    }

    @Test("LINE INPUT can assign record fields")
    func lineInputAssignsRecordFields() {
        let host = TestHost()
        host.input = ["Ada Lovelace"]
        let session = BASICSession(host: host)

        session.program.loadSource("""
        type Person
            Name as string
        end type
        dim p as Person
        line input p.Name
        print p.Name
        """)
        session.submit("RUN")

        #expect(host.output == ["Ada Lovelace"])
    }

    @Test("LINE INPUT EXITVAR returns special key and keeps typed text")
    func lineInputExitVarReturnsSpecialKey() {
        let host = TestHost()
        host.lineInputResults = [BASICLineInputResult(text: "Ada", exitKey: "[P")]
        let session = BASICSession(host: host)

        session.program.loadSource("""
        line input "Name: "; name$ exitvar key$
        print name$
        print key$
        """)
        session.submit("RUN")

        #expect(host.output == ["Ada", "[P"])
    }

    @Test("LINE INPUT EXITVAR clears exit variable on normal enter")
    func lineInputExitVarClearsOnNormalEnter() {
        let host = TestHost()
        host.lineInputResults = [BASICLineInputResult(text: "Ada")]
        let session = BASICSession(host: host)

        session.program.loadSource("""
        key$ = "OLD"
        line input name$ exitvar key$
        print name$
        print key$
        """)
        session.submit("RUN")

        #expect(host.output == ["Ada", ""])
    }

    @Test("LINE INPUT EXITVAR can assign record fields")
    func lineInputExitVarAssignsRecordFields() {
        let host = TestHost()
        host.lineInputResults = [BASICLineInputResult(text: "Ada", exitKey: "[F1]")]
        let session = BASICSession(host: host)

        session.program.loadSource("""
        type Person
            Name as string
            ExitKey as string
        end type
        dim p as Person
        line input p.Name exitvar p.ExitKey
        print p.Name
        print p.ExitKey
        """)
        session.submit("RUN")

        #expect(host.output == ["Ada", "[F1]"])
    }

    @Test("LINE INPUT LENGTH and MAX pass field options to host")
    func lineInputLengthAndMaxPassOptions() {
        let host = TestHost()
        host.lineInputResults = [BASICLineInputResult(text: "Ada Lovelace")]
        let session = BASICSession(host: host)

        session.program.loadSource("""
        line input "Name: "; name$ length 8 max 20
        print name$
        """)
        session.submit("RUN")

        #expect(host.output == ["Ada Lovelace"])
        #expect(host.lineInputOptions == [BASICLineInputOptions(fieldLength: 8, maxLength: 20)])
    }

    @Test("LINE INPUT MAX truncates host result")
    func lineInputMaxTruncatesResult() {
        let host = TestHost()
        host.lineInputResults = [BASICLineInputResult(text: "Ada Lovelace")]
        let session = BASICSession(host: host)

        session.program.loadSource("""
        line input name$ max 3
        print name$
        """)
        session.submit("RUN")

        #expect(host.output == ["Ada"])
    }

    @Test("LINE INPUT options can appear around EXITVAR")
    func lineInputOptionsCanAppearAroundExitVar() {
        let host = TestHost()
        host.lineInputResults = [BASICLineInputResult(text: "Ada", exitKey: "[P]")]
        let session = BASICSession(host: host)

        session.program.loadSource("""
        line input name$ length 5 exitvar key$ max 10
        print name$
        print key$
        """)
        session.submit("RUN")

        #expect(host.output == ["Ada", "[P]"])
        #expect(host.lineInputOptions == [BASICLineInputOptions(fieldLength: 5, maxLength: 10)])
    }

    @Test("LINE INPUT DEFAULT passes prefilled text to host")
    func lineInputDefaultPassesPrefilledTextToHost() {
        let host = TestHost()
        host.lineInputResults = [BASICLineInputResult(text: "COFFEE-002")]
        let session = BASICSession(host: host)

        session.program.loadSource("""
        line input sku$ length 12 default "COFFEE-001" exitvar key$
        print sku$
        print key$
        """)
        session.submit("RUN")

        #expect(host.output == ["COFFEE-002", ""])
        #expect(host.lineInputOptions == [BASICLineInputOptions(fieldLength: 12, defaultText: "COFFEE-001")])
    }

    @Test("INPUT supports prompts and record fields")
    func inputSupportsPromptsAndRecordFields() {
        let host = TestHost()
        host.input = ["Ada Market", "0.075", "true"]
        let session = BASICSession(host: host)

        session.program.loadSource("""
        type Store
            Name as string
            Tax as double
            Enabled as boolean
        end type
        let store as Store
        input "Name: ", store.Name
        input "Tax rate: ", store.Tax
        input "Enabled: ", store.Enabled
        print store.Name
        print store.Tax
        print store.Enabled
        """)
        session.submit("RUN")

        #expect(host.output == ["Ada Market", "0.075", "TRUE"])
    }

    @Test("INPUT# uses record field types")
    func inputFileUsesRecordFieldTypes() {
        let host = TestHost()
        host.files["stores.txt"] = "Ada Market,0.075,true\n"
        let session = BASICSession(host: host)

        session.program.loadSource("""
        type Store
            Name as string
            Tax as double
            Enabled as boolean
        end type
        let store as Store
        open "stores.txt" for input as #1
        input #1, store.Name, store.Tax, store.Enabled
        close #1
        print store.Name
        print store.Tax
        print store.Enabled
        """)
        session.submit("RUN")

        #expect(host.output == ["Ada Market", "0.075", "TRUE"])
    }

    @Test("INKEY$ reads pending key without blocking")
    func inkeyReadsPendingKeyWithoutBlocking() {
        let host = TestHost()
        host.keys = ["A", "B"]
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print inkey$()
        print inkey$
        print inkey$()
        """)
        session.submit("RUN")

        #expect(host.output == ["A", "B", ""])
    }

    @Test("INKEY$ empty result can branch to a label inside a method")
    func inkeyEmptyCanBranchToLabelInsideMethod() {
        let host = TestHost()
        host.keys = ["", "\r"]
        let session = BASICSession(host: host)

        session.program.loadSource("""
        class KeyMenu
            function Choose() as integer
                let key$ = ""
        WaitForKey:
                key$ = inkey$
                if key$ = "" then WaitForKey
                return 7
            end function
        end class

        let menu as KeyMenu
        menu = new KeyMenu()
        print menu.Choose()
        """, fileName: "mainmenu.bas")
        session.submit("RUN")

        #expect(host.output == ["7"])
    }

    @Test("INKEY$ normalizes special keys in default AIBasic mode")
    func inkeyNormalizesSpecialKeysInAIBasicMode() {
        let host = TestHost()
        host.keys = ["\u{1B}[D", "\u{1B}OP", "\u{1B}[1;2D", "\u{1B}[1;3P", "\u{1B}[25;10~", "\u{1B}[#s", "\u{1B}[Z", "[GP:A", "\t", "\u{8}", "\u{11}"]
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print inkey$()
        print inkey$()
        print inkey$()
        print inkey$()
        print inkey$()
        print inkey$()
        print inkey$()
        print inkey$()
        print asc(inkey$())
        print asc(inkey$())
        print asc(inkey$())
        """)
        session.submit("RUN")

        #expect(host.output == ["[K", "[F1", "[!K", "[#F1", "[!$F13", "[#s", "[!T", "[GP:A", "9", "8", "17"])
    }

    @Test("OPTION IBM-KEYS makes INKEY$ return GW-BASIC extended keys")
    func optionIBMKeysMakesInkeyReturnGWBasicExtendedKeys() {
        let host = TestHost()
        host.keys = ["\u{1B}[D", "\u{1B}OP"]
        let session = BASICSession(host: host)

        session.program.loadSource("""
        option ibm-keys
        k$ = inkey$()
        print len(k$)
        print asc(mid$(k$, 2, 1))
        k$ = inkey$()
        print len(k$)
        print asc(mid$(k$, 2, 1))
        """)
        session.submit("RUN")

        #expect(host.output == ["2", "75", "2", "59"])
    }

    @Test("POS reports the current print column")
    func posReportsCurrentPrintColumn() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "ABC";
        col = pos(0)
        print
        print col
        print "AB";
        print tab(5);"C"
        """)
        session.submit("RUN")

        #expect(host.output == ["ABC", "4", "AB  C"])
    }

    @Test("HEX$ formats non-negative integers")
    func hexFormatsNonNegativeIntegers() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print hex$(0)
        print hex$(15)
        print hex$(255)
        print hex$(4095)
        """)
        session.submit("RUN")

        #expect(host.output == ["0", "F", "FF", "FFF"])
    }

    @Test("HEX$ rejects negative values")
    func hexRejectsNegativeValues() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("print hex$(-1)")

        #expect(host.output == ["Runtime error: HEX$ requires a non-negative value"])
    }

    @Test("BINARY$ formats non-negative integers")
    func binaryFormatsNonNegativeIntegers() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print binary$(0)
        print binary$(5)
        print binary$(255)
        """)
        session.submit("RUN")

        #expect(host.output == ["0", "101", "11111111"])
    }

    @Test("BINARY$ rejects negative values")
    func binaryRejectsNegativeValues() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("print binary$(-1)")

        #expect(host.output == ["Runtime error: BINARY$ requires a non-negative value"])
    }

    @Test("PRINT USING and USING$ format numbers and strings")
    func printUsingAndUsingFunctionFormatValues() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print using "TOTAL ###.##"; 12.3
        print using "$#,###.##"; 1234.5
        print using "NAME ! &"; "Ada", "Lovelace"
        print using "## "; 1, 2, 3
        print using "##"; 123
        print using$("###.#", 4.25)
        """)
        session.submit("run")

        #expect(host.output == [
            "TOTAL  12.30",
            "$1,234.50",
            "NAME A Lovelace",
            " 1  2  3 ",
            "%%",
            "  4.3"
        ])
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

    @Test("IBM BASIC 1970 math aliases")
    func ibmBasic1970MathAliases() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print ACS(1),ASN(0),COT(0.7853981633974483)
        print CSC(1.5707963267948966),SEC(0),SCN(-2)
        print DEC(3.141592653589793),RAD(180)
        print HCS(0),HSN(0),HTN(0)
        print LCT(100),LOC(1),LTW(8)
        """)
        session.submit("RUN")

        #expect(host.output == [
            "0             0             1.0000000000000002",
            "1             1             -1",
            "180           3.141592653589793",
            "1             0             0",
            "2             0             3"
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

        let paintHost = TextOnlyHost()
        let paintSession = BASICSession(host: paintHost)
        paintSession.submit("paint (1,1), 2")

        #expect(paintHost.output == ["Unsupported feature: you must run this program in BASICStudio"])

        let drawHost = TextOnlyHost()
        let drawSession = BASICSession(host: drawHost)
        drawSession.submit("draw \"R10\"")

        #expect(drawHost.output == ["Unsupported feature: you must run this program in BASICStudio"])
    }

    @Test("Shared graphics demos run against mock Studio graphics host")
    func sharedGraphicsDemosRunAgainstMockStudioGraphicsHost() throws {
        let demoNames = [
            "simple-graphics.bas",
            "graphics-box.bas",
            "diagonal-lines.bas",
            "basic-graphics-command-test.bas",
            "graphics-primitives.bas"
        ]

        for demoName in demoNames {
            let host = TestHost()
            host.columns = 120
            host.rows = 40
            host.keys = ["x"]
            let session = BASICSession(host: host)
            session.program.loadSource(
                try sharedDemoSource(named: demoName),
                fileName: "basicPrograms/demos/\(demoName)"
            )

            try session.runProgram()

            let graphicsOperationCount = host.lines.count
                + host.circles.count
                + host.fills.count
                + host.pixels.count
                + host.fullLines.count
                + host.fullCircles.count
                + host.fullFills.count
                + host.fullPixels.count
            #expect(host.screenMode?.number == 1, "Expected \(demoName) to select graphics mode")
            #expect(graphicsOperationCount > 0, "Expected \(demoName) to emit graphics operations")
            #expect(!host.output.contains { $0.hasPrefix("Runtime error:") }, "Expected \(demoName) to run without runtime errors")
        }
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

    @Test("Question mark PRINT alias is direct mode only")
    func questionMarkPrintAliasIsDirectModeOnly() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("10 ? \"NOPE\"")
        session.submit("RUN")

        #expect(host.output == ["? \"NOPE\"\n^\nSyntax error: Unexpected character ?"])
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

    @Test("LIST preserves source whitespace")
    func listPreservesSourceWhitespace() {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource("""
        class Sample
            public Name as string

            function Title() as string
                return Name
            end function
        end class
        """)

        session.submit("LIST")

        #expect(host.output == ["""
        class Sample
            public Name as string
            function Title() as string
                return Name
            end function
        end class
        """])
    }

    @Test("LIST preserves direct numbered line spacing")
    func listPreservesDirectNumberedLineSpacing() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("10    print \"indented\"")
        session.submit("LIST")

        #expect(host.output == ["10    print \"indented\""])
    }

    @Test("LIST supports ranges")
    func listSupportsRanges() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("10 print 1")
        session.submit("20 print 2")
        session.submit("30 print 3")
        session.submit("LIST 20-")
        session.submit("LIST -20")
        session.submit("LIST 20")

        #expect(host.output == [
            "20 print 2\n30 print 3",
            "10 print 1\n20 print 2",
            "20 print 2"
        ])
    }

    @Test("LIST CHECK reports diagnostics")
    func listCheckReportsDiagnostics() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("10 print \"ok\"")
        session.submit("20 skdjfhs fhkdsfhsdfk")
        session.submit("LIST CHECK")

        #expect(host.output.count == 5)
        #expect(host.output[0] == "10 print \"ok\"\n20 skdjfhs fhkdsfhsdfk")
        #expect(host.output[1] == "Diagnostics:")
        #expect(host.output[2].contains("Line 20, column"))
        #expect(host.output[2].contains("Syntax error: Expected ="))
        #expect(host.output[3] == "20 skdjfhs fhkdsfhsdfk")
        #expect(host.output[4].contains("^"))
    }

    @Test("DELETE removes line ranges")
    func deleteRemovesLineRanges() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("10 print 1")
        session.submit("20 print 2")
        session.submit("30 print 3")
        session.submit("40 print 4")
        session.submit("DELETE 20-30")
        session.submit("LIST")
        session.submit("DEL 10")
        session.submit("LIST")

        #expect(host.output == [
            "10 print 1\n40 print 4",
            "40 print 4"
        ])
    }

    @Test("RENUM renumbers lines and common references")
    func renumRenumbersLinesAndReferences() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("10 print \"goto 30\"")
        session.submit("20 if X then 40 else 50")
        session.submit("30 goto 60")
        session.submit("40 gosub 70")
        session.submit("50 rem goto 10")
        session.submit("60 print \"done\"")
        session.submit("70 return")
        session.submit("RENUM 100,10,5")
        session.submit("LIST")

        #expect(host.output == ["""
        100 print "goto 30"
        105 if X then 115 else 120
        110 goto 125
        115 gosub 130
        120 rem goto 10
        125 print "done"
        130 return
        """])
    }

    @Test("RENUM detects collisions with unrenumbered lines")
    func renumDetectsCollisions() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("10 print 1")
        session.submit("20 print 2")
        session.submit("RENUM 10,20,10")

        #expect(host.output == ["Runtime error: RENUM would collide with existing line 10"])
    }

    @Test("AUTO reads numbered program lines until blank")
    func autoReadsNumberedProgramLines() {
        let host = TestHost()
        host.input = [
            "print \"A\"",
            "35 print \"explicit\"",
            "print \"B\"",
            ""
        ]
        let session = BASICSession(host: host)

        session.submit("AUTO 10,10")
        session.submit("LIST")

        #expect(host.output == ["""
        10 print "A"
        35 print "explicit"
        45 print "B"
        """])
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

    @Test("RUN quoted path loads and runs source")
    func runQuotedPathLoadsAndRunsSource() {
        let host = TestHost()
        host.files["apps/hello.bas"] = """
        print "file run"
        let x = 12
        print x
        """
        let session = BASICSession(host: host)

        session.submit("run \"apps/hello.bas\"")
        session.submit("save")

        #expect(host.output == ["file run", "12"])
        #expect(host.files["apps/hello.bas"] == """
        print "file run"
        let x = 12
        print x
        """)
    }

    @Test("LOAD accepts classic no-space quoted path")
    func loadAcceptsClassicNoSpaceQuotedPath() {
        let host = TestHost()
        host.files["demo.bas"] = """
        print "loaded"
        line input a$
        """
        let session = BASICSession(host: host)

        session.submit("load\"demo.bas\"")
        session.submit("list")

        #expect(host.output == ["print \"loaded\"\nline input a$"])
    }

    @Test("DEF FN single-expression functions work")
    func defFnSingleExpressionFunctionsWork() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        def FNSquare(x) = x * x
        def FNShout$(word$) = word$ + "!"
        print FNSquare(5)
        print FNShout$("HELLO")
        """)
        session.submit("run")

        #expect(host.output == ["25", "HELLO!"])
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

        #expect(host.output == ["alpha.bas  zeta.bas"])
    }

    @Test("FILES formats names in terminal-width columns")
    func filesFormatsNamesInTerminalWidthColumns() {
        let host = TestHost()
        host.columns = 32
        for name in ["zeta.bas", "gamma.bas", "epsilon.bas", "delta.bas", "beta.bas", "alpha.bas"] {
            host.files[name] = ""
        }
        let session = BASICSession(host: host)

        session.submit("files")

        #expect(host.output == ["alpha.bas    epsilon.bas\nbeta.bas     gamma.bas\ndelta.bas    zeta.bas"])
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

        #expect(host.output == ["loadme.bas  other.bas"])
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

    @Test("SYSTEM command runner receives terminal dimensions")
    func systemCommandRunnerReceivesTerminalDimensions() throws {
        let output = try BASICSystemCommand.run("printf \"$COLUMNS,$LINES\"", columns: 132, rows: 43)

        #expect(output == "132,43")
    }

    @Test("SYSTEM command runner presents a terminal to column-aware tools")
    func systemCommandRunnerPresentsTerminalToColumnAwareTools() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIBasic-system-ls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["alpha", "beta", "gamma"] {
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent(name).path,
                contents: Data()
            )
        }

        let output = try BASICSystemCommand.run("ls", workingDirectory: directory, columns: 80, rows: 24)
        let lines = output.split(whereSeparator: \.isNewline)

        #expect(output.contains("alpha"))
        #expect(output.contains("beta"))
        #expect(output.contains("gamma"))
        #expect(lines.count == 1)
    }

    @Test("SYSTEM command runner supports shell pipes and redirection")
    func systemCommandRunnerSupportsShellPipesAndRedirection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIBasic-system-pipes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let command = "printf alpha | tr a-z A-Z > out.txt; sh -c 'printf err >&2' 2> err.txt; cat out.txt; printf ':'; cat err.txt"
        let output = try BASICSystemCommand.run(command, workingDirectory: directory)

        #expect(output == "ALPHA:err")
        #expect(try String(contentsOf: directory.appendingPathComponent("out.txt"), encoding: .utf8) == "ALPHA")
        #expect(try String(contentsOf: directory.appendingPathComponent("err.txt"), encoding: .utf8) == "err")
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

    @Test("INPUT$ observes break while waiting for keyboard input")
    func inputStringObservesBreakWhileWaitingForKeyboardInput() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        host.breakOnBlockingKeyRead = true
        host.executionControl = control
        let session = BASICSession(host: host)

        session.program.loadSource("""
        10 a$ = input$(1)
        20 print "not reached"
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

    @Test("Logical BASIC task completes after RUN")
    func logicalBasicTaskCompletesAfterRun() throws {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "task"
        end
        """)

        try session.runProgram()

        #expect(host.output == ["task"])
        #expect(session.debugTasks.count == 1)
        #expect(session.debugTasks.first?.name == "Program")
        #expect(session.debugTasks.first?.state == .completed)
        #expect(session.debugTasks.first?.location == BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
    }

    @Test("Logical BASIC task suspends at breakpoint and completes after continue")
    func logicalBasicTaskSuspendsAtBreakpointAndCompletesAfterContinue() throws {
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

        #expect(session.debugTasks.count == 1)
        #expect(session.debugTasks.first?.state == .suspended)
        #expect(session.debugTasks.first?.location == BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))

        control.ignoreBreakpointOnce(at: BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        try session.continueProgram(executionControl: control)

        #expect(host.output == ["before", "break", "after"])
        #expect(session.debugTasks.count == 1)
        #expect(session.debugTasks.first?.state == .completed)
    }

    @Test("Logical BASIC task records failed runtime error")
    func logicalBasicTaskRecordsFailedRuntimeError() throws {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "before"
        print 10 / 0
        print "after"
        """)

        do {
            try session.runProgram()
            Issue.record("Expected division by zero")
        } catch BASICError.runtime(let message) {
            #expect(message == "Division by zero")
        }

        #expect(host.output == ["before"])
        #expect(session.debugTasks.count == 1)
        #expect(session.debugTasks.first?.state == .failed)
        #expect(session.debugTasks.first?.location == BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        #expect(session.debugTasks.first?.errorDescription?.contains("Division by zero") == true)
    }

    @Test("YIELD records cooperative task boundaries")
    func yieldRecordsCooperativeTaskBoundaries() throws {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "before"
        yield
        yield
        print "after"
        """)

        try session.runProgram()

        #expect(host.output == ["before", "after"])
        #expect(session.debugTasks.count == 1)
        #expect(session.debugTasks.first?.state == .completed)
        #expect(session.debugTasks.first?.yieldCount == 2)
    }

    @Test("Logical BASIC task can be cancelled by handle")
    func logicalBasicTaskCanBeCancelledByHandle() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "before"
        yield
        print "after"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        }

        guard let handle = session.currentTaskHandle else {
            Issue.record("Expected current task handle")
            return
        }
        #expect(handle.name == "Program")
        #expect(session.requestTaskCancellation(id: handle.id))

        control.ignoreBreakpointOnce(at: BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        do {
            try session.continueProgram(executionControl: control)
            Issue.record("Expected cancellation break")
        } catch BASICError.breakRequested(let line) {
            #expect(line == 2)
        }

        #expect(host.output == ["before"])
        #expect(session.debugTasks.first?.state == .cancelled)
        #expect(session.debugTasks.first?.isCancellationRequested == true)
    }

    @Test("Logical BASIC task supports child handles and join states")
    func logicalBasicTaskSupportsChildHandlesAndJoinStates() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "parent"
        yield
        print "done"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        }

        guard let parent = session.currentTaskHandle,
              let child = session.createChildTask(name: "Child work") else {
            Issue.record("Expected parent and child handles")
            return
        }

        #expect(child.parentID == parent.id)
        #expect(session.debugTasks.first { $0.id == parent.id }?.childCount == 1)
        #expect(session.taskJoinState(id: child.id) == .waiting)
        #expect(session.taskJoinState(id: 999_999) == .missing)

        #expect(session.requestTaskCancellation(id: child.id))
        #expect(session.taskJoinState(id: child.id) == .cancelled)

        control.ignoreBreakpointOnce(at: BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        try session.continueProgram(executionControl: control)

        #expect(host.output == ["parent", "done"])
        #expect(session.taskJoinState(id: parent.id) == .completed)
    }

    @Test("Logical BASIC task can suspend and resume for host operations")
    func logicalBasicTaskCanSuspendAndResumeForHostOperations() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "parent"
        yield
        print "done"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        }

        guard let child = session.createChildTask(name: "Timer wait") else {
            Issue.record("Expected child handle")
            return
        }

        #expect(session.suspendTaskForHostOperation(id: child.id, operation: "timer"))
        let suspended = session.debugTasks.first { $0.id == child.id }
        #expect(suspended?.state == .suspended)
        #expect(suspended?.suspensionReason == .hostOperation("timer"))
        #expect(session.taskJoinState(id: child.id) == .waiting)
        #expect(!session.readyTaskHandles.contains(child))

        #expect(session.resumeTask(id: child.id))
        let resumed = session.debugTasks.first { $0.id == child.id }
        #expect(resumed?.state == .ready)
        #expect(resumed?.suspensionReason == nil)
        #expect(session.readyTaskHandles.contains(child))

        #expect(session.suspendTaskForHostOperation(id: child.id, operation: "network"))
        #expect(session.requestTaskCancellation(id: child.id))
        #expect(!session.resumeTask(id: child.id))
        #expect(session.taskJoinState(id: child.id) == .cancelled)
    }

    @Test("Logical BASIC task captures suspended await frames")
    func logicalBasicTaskCapturesSuspendedAwaitFrames() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "parent"
        yield
        print "done"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        }

        guard let parent = session.currentTaskHandle,
              let child = session.createChildTask(name: "Async worker") else {
            Issue.record("Expected parent and child handles")
            return
        }

        let frame = BASICSuspendedFrame(
            kind: "Function",
            name: "AsyncCaller",
            resumeLocation: BASICBreakpointLocation(lineNumber: 2, statementNumber: 0),
            localScopeDepth: 1
        )

        #expect(session.suspendTaskForAwait(id: parent.id, awaitingTaskID: child.id, frame: frame))
        let suspended = session.debugTasks.first { $0.id == parent.id }
        #expect(suspended?.state == .suspended)
        #expect(suspended?.suspensionReason == .join(taskID: child.id))
        #expect(suspended?.suspendedFrames == [frame])
        #expect(session.taskAwaitState(id: parent.id) == .waiting)
        #expect(session.debugTasks.first { $0.id == child.id }?.waiterCount == 1)

        #expect(session.resumeTask(id: parent.id))
        let resumed = session.debugTasks.first { $0.id == parent.id }
        #expect(resumed?.state == .ready)
        #expect(resumed?.suspendedFrames.isEmpty == true)
        #expect(session.debugTasks.first { $0.id == child.id }?.waiterCount == 0)
    }

    @Test("Suspended task frames retain local variable snapshots")
    func suspendedTaskFramesRetainLocalVariableSnapshots() throws {
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        ])
        let session = BASICSession(host: TestHost())
        session.program.loadSource("""
        print "parent"
        yield
        print "done"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        }

        guard let parent = session.currentTaskHandle,
              let child = session.createChildTask(name: "Child") else {
            Issue.record("Expected parent and child handles")
            return
        }
        let local = BASICVariableSnapshot(
            path: "Local:count",
            name: "count",
            typeName: "INTEGER",
            value: "30",
            scope: .local,
            children: []
        )
        let frame = BASICSuspendedFrame(
            kind: "Function",
            name: "Worker",
            resumeLocation: BASICBreakpointLocation(lineNumber: 30, statementNumber: 0),
            localScopeDepth: 1,
            localVariables: [local]
        )
        let global = BASICVariableSnapshot(
            path: "Global:total",
            name: "total",
            typeName: "DOUBLE",
            value: "31",
            scope: .global,
            children: []
        )

        #expect(session.suspendTaskForAwait(
            id: parent.id,
            awaitingTaskID: child.id,
            frames: [frame],
            globalVariables: [global]
        ))
        let snapshot = session.debugTasks.first { $0.id == parent.id }
        #expect(snapshot?.suspendedFrames.first?.localVariables == [local])
        #expect(snapshot?.suspendedGlobalVariables == [global])

        _ = session.requestTaskCancellation(id: parent.id)
        _ = session.requestTaskCancellation(id: child.id)
    }

    @Test("Completed awaited task wakes suspended parent")
    func completedAwaitedTaskWakesSuspendedParent() async throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "parent"
        yield
        print "done"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        }

        guard let parent = session.currentTaskHandle else {
            Issue.record("Expected parent handle")
            return
        }

        let release = AsyncTestGate()
        let child = session.startHostOperationTaskWithResult(name: "Async value", parentID: parent.id, operation: "test") {
            await release.wait()
            return .number(42)
        }
        let frame = BASICSuspendedFrame(
            kind: "Function",
            name: "AwaitValue",
            resumeLocation: BASICBreakpointLocation(lineNumber: 2, statementNumber: 0),
            localScopeDepth: 1
        )

        #expect(session.suspendTaskForAwait(id: parent.id, awaitingTaskID: child.id, frame: frame))
        #expect(session.debugTasks.first { $0.id == parent.id }?.state == .suspended)
        #expect(!session.readyTaskHandles.contains(parent))

        await release.open()
        try await waitForTaskState(session, id: child.id, expected: .completed)

        #expect(session.taskAwaitState(id: child.id) == .completed(.number(42)))
        let parentSnapshot = session.debugTasks.first { $0.id == parent.id }
        #expect(parentSnapshot?.state == .ready)
        #expect(parentSnapshot?.suspendedFrames.isEmpty == true)
        #expect(session.readyTaskHandles.contains(parent))
        let childSnapshot = session.debugTasks.first { $0.id == child.id }
        #expect(childSnapshot?.waiterCount == 0)
        #expect(childSnapshot?.resultDescription == "42")
    }

    @Test("Cancelling awaited task wakes suspended parent")
    func cancellingAwaitedTaskWakesSuspendedParent() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        ])
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "parent"
        yield
        print "done"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 2, statementNumber: 0))
        }

        guard let parent = session.currentTaskHandle,
              let child = session.createChildTask(name: "Cancellable child") else {
            Issue.record("Expected parent and child handles")
            return
        }

        let frame = BASICSuspendedFrame(
            kind: "Expression",
            name: "AWAIT",
            resumeLocation: BASICBreakpointLocation(lineNumber: 2, statementNumber: 0),
            localScopeDepth: 0
        )

        #expect(session.suspendTaskForAwait(id: parent.id, awaitingTaskID: child.id, frame: frame))
        #expect(session.debugTasks.first { $0.id == parent.id }?.state == .suspended)
        #expect(session.debugTasks.first { $0.id == child.id }?.waiterCount == 1)

        #expect(session.requestTaskCancellation(id: child.id))

        let parentSnapshot = session.debugTasks.first { $0.id == parent.id }
        #expect(parentSnapshot?.state == .ready)
        #expect(parentSnapshot?.suspendedFrames.isEmpty == true)
        #expect(session.readyTaskHandles.contains(parent))
        #expect(session.debugTasks.first { $0.id == child.id }?.waiterCount == 0)
        #expect(session.taskAwaitState(id: child.id) == .cancelled)
    }

    @Test("Host operation tasks complete on Swift async lanes")
    func hostOperationTasksCompleteOnSwiftAsyncLanes() async throws {
        let session = BASICSession(host: TestHost())
        let log = ThreadSafeStringLog()
        let release = AsyncTestGate()

        let alpha = session.startHostOperationTask(name: "ALPHA", operation: "timer") {
            await release.wait()
            for iterator in 1...3 {
                log.append("ALPHA ITER \(iterator) BEFORE YIELD")
                await Task.yield()
                log.append("ALPHA ITER \(iterator) AFTER YIELD")
            }
        }
        let beta = session.startHostOperationTask(name: "BETA", operation: "timer") {
            await release.wait()
            for iterator in 1...3 {
                log.append("BETA ITER \(iterator) BEFORE YIELD")
                await Task.yield()
                log.append("BETA ITER \(iterator) AFTER YIELD")
            }
        }

        #expect(session.debugTasks.first { $0.id == alpha.id }?.state == .suspended)
        #expect(session.debugTasks.first { $0.id == beta.id }?.suspensionReason == .hostOperation("timer"))

        await release.open()

        try await waitForTaskState(session, id: alpha.id, expected: .completed)
        try await waitForTaskState(session, id: beta.id, expected: .completed)

        let entries = log.snapshot
        #expect(entries.contains("ALPHA ITER 1 BEFORE YIELD"))
        #expect(entries.contains("BETA ITER 1 BEFORE YIELD"))
        #expect(entries.contains("ALPHA ITER 3 AFTER YIELD"))
        #expect(entries.contains("BETA ITER 3 AFTER YIELD"))
        #expect(session.taskJoinState(id: alpha.id) == .completed)
        #expect(session.taskJoinState(id: beta.id) == .completed)
    }

    @Test("Host operation tasks can complete with BASIC result values")
    func hostOperationTasksCanCompleteWithBASICResultValues() async throws {
        let session = BASICSession(host: TestHost())

        let handle = session.startHostOperationTaskWithResult(name: "FETCH", operation: "network") {
            await Task.yield()
            return BASICValue.string(BASICString("payload"))
        }

        #expect(session.taskAwaitState(id: handle.id) == .waiting)
        try await waitForTaskState(session, id: handle.id, expected: .completed)

        let snapshot = session.debugTasks.first { $0.id == handle.id }
        #expect(snapshot?.resultValue == .string(BASICString("payload")))
        #expect(session.taskJoinState(id: handle.id) == .completed)
        #expect(session.taskAwaitState(id: handle.id) == .completed(.string(BASICString("payload"))))
        #expect(session.taskAwaitState(id: 999_999) == .missing)
    }

    @Test("Host operation completions post through the session event loop")
    func hostOperationCompletionsPostThroughSessionEventLoop() async throws {
        let session = BASICSession(host: TestHost())

        let handle = session.startHostOperationTaskWithResult(name: "CALLBACK", operation: "network") {
            BASICValue.string(BASICString("callback"))
        }

        try await waitForEventLoopPending(session, expected: 1)
        #expect(session.eventLoop.pendingCount == 1)
        #expect(session.eventLoop.runUntilIdle() == 1)
        #expect(session.taskAwaitState(id: handle.id) == .completed(.string(BASICString("callback"))))
    }

    @Test("BASIC AWAIT drains host completion callbacks")
    func basicAwaitDrainsHostCompletionCallbacks() throws {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        value$ = await AsyncValue("callback")
        print "VALUE ="; value$
        """)

        try session.runProgram()

        #expect(host.output == ["VALUE =callback"])
        #expect(session.eventLoop.isEmpty)
    }

    @Test("SLEEP creates an awaitable timer host task")
    func sleepCreatesAwaitableTimerHostTask() throws {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "BEFORE SLEEP"
        slept = await Sleep(25)
        print "SLEPT ="; slept
        print "AFTER SLEEP"
        """)

        try session.runProgram()

        #expect(host.output == ["BEFORE SLEEP", "SLEPT =25", "AFTER SLEEP"])
        #expect(session.eventLoop.isEmpty)
    }

    @Test("Host operation tasks report failure and cancellation")
    func hostOperationTasksReportFailureAndCancellation() async throws {
        let session = BASICSession(host: TestHost())

        let failing = session.startHostOperationTask(name: "FAIL", operation: "network") {
            throw BASICError.runtime("Host operation failed")
        }
        try await waitForTaskState(session, id: failing.id, expected: .failed)
        if case .failed(let message) = session.taskJoinState(id: failing.id) {
            #expect(message?.contains("Host operation failed") == true)
        } else {
            Issue.record("Expected failed join state")
        }
        if case .failed(let message) = session.taskAwaitState(id: failing.id) {
            #expect(message?.contains("Host operation failed") == true)
        } else {
            Issue.record("Expected failed await state")
        }

        let cancelled = session.startHostOperationTask(name: "CANCEL", operation: "timer") {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        #expect(session.requestTaskCancellation(id: cancelled.id))
        try await waitForTaskState(session, id: cancelled.id, expected: .cancelled)
        #expect(session.taskJoinState(id: cancelled.id) == .cancelled)
        #expect(session.taskAwaitState(id: cancelled.id) == .cancelled)
    }

    @Test("ASYNC FUNCTION and AWAIT parse and evaluate through current function runtime")
    func asyncFunctionAndAwaitParseAndEvaluate() throws {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "slice 9"
        total = await AddAsync(2, 3)
        print "TOTAL ="; total
        async function AddAsync(a as integer, b as integer) as integer
            return a + b
        end function
        """)

        try session.runProgram()

        #expect(host.output == ["slice 9", "TOTAL =5"])
    }

    @Test("AWAIT can resolve a user-visible host task handle")
    func awaitCanResolveUserVisibleHostTaskHandle() throws {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "slice 12"
        value$ = await AsyncValue("payload")
        print "VALUE ="; value$
        number = await AsyncValue(12)
        print "NUMBER ="; number
        """)

        try session.runProgram()

        #expect(host.output == ["slice 12", "VALUE =payload", "NUMBER =12"])
    }

    @Test("Async file hosts return task values without blocking the BASIC lane")
    func asyncFileHostsReturnTaskValues() throws {
        let host = TestHost()
        host.files["input.txt"] = "alpha"
        let session = BASICSession(host: host)

        session.program.loadSource("""
        global readTask as task = ReadFileAsync("input.txt")
        text$ = await readTask
        global writeTask as task = WriteFileAsync("output.txt", text$ + " beta")
        byteCount = await writeTask
        print text$
        print byteCount
        """)

        try session.runProgram()

        #expect(host.output == ["alpha", "10"])
        #expect(host.files["output.txt"] == "alpha beta")
        #expect(session.debugTasks.contains { $0.name == "READFILEASYNC" && $0.state == .completed })
        #expect(session.debugTasks.contains { $0.name == "WRITEFILEASYNC" && $0.state == .completed })
    }

    @Test("Async HTTP host returns structured response data")
    func asyncHTTPHostReturnsStructuredResponseData() throws {
        let host = TestHost()
        host.httpResponses["https://example.test/data"] = BASICHTTPResponse(
            url: "https://example.test/final",
            statusCode: 200,
            body: "payload",
            headers: ["Content-Type": "text/plain"]
        )
        let session = BASICSession(host: host)

        session.program.loadSource("""
        global request as task = HttpGetAsync("https://example.test/data")
        response = await request
        headers = response("HEADERS")
        print response("STATUS")
        print response("BODY")
        print response("URL")
        print headers("Content-Type")
        """)

        try session.runProgram()

        #expect(host.httpRequests == ["https://example.test/data"])
        #expect(host.output == ["200", "payload", "https://example.test/final", "text/plain"])
        #expect(session.debugTasks.contains { $0.name == "HTTPGETASYNC" && $0.state == .completed })
    }

    @Test("Async HTTP failures surface at AWAIT")
    func asyncHTTPFailuresSurfaceAtAwait() throws {
        let host = TestHost()
        host.httpErrors["https://example.test/fail"] = "network unavailable"
        let session = BASICSession(host: host)
        session.program.loadSource("""
        on error goto Failed
        request = HttpGetAsync("https://example.test/fail")
        response = await request
        print "UNEXPECTED"
        end
        Failed:
            print "ERROR="; ERR
            print "MESSAGE="; taskerror$(request)
        """)

        try session.runProgram()

        #expect(host.output.count == 2)
        #expect(host.output[0].hasPrefix("ERROR="))
        #expect(host.output[1].contains("network unavailable"))
        #expect(session.debugTasks.contains { $0.name == "HTTPGETASYNC" && $0.state == .failed })
    }

    @Test("ASYNC FUNCTION calls produce awaitable task handles")
    func asyncFunctionCallsProduceAwaitableTaskHandles() throws {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "slice 13"
        global handle as task = AsyncAdd(6, 7)
        total = await handle
        print "STATUS ="; taskstatus$(handle)
        print "HANDLE ="; handle
        print "TOTAL ="; total
        async function AsyncAdd(a as integer, b as integer) as integer
            return a + b
        end function
        """)

        try session.runProgram()

        #expect(host.output.count == 4)
        #expect(host.output[0] == "slice 13")
        #expect(host.output[1] == "STATUS =COMPLETED")
        #expect(host.output[2].hasPrefix("HANDLE =<TASK #"))
        #expect(host.output[2].hasSuffix(" AsyncAdd>"))
        #expect(host.output[3] == "TOTAL =13")
        #expect(session.debugTasks.contains { $0.name == "AsyncAdd" })
        #expect(session.debugGlobalVariables.first { $0.name == "handle" }?.typeName == "TASK")
    }

    @Test("TASK declarations reject non-task values")
    func taskDeclarationsRejectNonTaskValues() throws {
        let session = BASICSession(host: TestHost())
        session.program.loadSource("global handle as task = 1")

        do {
            try session.runProgram()
            Issue.record("Expected TASK assignment to reject a numeric value")
        } catch {
            #expect(String(describing: error).contains("Cannot assign non-task value"))
        }
    }

    @Test("Discarded async calls require explicit background intent")
    func discardedAsyncCallsRequireExplicitBackgroundIntent() throws {
        let session = BASICSession(host: TestHost())
        session.program.loadSource("AsyncValue(42)")

        do {
            try session.runProgram()
            Issue.record("Expected a discarded async call to fail")
        } catch {
            #expect(String(describing: error).contains("Task result was ignored"))
        }
    }

    @Test("BACKGROUND explicitly launches fire-and-forget async work")
    func backgroundExplicitlyLaunchesFireAndForgetAsyncWork() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource("background AsyncValue(42)")

        try session.runProgram()

        let task = try #require(session.debugTasks.first { $0.name == "ASYNCVALUE" })
        #expect(task.isBackground)
        #expect(task.isObserved)
        #expect(host.output.isEmpty)
    }

    @Test("Unawaited retained tasks produce an end-of-run diagnostic")
    func unawaitedRetainedTasksProduceEndOfRunDiagnostic() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource("global handle as task = AsyncValue(42)")

        try session.runProgram()

        #expect(host.output.count == 1)
        #expect(host.output[0].contains("Warning: task #"))
        #expect(host.output[0].contains("ASYNCVALUE"))
    }

    @Test("Direct mode can await a retained task")
    func directModeCanAwaitRetainedTask() {
        let host = TestHost()
        let session = BASICSession(host: host)

        #expect(session.submit("global handle as task = AsyncValue(\"direct\")"))
        #expect(session.submit("print await handle"))

        #expect(host.output == ["direct"])
    }

    @Test("ASYNC FUNCTION body runs on scheduled task before await result")
    func asyncFunctionBodyRunsOnScheduledTaskBeforeAwaitResult() throws {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "slice 14"
        handle = AsyncBody("GAMMA", 4)
        print "CALLER AFTER HANDLE"
        value$ = await handle
        print "RESULT ="; value$
        async function AsyncBody(name$ as string, count as integer) as string
            print "ASYNC BODY "; name$; " "; count
            return name$ + ":" + str$(count)
        end function
        """)

        try session.runProgram()

        #expect(host.output == [
            "slice 14",
            "CALLER AFTER HANDLE",
            "ASYNC BODY GAMMA 4",
            "RESULT =GAMMA: 4"
        ])
    }

    @Test("Async interpreters serialize writes through the session output boundary")
    func asyncInterpretersSerializeHostOutput() throws {
        let host = ConcurrentOutputProbeHost()
        let session = BASICSession(host: host)
        session.program.loadSource("""
        global first as task = WriteMany("A")
        global second as task = WriteMany("B")
        join first
        join second

        async function WriteMany(prefix$ as string) as integer
            for i = 1 to 20
                print prefix$; i
            next i
            return 20
        end function
        """)

        try session.runProgram()

        #expect(host.maximumConcurrentWrites == 1)
        #expect(host.lines.count == 40)
    }

    @Test("Async function breakpoints retain frames across step and continue")
    func asyncFunctionDebuggerPauseIsResumable() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        let breakpointLocation = BASICBreakpointLocation(lineNumber: 7, statementNumber: 0)
        let initialControl = BASICExecutionControl()
        initialControl.setBreakpoints([BASICBreakpoint(location: breakpointLocation)])
        session.program.loadSource("""
        global handle as task = Work()
        global result as integer = await handle
        print "RESULT="; result

        async function Work() as integer
            local value as integer = 1
            value = value + 1
            value = value + 10
            return value
        end function
        """)

        do {
            try session.runProgram(executionControl: initialControl)
            Issue.record("Expected async breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == breakpointLocation)
        }

        let pausedTask = try #require(session.debugTasks.first { $0.name == "Work" })
        #expect(pausedTask.state == .suspended)
        #expect(pausedTask.suspensionReason == .debugger)
        #expect(pausedTask.suspendedFrames.first?.resumeLocation == breakpointLocation)
        #expect(pausedTask.suspendedFrames.first?.localVariables.first { $0.name.lowercased() == "value" }?.value == "1")

        let stepControl = BASICExecutionControl()
        stepControl.setBreakpoints([BASICBreakpoint(location: breakpointLocation)])
        stepControl.setMode(.stepInto)
        stepControl.setTargetTaskID(pausedTask.id)
        do {
            try session.continueProgram(executionControl: stepControl)
            Issue.record("Expected async step pause")
        } catch BASICError.stepComplete(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 8, statementNumber: 0))
        }

        let steppedTask = try #require(session.debugTasks.first { $0.id == pausedTask.id })
        #expect(steppedTask.state == .suspended)
        #expect(steppedTask.suspendedFrames.first?.resumeLocation == BASICBreakpointLocation(lineNumber: 8, statementNumber: 0))
        #expect(steppedTask.suspendedFrames.first?.localVariables.first { $0.name.lowercased() == "value" }?.value == "2")

        let continueControl = BASICExecutionControl()
        continueControl.setBreakpoints([BASICBreakpoint(location: breakpointLocation)])
        try session.continueProgram(executionControl: continueControl)

        #expect(host.output == ["RESULT=12"])
        #expect(session.debugTasks.first { $0.id == pausedTask.id }?.state == .completed)
    }

    @Test("Cancelling a debugger-suspended async function releases its retained frame")
    func cancellingDebuggerSuspendedAsyncFunction() async throws {
        let session = BASICSession(host: TestHost())
        let breakpointLocation = BASICBreakpointLocation(lineNumber: 6, statementNumber: 0)
        let control = BASICExecutionControl()
        control.setBreakpoints([BASICBreakpoint(location: breakpointLocation)])
        session.program.loadSource("""
        global handle as task = Work()
        global result as integer = await handle

        async function Work() as integer
            local value as integer = 1
            value = value + 1
            return value
        end function
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected async breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == breakpointLocation)
        }

        let pausedTask = try #require(session.debugTasks.first { $0.name == "Work" })
        #expect(session.requestTaskCancellation(id: pausedTask.id))
        try await waitForTaskState(session, id: pausedTask.id, expected: .cancelled)

        do {
            try session.continueProgram(executionControl: BASICExecutionControl())
            Issue.record("Expected awaiting parent to observe cancellation")
        } catch {
            #expect(String(describing: error).contains("Awaited task was cancelled"))
        }
        #expect(session.debugTasks.first { $0.id == pausedTask.id }?.suspendedFrames.isEmpty == true)
    }

    @Test("JOIN waits for an async task and discards its result")
    func joinWaitsForAsyncTaskAndDiscardsResult() throws {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "slice 28"
        handle = AsyncBody("JOINED", 28)
        print "CALLER BEFORE JOIN"
        join handle
        print "CALLER AFTER JOIN"
        async function AsyncBody(name$ as string, count as integer) as string
            print "ASYNC BODY "; name$; " "; count
            return name$ + ":" + str$(count)
        end function
        """)

        try session.runProgram()

        #expect(host.output == [
            "slice 28",
            "CALLER BEFORE JOIN",
            "ASYNC BODY JOINED 28",
            "CALLER AFTER JOIN"
        ])
    }

    @Test("ASYNC FUNCTION body receives launch-time global snapshot")
    func asyncFunctionBodyReceivesLaunchTimeGlobalSnapshot() throws {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        type Payload
            Name as string
            Count as integer
        end type
        global shared as integer = 10
        global title$ = "SNAP"
        global payload as Payload
        payload.Name = "Ada"
        payload.Count = 7
        handle = ReadSnapshot(5)
        shared = 99
        title$ = "LIVE"
        payload.Name = "Grace"
        payload.Count = 8
        value$ = await handle
        print "RESULT ="; value$
        print "LIVE ="; title$; ":"; shared; ":"; payload.Name; ":"; payload.Count
        async function ReadSnapshot(extra as integer) as string
            return title$ + ":" + str$(shared + extra) + ":" + payload.Name + ":" + str$(payload.Count)
        end function
        """)

        try session.runProgram()

        #expect(host.output == [
            "RESULT =SNAP: 15:Ada: 7",
            "LIVE =LIVE:99:Grace:8"
        ])
    }

    @Test("ASYNC FUNCTION can await nested async functions and host timers")
    func asyncFunctionCanAwaitNestedAsyncFunctionsAndHostTimers() throws {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        value = await OuterAsync(7)
        print "VALUE ="; value
        async function OuterAsync(input as integer) as integer
            waited = await Sleep(5)
            inner = await InnerAsync(input + waited)
            return inner + 1
        end function
        async function InnerAsync(input as integer) as integer
            return input * 2
        end function
        """)

        try session.runProgram()

        #expect(host.output == ["VALUE =25"])
        let tasks = session.debugTasks
        let program = tasks.first { $0.name == "Program" }
        let outer = tasks.first { $0.name == "OuterAsync" }
        let timer = tasks.first { $0.name == "SLEEP" }
        let inner = tasks.first { $0.name == "InnerAsync" }
        #expect(outer?.parentID == program?.id)
        #expect(timer?.parentID == outer?.id)
        #expect(inner?.parentID == outer?.id)
        #expect(tasks.allSatisfy { $0.state == .completed })
    }

    @Test("Cancelling an async function cancels its owned await tree")
    func cancellingAsyncFunctionCancelsItsOwnedAwaitTree() async throws {
        let session = BASICSession(host: TestHost())
        let lane = BASICWorkerLane(label: "AIBasicTests.AsyncCancellation")
        let resultBox = ThreadSafeValueBox<BASICWorkerLaneRunResult>()

        session.program.loadSource("""
        value = await SlowAsync()
        print value
        async function SlowAsync() as integer
            waited = await Sleep(10000)
            return waited
        end function
        """)

        #expect(session.runProgram(on: lane) { result in
            resultBox.store(result)
        })

        var asyncTaskID: Int?
        for _ in 0..<100 {
            asyncTaskID = session.debugTasks.first { $0.name == "SlowAsync" }?.id
            if asyncTaskID != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let taskID = try #require(asyncTaskID)
        #expect(session.requestTaskCancellation(id: taskID))
        try await waitForTaskState(session, id: taskID, expected: .cancelled)

        var result: BASICWorkerLaneRunResult?
        for _ in 0..<100 {
            result = resultBox.value
            if result != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if case .failure(let message) = result {
            #expect(message.contains("Awaited task was cancelled"))
        } else {
            Issue.record("Expected the awaiting program to report cancellation")
        }

        let timer = try #require(session.debugTasks.first { $0.name == "SLEEP" })
        try await waitForTaskState(session, id: timer.id, expected: .cancelled)
    }

    @Test("Foreground Stop or Ctrl-C cancels the complete async task tree")
    func foregroundBreakCancelsCompleteAsyncTaskTree() async throws {
        let session = BASICSession(host: TestHost())
        let lane = BASICWorkerLane(label: "AIBasicTests.ForegroundAsyncStop")
        let control = BASICExecutionControl()
        let resultBox = ThreadSafeValueBox<BASICWorkerLaneRunResult>()
        session.stopsForegroundProgramOnBreak = true
        session.program.loadSource("""
        value = await OuterAsync()
        print value
        async function OuterAsync() as integer
            waited = await Sleep(10000)
            return waited
        end function
        """)

        #expect(session.runProgram(on: lane, executionControl: control) { result in
            resultBox.store(result)
        })

        var timerID: Int?
        for _ in 0..<100 {
            timerID = session.debugTasks.first { $0.name == "SLEEP" }?.id
            if timerID != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = try #require(timerID)
        control.requestBreak()

        var result: BASICWorkerLaneRunResult?
        for _ in 0..<100 {
            result = resultBox.value
            if result != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if case .failure(let message) = result {
            #expect(message.contains("Break"))
        } else {
            Issue.record("Expected foreground break to end the run")
        }

        for snapshot in session.debugTasks.filter({ ["Program", "OuterAsync", "SLEEP"].contains($0.name) }) {
            try await waitForTaskState(session, id: snapshot.id, expected: .cancelled)
        }
        #expect(session.debugTasks.filter { ["Program", "OuterAsync", "SLEEP"].contains($0.name) }.count == 3)
    }

    @Test("BASIC task status error and cancellation APIs are available")
    func basicTaskStatusErrorAndCancellationAPIsAreAvailable() throws {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        completeHandle = AsyncValue(42)
        join completeHandle
        print taskstatus$(completeHandle)
        print "ERROR="; taskerror$(completeHandle)
        slowHandle = SlowAsync()
        cancel slowHandle
        print taskstatus$(slowHandle)
        async function SlowAsync() as integer
            waited = await Sleep(10000)
            return waited
        end function
        """)

        try session.runProgram()

        #expect(host.output == ["COMPLETED", "ERROR=", "CANCELLED"])
        let slow = try #require(session.debugTasks.first { $0.name == "SlowAsync" })
        #expect(slow.isCancellationRequested)
    }

    @Test("ASYNC FUNCTION failures surface at AWAIT and respect ON ERROR")
    func asyncFunctionFailuresSurfaceAtAwaitAndRespectOnError() throws {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        on error goto Handler
        handle = FailingAsync()
        print "BEFORE AWAIT"
        value = await handle
        print "AFTER AWAIT"
        end
        Handler:
            print "ERR", ERR
            print "ERL", ERL
            resume next
        async function FailingAsync() as integer
            return 10 / 0
        end function
        """)

        try session.runProgram()

        #expect(host.output == [
            "BEFORE AWAIT",
            "ERR           11",
            "ERL           4",
            "AFTER AWAIT"
        ])
    }

    @Test("Shared async value cell supports synchronized mutation")
    func sharedAsyncValueCellSupportsSynchronizedMutation() async throws {
        let cell = BASICSharedValueCell(id: 1, name: "sharedTotal", value: .number(0))

        async let alpha: Void = {
            for _ in 0..<50 {
                _ = cell.update { value in
                    .number((value.number ?? 0) + 1)
                }
                await Task.yield()
            }
        }()
        async let beta: Void = {
            for _ in 0..<50 {
                _ = cell.update { value in
                    .number((value.number ?? 0) + 1)
                }
                await Task.yield()
            }
        }()

        _ = await (alpha, beta)

        let snapshot = cell.snapshot()
        #expect(snapshot.name == "sharedTotal")
        #expect(snapshot.typeName == "DOUBLE")
        #expect(snapshot.value == "100")
        #expect(snapshot.revision == 100)
        #expect(snapshot.access == .strongMutable)
    }

    @Test("Read-only async value cell reports access and rejects mutation")
    func readOnlyAsyncValueCellReportsAccessAndRejectsMutation() {
        let cell = BASICSharedValueCell(
            id: 2,
            name: "title$",
            value: .string(BASICString("original")),
            access: .readOnly
        )

        #expect(!cell.set(.string(BASICString("changed"))))
        #expect(cell.update { _ in .string(BASICString("changed")) } == nil)

        let snapshot = cell.snapshot()
        #expect(snapshot.name == "title$")
        #expect(snapshot.typeName == "STRING")
        #expect(snapshot.value == "original")
        #expect(snapshot.revision == 0)
        #expect(snapshot.access == .readOnly)
    }

    @Test("Captured environment stores named cells case insensitively")
    func capturedEnvironmentStoresNamedCellsCaseInsensitively() {
        let environment = BASICCapturedEnvironment()

        let first = environment.capture(name: "Score", value: .number(10))
        let title = environment.capture(
            name: "Title$",
            value: .string(BASICString("hello")),
            access: .readOnly
        )

        #expect(first.id == 1)
        #expect(title.id == 2)
        #expect(environment.count == 2)
        #expect(environment.value(named: "score") == .number(10))
        #expect(environment.value(named: "SCORE") == .number(10))
        #expect(environment.value(named: "title$") == .string(BASICString("hello")))

        #expect(environment.set(.number(11), named: "sCoRe"))
        #expect(environment.value(named: "SCORE") == .number(11))
        #expect(!environment.set(.string(BASICString("changed")), named: "TITLE$"))

        let snapshots = environment.snapshots
        #expect(snapshots.map(\.name) == ["Score", "Title$"])
        #expect(snapshots[0].revision == 1)
        #expect(snapshots[1].access == .readOnly)
        #expect(snapshots[1].value == "hello")
    }

    @Test("Captured environment supports synchronized updates")
    func capturedEnvironmentSupportsSynchronizedUpdates() async throws {
        let environment = BASICCapturedEnvironment()
        environment.capture(name: "counter", value: .number(0))

        async let alpha: Void = {
            for _ in 0..<75 {
                _ = environment.update(named: "COUNTER") { value in
                    .number((value.number ?? 0) + 1)
                }
                await Task.yield()
            }
        }()
        async let beta: Void = {
            for _ in 0..<25 {
                _ = environment.update(named: "counter") { value in
                    .number((value.number ?? 0) + 1)
                }
                await Task.yield()
            }
        }()

        _ = await (alpha, beta)

        let snapshot = try #require(environment.snapshot(named: "Counter"))
        #expect(snapshot.value == "100")
        #expect(snapshot.revision == 100)
        #expect(snapshot.access == .strongMutable)
    }

    @Test("Captured closure reads and mutates captured environment")
    func capturedClosureReadsAndMutatesCapturedEnvironment() throws {
        let environment = BASICCapturedEnvironment()
        environment.capture(name: "prefix$", value: .string(BASICString("Score: ")), access: .readOnly)
        environment.capture(name: "count", value: .number(0))

        let closure = BASICCapturedClosure(name: "Formatter", environment: environment) { environment, arguments in
            let prefix = environment.value(named: "PREFIX$")?.string?.description ?? ""
            let value = arguments.first?.description ?? ""
            _ = environment.update(named: "count") { current in
                .number((current.number ?? 0) + 1)
            }
            return .string(BASICString(prefix + value))
        }

        let first = try closure.call(arguments: [.number(42)])
        let second = try closure.call(arguments: [.string(BASICString("READY"))])

        #expect(first == .string(BASICString("Score: 42")))
        #expect(second == .string(BASICString("Score: READY")))
        #expect(environment.value(named: "count") == .number(2))
    }

    @Test("Captured closure exposes stable captured snapshots")
    func capturedClosureExposesStableCapturedSnapshots() throws {
        let environment = BASICCapturedEnvironment()
        environment.capture(name: "Title$", value: .string(BASICString("Demo")), access: .readOnly)
        environment.capture(name: "Total", value: .number(5))

        let closure = BASICCapturedClosure(name: "Inspector", environment: environment) { environment, _ in
            _ = environment.set(.number(6), named: "total")
            return environment.value(named: "title$") ?? .empty
        }

        #expect(try closure.call() == .string(BASICString("Demo")))
        #expect(closure.name == "Inspector")

        let snapshots = closure.capturedSnapshots
        #expect(snapshots.map(\.name) == ["Title$", "Total"])
        #expect(snapshots[0].access == .readOnly)
        #expect(snapshots[1].value == "6")
        #expect(snapshots[1].revision == 1)
    }

    @Test("BASIC closure expressions use named typed parameters")
    func basicClosureExpressionsUseNamedTypedParameters() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        let add = function(left as integer, right as integer) as integer = left + right
        print add(2, 3)
        print add(10, -4)
        """)
        session.submit("RUN")

        #expect(host.output == ["5", "6"])
    }

    @Test("BASIC closure expressions capture surrounding values by snapshot")
    func basicClosureExpressionsCaptureSurroundingValuesBySnapshot() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        prefix$ = "Score: "
        bonus = 5
        formatter = function(value as integer) as string = prefix$ + str$(value + bonus)
        prefix$ = "Changed: "
        bonus = 100
        print formatter(7)
        """)
        session.submit("RUN")

        #expect(host.output == ["Score:  12"])
    }

    @Test("BASIC closure expressions validate typed arguments")
    func basicClosureExpressionsValidateTypedArguments() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        local twice = function(value as integer) as integer = value * 2
        print twice("nope")
        """)
        session.submit("RUN")

        #expect(host.output == ["Type error: Cannot assign non-numeric value to value"])
    }

    @Test("BASIC closure expressions support explicit capture lists")
    func basicClosureExpressionsSupportExplicitCaptureLists() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        prefix$ = "LOCKED="
        bonus = 5
        formatter = function(value as integer) as string captures readonly prefix$ = prefix$ + str$(value + bonus)
        prefix$ = "LIVE="
        bonus = 20
        print formatter(2)
        """)
        session.submit("RUN")

        #expect(host.output == ["LOCKED= 22"])
    }

    @Test("Debugger snapshots expose closure signatures and captures")
    func debuggerSnapshotsExposeClosureSignaturesAndCaptures() throws {
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 4, statementNumber: 0))
        ])
        let session = BASICSession(host: TestHost())

        session.program.loadSource("""
        prefix$ = "LOCKED="
        bonus = 5
        formatter = function(value as integer) as string captures readonly prefix$, readonly bonus = prefix$ + str$(value + bonus)
        yield
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 4, statementNumber: 0))
        }

        let formatter = try #require(session.debugGlobalVariables.first { $0.name == "formatter" })
        #expect(formatter.typeName == "FUNCTION (value AS INTEGER) AS STRING")
        #expect(formatter.value == "2 captures")
        let signature = try #require(formatter.children.first { $0.name == "Signature" })
        #expect(signature.value == "(value AS INTEGER) AS STRING")
        let captures = try #require(formatter.children.first { $0.name == "Captured Values" })
        #expect(captures.value == "2 captures")
        #expect(captures.children.contains {
            $0.name == "prefix$" && $0.typeName == "STRING" && $0.value == "LOCKED= [Read Only, rev 0]"
        })
        #expect(captures.children.contains {
            $0.name == "bonus" && $0.typeName == "DOUBLE" && $0.value == "5 [Read Only, rev 0]"
        })
    }

    @Test("BASIC closure expressions support multi-line bodies")
    func basicClosureExpressionsSupportMultiLineBodies() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        function type ScoreFormatter(value as integer) as string
        prefix$ = "BLOCK="
        bonus = 4
        local formatter as ScoreFormatter
        formatter = function(value as integer) as string
            local adjusted as integer = value + bonus
            return prefix$ + str$(adjusted)
        end function
        prefix$ = "LIVE="
        bonus = 100
        print formatter(6)
        """)
        session.submit("RUN")

        #expect(host.output == ["BLOCK= 10"])
    }

    @Test("FUNCTION TYPE declarations type closure variables structurally")
    func functionTypeDeclarationsTypeClosureVariablesStructurally() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        function type ScoreFormatter(value as integer) as string
        local formatter as ScoreFormatter
        formatter = function(points as integer) as string = "SCORE=" + str$(points)
        print formatter(12)
        """)
        session.submit("RUN")

        #expect(host.output == ["SCORE= 12"])
    }

    @Test("FUNCTION TYPE declarations reject mismatched closures")
    func functionTypeDeclarationsRejectMismatchedClosures() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        function type ScoreFormatter(value as integer) as string
        local formatter as ScoreFormatter
        formatter = function(text$ as string) as string = text$
        print "unreachable"
        """)
        session.submit("RUN")

        #expect(host.output == ["Type error: Type Mismatch"])
    }

    @Test("FUNCTION TYPE declarations can type callback parameters")
    func functionTypeDeclarationsCanTypeCallbackParameters() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        function type ScoreFormatter(value as integer) as string
        local formatter as ScoreFormatter
        formatter = function(points as integer) as string = "CALLBACK=" + str$(points)
        print RenderScore(14, formatter)
        end

        function RenderScore(value as integer, formatter as ScoreFormatter) as string
            return formatter(value + 1)
        end function
        """)
        session.submit("RUN")

        #expect(host.output == ["CALLBACK= 15"])
    }

    @Test("FUNCTION TYPE declarations can be returned from functions")
    func functionTypeDeclarationsCanBeReturnedFromFunctions() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        function type ScoreFormatter(value as integer) as string
        local formatter as ScoreFormatter
        formatter = MakeFormatter("FACTORY=")
        print formatter(26)
        end

        function MakeFormatter(prefix$ as string) as ScoreFormatter
            return function(value as integer) as string = prefix$ + str$(value)
        end function
        """)
        session.submit("RUN")

        #expect(host.output == ["FACTORY= 26"])
    }

    private func waitForTaskState(_ session: BASICSession, id: Int, expected state: BASICTaskState) async throws {
        for _ in 0..<100 {
            if session.debugTasks.first(where: { $0.id == id })?.state == state {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Expected task \(id) to reach \(state)")
    }

    private func waitForEventLoopPending(_ session: BASICSession, expected count: Int) async throws {
        for _ in 0..<100 {
            if session.eventLoop.pendingCount >= count {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Expected event loop to have at least \(count) pending callback(s)")
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

    @Test("Built-in File class cannot be redefined")
    func builtInFileClassCannotBeRedefined() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        class File
        end class
        """)
        session.submit("run")

        #expect(host.output == ["Runtime error: Cannot redefine built-in class FILE"])
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

    @Test("Modern File RAW mode preserves bytes and reports metadata")
    func modernFileRawModePreservesBytesAndReportsMetadata() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        let output = File("bytes.bin", WRITE, RAW, true)
        output.write(chr$(65) + chr$(0) + chr$(255))
        print output.size()
        print output.path$()
        print output.access$()
        print output.type$()
        output.close

        let input = File("bytes.bin", READ, RAW, false)
        let copy = File("copy.bin", WRITE, RAW, true)
        copy.write(input.read(2))
        copy.write(input.read())
        input.close
        copy.close
        """)
        session.submit("run")

        #expect(host.output == ["3", "bytes.bin", "WRITE", "RAW"])
        #expect(host.fileData["bytes.bin"] == Data([65, 0, 255]))
        #expect(host.fileData["copy.bin"] == Data([65, 0, 255]))
    }

    @Test("Modern File BOTH mode uses character positions and byte sizes")
    func modernFileBothModeUsesCharacterPositionsAndByteSizes() throws {
        let host = TestHost()
        host.files["unicode.txt"] = "Aé🙂Z"
        host.fileData["unicode.txt"] = Data("Aé🙂Z".utf8)
        let session = BASICSession(host: host)

        session.program.loadSource("""
        let file = File("unicode.txt", BOTH, TEXT, false)
        print file.read(2)
        file.write("XY")
        print file.size()
        """)
        session.submit("run")

        #expect(host.output == ["Aé", "5"])
        #expect(host.files["unicode.txt"] == "AéXY")
        let snapshot = try #require(session.debugFiles.first { $0.path == "unicode.txt" })
        #expect(snapshot.position == 4)
        #expect(snapshot.size == 5)
        #expect(snapshot.isAtEOF)
    }

    @Test("Modern File BOTH JSON reads then atomically replaces the document")
    func modernFileBothJSONReadsThenReplacesDocument() {
        let host = TestHost()
        host.files["state.json"] = "{\"count\":1}"
        host.fileData["state.json"] = Data("{\"count\":1}".utf8)
        let session = BASICSession(host: host)

        session.program.loadSource("""
        let file = File("state.json", BOTH, JSON, false)
        let payload as variant = file.json()
        payload("count") = 2
        file.writeJson(payload, false)
        file.close

        let check = File("state.json", READ, JSON, false)
        let restored as variant = check.json()
        print restored("count")
        check.close
        """)
        session.submit("run")

        #expect(host.output == ["2"])
        #expect(host.files["state.json"] == "{\"count\":2}")
    }

    @Test("Modern File rejects opening an already open object")
    func modernFileRejectsOpeningAnAlreadyOpenObject() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        let file = File("first.txt", WRITE, TEXT, false)
        file.open("second.txt", WRITE, TEXT, false)
        """)
        session.submit("run")

        #expect(host.output == ["Runtime error: File Already Open"])
        #expect(host.files["first.txt"] == "")
        #expect(host.files["second.txt"] == nil)
    }

    @Test("Shared File text and byte helpers preserve their respective representations")
    func sharedFileTextAndByteHelpersPreserveRepresentations() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        File.WriteText "note.txt", "héllo"
        print File.ReadText$("note.txt")
        File.WriteBytes "bytes.bin", chr$(65) + chr$(0)
        File.AppendBytes "bytes.bin", chr$(255)
        payload$ = File.ReadBytes$("bytes.bin")
        File.WriteBytes "copy.bin", payload$
        """)
        session.submit("run")

        #expect(host.output == ["héllo"])
        #expect(host.fileData["bytes.bin"] == Data([65, 0, 255]))
        #expect(host.fileData["copy.bin"] == Data([65, 0, 255]))
    }

    @Test("Shared File methods manage directories paths and JSON")
    func sharedFileMethodsManageDirectoriesPathsAndJSON() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        File.Mkdir "workspace"
        print File.IsDir("workspace")
        File.WriteJson("workspace/config.json", FromJsonString('{"ready":true}', true), false)
        let names as variant = File.Files$("workspace")
        print len(names)
        print names(0)
        File.Rename "workspace/config.json", "workspace/settings.json"
        print File.Exists("workspace/config.json")
        print File.Exists("workspace/settings.json")
        let payload = File.ReadJson("workspace/settings.json")
        print payload("ready")
        File.Rm "workspace/settings.json"
        File.Rm "workspace"
        print File.Exists("workspace")
        print File.Cwd$()
        """)
        session.submit("run")

        #expect(host.output == [
            "TRUE",
            "1",
            "config.json",
            "FALSE",
            "TRUE",
            "TRUE",
            "FALSE",
            "."
        ])
    }

    @Test("File Files returns sorted immediate directory entries")
    func fileFilesReturnsSortedImmediateDirectoryEntries() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        File.Mkdir "workspace"
        File.Mkdir "workspace/sub"
        File.WriteText "workspace/z.txt", "z"
        File.WriteText "workspace/a.txt", "a"
        File.WriteText "workspace/sub/deep.txt", "deep"
        let names as variant = File.Files$("workspace")
        print len(names)
        print names(0)
        print names(1)
        print names(2)
        """)
        session.submit("run")

        #expect(host.output == ["3", "a.txt", "sub", "z.txt"])
    }

    @Test("File Rm refuses nonempty directories")
    func fileRmRefusesNonemptyDirectories() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        File.Mkdir "workspace"
        File.WriteText "workspace/keep.txt", "keep"
        File.Rm "workspace"
        """)
        session.submit("run")

        #expect(host.output == ["Runtime error: Directory not empty"])
        #expect(host.directories.contains("workspace"))
        #expect(host.files["workspace/keep.txt"] == "keep")
    }

    @Test("File APIs preserve host policy rejection")
    func fileAPIsPreserveHostPolicyRejection() {
        let host = TestHost()
        host.deniedFilePaths.insert("blocked.txt")
        let session = BASICSession(host: host)

        session.program.loadSource("""
        let file = File("blocked.txt", WRITE, TEXT, false)
        """)
        session.submit("run")

        #expect(host.output == ["Runtime error: Permission denied"])
        #expect(host.files["blocked.txt"] == nil)
    }

    @Test("File ChDir controls relative path resolution")
    func fileChDirControlsRelativePathResolution() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        File.Mkdir "work"
        File.ChDir "work"
        File.WriteText "relative.txt", "inside"
        print File.Cwd$()
        print File.ReadText$("relative.txt")
        """)
        session.submit("run")

        #expect(host.output == ["work", "inside"])
        #expect(host.currentDirectory == "work")
        #expect(host.files["work/relative.txt"] == "inside")
    }

    @Test("Known legacy device paths are rejected until device support exists")
    func knownLegacyDevicePathsAreRejected() {
        let modernHost = TestHost()
        let modernSession = BASICSession(host: modernHost)
        modernSession.program.loadSource("""
        let device = File("COM1:9600,N,8,1", WRITE, RAW, false)
        """)
        modernSession.submit("run")
        #expect(modernHost.output == ["Runtime error: Unsupported file device"])

        let legacyHost = TestHost()
        let legacySession = BASICSession(host: legacyHost)
        legacySession.program.loadSource("""
        open "LPT1:" for output as #1
        """)
        legacySession.submit("run")
        #expect(legacyHost.output == ["Runtime error: Unsupported file device"])
    }

    @Test("Legacy sequential file statements write read append and report EOF")
    func legacySequentialFileStatementsWriteReadAppendAndReportEOF() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        open "legacy.txt" for output as #1
        print #1, "HELLO"; " "; 42
        print#1, "NEXT,"; 7
        print #1, using "TOTAL ###.##"; 12.3
        close #1

        open "legacy.txt" for append as #1
        print #1, "TAIL"
        close #1

        open "legacy.txt" for input as #2
        line input #2, a$
        input#2, b$, n
        line input#2, c$
        line input #2, d$
        print a$
        print b$
        print n
        print c$
        print d$
        print eof(2)
        close
        """)
        session.submit("run")

        #expect(host.files["legacy.txt"] == "HELLO 42\nNEXT,7\nTOTAL  12.30\nTAIL\n")
        #expect(host.output == [
            "HELLO 42",
            "NEXT",
            "7",
            "TOTAL  12.30",
            "TAIL",
            "TRUE"
        ])
    }

    @Test("INPUT$ reads fixed character counts from numbered files")
    func inputStringReadsFixedCountsFromNumberedFiles() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.files["raw.txt"] = "ABCDEF"

        session.program.loadSource("""
        open "raw.txt" for input as #1
        print input$(2, #1)
        print input$(3, #1)
        print eof(1)
        print input$(1, #1)
        print eof(1)
        close #1
        """)
        session.submit("run")

        #expect(host.output == ["AB", "CDE", "FALSE", "F", "TRUE"])
    }

    @Test("WRITE hash round trips quoted comma separated values through INPUT hash")
    func writeFileRoundTripsMachineReadableValues() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        open "values.csv" for output as #1
        write #1, "ADA, LOVELACE", 36, true, 'SHE SAID "HI"'
        close #1

        dim active as boolean
        open "values.csv" for input as #1
        input #1, name$, age, active, note$
        close #1
        print name$
        print age
        print active
        print note$
        """)
        session.submit("run")

        #expect(host.files["values.csv"] == "\"ADA, LOVELACE\",36,TRUE,\"SHE SAID \"\"HI\"\"\"\n")
        #expect(host.output == ["ADA, LOVELACE", "36", "TRUE", "SHE SAID \"HI\""])
    }

    @Test("Binary OPEN LOF and INPUT string preserve exact bytes")
    func binaryOpenAndInputStringPreserveExactBytes() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.fileData["source.bin"] = Data([65, 0, 66, 13, 10, 255])

        session.program.loadSource("""
        open "source.bin" for binary as #1
        print lof(1)
        payload$ = input$(lof(1), 1)
        print eof(1)
        close #1

        dim output as File
        output = File("copy.bin", WRITE, RAW, false)
        output.write(payload$)
        print output.size()
        output.close
        """)
        session.submit("run")

        #expect(host.output == ["6", "TRUE", "6"])
        #expect(host.fileData["copy.bin"] == Data([65, 0, 66, 13, 10, 255]))
    }

    @Test("Random files support FIELD alignment records positions and numeric conversions")
    func randomFilesSupportFixedRecordsAndNumericConversions() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        open "people.dat" as #1 len = 12
        field #1, 8 as name$, 4 as code$
        lset name$ = "ADA"
        rset code$ = "7"
        put #1, 1
        lset name$ = "GRACE"
        rset code$ = "12"
        put #1, 2

        get #1, 1
        print "["; name$; "]["; code$; "]"
        print lof(1)
        print loc(1)
        print seek(1)
        close #1

        print cvi(mki$(-1234))
        print cvs(mks$(12.5))
        print cvd(mkd$(42.25))
        """)
        session.submit("run")

        #expect(host.output == ["[ADA     ][   7]", "24", "1", "2", "-1234", "12.5", "42.25"])
        #expect(host.fileData["people.dat"] == Data("ADA        7GRACE     12".utf8))
    }

    @Test("Extended integer conversions preserve width signed values and byte order in random files")
    func extendedIntegerConversionsRoundTripThroughRandomFiles() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        open "integers.dat" as #1 len = 14
        field #1, 2 as int16Bytes$, 4 as int32Bytes$, 8 as int64Bytes$
        lset int16Bytes$ = mki$(-1234, 16, little)
        lset int32Bytes$ = mki$(2000000000, 32, big)
        lset int64Bytes$ = mki$(5000000000, 64, little)
        put #1, 1

        lset int16Bytes$ = ""
        lset int32Bytes$ = ""
        lset int64Bytes$ = ""
        get #1, 1
        print cvi(int16Bytes$, 16, little)
        print cvi(int32Bytes$, 32, big)
        print cvi(int64Bytes$, 64, little)
        close #1

        print len(mki$(1, 16, native))
        print len(mki$(1, 32, native))
        print len(mki$(1, 64, native))
        print cvs(mks$(12.5, big), big)
        print cvd(mkd$(42.25, big), big)
        """)
        session.submit("run")

        #expect(host.output == ["-1234", "2000000000", "5000000000", "2", "4", "8", "12.5", "42.25"])
        #expect(host.fileData["integers.dat"] == Data([
            0x2e, 0xfb,
            0x77, 0x35, 0x94, 0x00,
            0x00, 0xf2, 0x05, 0x2a, 0x01, 0x00, 0x00, 0x00
        ]))
    }

    @Test("Extended integer conversions reject invalid widths byte orders and overflow")
    func extendedIntegerConversionsValidateArguments() {
        let widthHost = TestHost()
        let widthSession = BASICSession(host: widthHost)
        widthSession.program.loadSource("print len(mki$(1, 24))")
        widthSession.submit("run")
        #expect(widthHost.output == ["Runtime error: mki$ width must be 16, 32, or 64"])

        let orderHost = TestHost()
        let orderSession = BASICSession(host: orderHost)
        orderSession.program.loadSource("print cvi(mki$(1), 16, \"SIDEWAYS\")")
        orderSession.submit("run")
        #expect(orderHost.output == ["Runtime error: cvi byte order must be NATIVE, LITTLE, or BIG"])

        let overflowHost = TestHost()
        let overflowSession = BASICSession(host: overflowHost)
        overflowSession.program.loadSource("print len(mki$(32768))")
        overflowSession.submit("run")
        #expect(overflowHost.output == ["Runtime error: Overflow"])

        let precisionHost = TestHost()
        let precisionSession = BASICSession(host: precisionHost)
        precisionSession.program.loadSource("""
        maxBytes$ = chr$(255) + chr$(255) + chr$(255) + chr$(255)
        maxBytes$ = maxBytes$ + chr$(255) + chr$(255) + chr$(255) + chr$(127)
        print cvi(maxBytes$, 64, little)
        """)
        precisionSession.submit("run")
        #expect(precisionHost.output == ["Runtime error: CVI 64-bit value cannot be represented exactly"])
    }

    @Test("Random files reject invalid record layouts and text operations reject binary mode")
    func legacyFileModesRejectInvalidOperations() {
        let lengthHost = TestHost()
        let lengthSession = BASICSession(host: lengthHost)
        lengthSession.program.loadSource("""
        open "bad.dat" as #1 len = 0
        """)
        lengthSession.submit("run")
        #expect(lengthHost.output == ["Runtime error: Bad record length"])

        let fieldHost = TestHost()
        let fieldSession = BASICSession(host: fieldHost)
        fieldSession.program.loadSource("""
        open "bad.dat" as #1 len = 4
        field #1, 5 as value$
        """)
        fieldSession.submit("run")
        #expect(fieldHost.output == ["Runtime error: FIELD overflow"])

        let binaryHost = TestHost()
        let binarySession = BASICSession(host: binaryHost)
        binarySession.program.loadSource("""
        open "bad.dat" for binary as #1
        print #1, "text"
        """)
        binarySession.submit("run")
        #expect(binaryHost.output == ["Runtime error: Bad file mode"])
    }

    @Test("Debugger file snapshots expose modern and numbered file state")
    func debuggerFileSnapshotsExposeFileState() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 5, statementNumber: 0))
        ])
        session.program.loadSource("""
        dim modern as File
        modern = File("modern.txt", WRITE, TEXT, false)
        modern.write("hello")
        open "records.dat" as #2 len = 8
        print "pause"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 5, statementNumber: 0))
        }

        let modern = try #require(session.debugFiles.first { $0.path == "modern.txt" })
        #expect(modern.path == "modern.txt")
        #expect(modern.access == "WRITE")
        #expect(modern.type == "TEXT")
        #expect(modern.position == 5)
        #expect(modern.size == 5)
        #expect(modern.isAtEOF)
        #expect(modern.isOpen)

        let numbered = try #require(session.debugFiles.first { $0.reference == "#2" })
        #expect(numbered.path == "records.dat")
        #expect(numbered.access == "BOTH")
        #expect(numbered.type == "RANDOM")
        #expect(numbered.recordLength == 8)
        #expect(numbered.isOpen)

        session.submit("OPENFILES")
        #expect(host.output.first == "REF       STATE   ACCESS TYPE     POSITION SIZE PATH")
        #expect(host.output.contains { $0.contains("File(") && $0.contains("modern.txt") })
        #expect(host.output.contains { $0.contains("#2") && $0.contains("records.dat") && $0.contains("LEN=8") })
    }

    @Test("Modern File snapshots retain the last operation error")
    func modernFileSnapshotsRetainLastError() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("dim f as File")
        session.submit("f = File()")
        session.submit("print f.read()")

        #expect(host.output == ["Runtime error: File is not open"])
        #expect(session.debugFiles.count == 1)
        #expect(session.debugFiles[0].lastError?.contains("File is not open") == true)
    }

    @Test("Legacy file snapshots retain trapped operation errors")
    func legacyFileSnapshotsRetainTrappedErrors() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        let control = BASICExecutionControl()
        control.setBreakpoints([
            BASICBreakpoint(location: BASICBreakpointLocation(lineNumber: 6, statementNumber: 0))
        ])
        session.program.loadSource("""
        open "bytes.bin" for binary as #1
        on error goto Handler
        print #1, "not allowed"
        end
        Handler:
        print "handled"
        """)

        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint in error handler")
        } catch BASICError.breakpoint(let location) {
            #expect(location == BASICBreakpointLocation(lineNumber: 6, statementNumber: 0))
        }

        let snapshot = try #require(session.debugFiles.first { $0.reference == "#1" })
        #expect(snapshot.lastError?.contains("Bad file mode") == true)
        #expect(snapshot.isOpen)
    }

    @Test("INPUT$ reads keyboard characters")
    func inputStringReadsKeyboardCharacters() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.keys = ["A", "B", "C"]

        session.program.loadSource("""
        print input$(2)
        print input$(2)
        """)
        session.submit("run")

        #expect(host.output == ["AB", "C"])
    }

    @Test("IBM PUT GET and RESET use legacy numbered files")
    func ibmPutGetAndResetUseLegacyNumberedFiles() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        open "ibm-file.txt" for output as #1
        put #1, "ADA"; ","; 16
        close #1

        open "ibm-file.txt" for input as #1
        get #1, name$, age
        print name$; " "; age
        reset #1
        line input #1, raw$
        print raw$
        close #1
        """)
        session.submit("run")

        #expect(host.files["ibm-file.txt"] == "ADA,16\n")
        #expect(host.output == ["ADA 16", "ADA,16"])
    }

    @Test("Legacy sequential files report bad modes and missing files")
    func legacySequentialFilesReportBadModesAndMissingFiles() {
        let missingHost = TestHost()
        let missingSession = BASICSession(host: missingHost)
        missingSession.program.loadSource("""
        open "missing.txt" for input as #1
        """)
        missingSession.submit("run")
        #expect(missingHost.output == ["Runtime error: File Not Found"])

        let modeHost = TestHost()
        let modeSession = BASICSession(host: modeHost)
        modeSession.program.loadSource("""
        open "out.txt" for output as #1
        line input #1, a$
        """)
        modeSession.submit("run")
        #expect(modeHost.output == ["Runtime error: Bad file mode"])
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

    @Test("PROMPT PROFILE applies named prompt presets")
    func promptProfileAppliesNamedPromptPresets() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("PROMPT PROFILE classic")
        #expect(session.promptTemplate == "READY%nl> ")

        session.submit("PROMPT PROFILE plain")
        #expect(session.promptTemplate == BASICSession.plainPromptTemplate)

        session.submit("PROMPT PROFILE shell")
        #expect(session.promptTemplate == BASICSession.defaultPromptTemplate)

        session.submit("PROMPT PROFILE basic")
        #expect(session.promptTemplate == "READY%nl> ")

        session.submit("PROMPT PROFILE powerline")
        #expect(session.promptTemplate == BASICSession.defaultPromptTemplate)
    }

    @Test("PROMPT PROFILES lists available prompt presets")
    func promptProfilesListsAvailablePromptPresets() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("PROMPT PROFILES")

        #expect(host.output == ["classic", "plain", "shell"])
    }

    @Test("PROMPT PROFILE reports unknown profile names")
    func promptProfileReportsUnknownProfileNames() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("PROMPT PROFILE vaporwave")

        #expect(host.output == ["Runtime error: Unknown prompt profile vaporwave. Try: classic, plain, shell"])
    }

    @Test("Shell options default off and can be toggled from BASIC")
    func shellOptionsDefaultOffAndCanBeToggledFromBASIC() {
        let host = TestHost()
        let session = BASICSession(host: host)

        #expect(session.shellModeEnabled == false)
        #expect(session.stringSubstitutionEnabled == false)

        session.submit("OPTION SHELLMODE ON")
        session.submit("OPTION STRINGSUB ON")

        #expect(session.shellModeEnabled == true)
        #expect(session.stringSubstitutionEnabled == true)

        session.submit("OPTION SHELL-MODE OFF")
        session.submit("OPTION STRING-SUB OFF")

        #expect(session.shellModeEnabled == false)
        #expect(session.stringSubstitutionEnabled == false)
    }

    @Test("history command lists recent commands")
    func historyCommandListsRecentCommands() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.commandHistory = ["one", "two", "three", "four"]

        session.submit("history 2")
        #expect(host.output == ["3  three", "4  four"])

        host.output.removeAll()
        session.submit("history")
        #expect(host.output == ["1  one", "2  two", "3  three", "4  four"])
    }

    @Test("history command can delete and clear entries")
    func historyCommandCanDeleteAndClearEntries() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.commandHistory = ["one", "two", "three"]

        session.submit("history -d 2")
        #expect(host.commandHistory == ["one", "three"])

        session.submit("history -c")
        #expect(host.commandHistory.isEmpty)
    }

    @Test("history command can pipe output to external commands")
    func historyCommandCanPipeOutputToExternalCommands() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.commandHistory = ["one", "two", "three"]
        host.processResults["/bin/sh"] = BASICProcessResult(stdout: "2  two\n", stderr: "", exitCode: 0)

        session.submit("history | grep two")
        session.submit("PRINT STATUS")

        #expect(host.output == ["2  two\n0"])
        #expect(host.processRequests.count == 1)
        #expect(host.processRequests[0].executable == "/bin/sh")
        #expect(host.processRequests[0].arguments == ["-lc", "grep two"])
        #expect(host.processRequests[0].standardInput == "1  one\n2  two\n3  three\n")
    }

    @Test("Shell mode falls back to external commands after direct BASIC errors")
    func shellModeFallsBackToExternalCommandsAfterDirectBASICErrors() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.systemOutputs["git status"] = "On branch feature/shell\n"
        host.systemStatuses["git status"] = 3

        session.submit("git status")
        #expect(host.systemCommands == [])
        #expect(host.output == ["git status\n    ^\nSyntax error: Expected ="])

        host.output.removeAll()
        session.shellModeEnabled = true
        session.submit("git status")

        #expect(host.systemCommands == ["git status"])
        #expect(host.output == ["On branch feature/shell"])
        session.submit("PRINT STATUS")
        #expect(host.output == ["On branch feature/shell", "3"])

        session.submit("OPTION SHELLMODE OFF")
        host.output.removeAll()
        session.submit("git status")

        #expect(host.systemCommands == ["git status"])
        #expect(host.output == ["git status\n    ^\nSyntax error: Expected ="])
    }

    @Test("alias expands command words before direct execution")
    func aliasExpandsCommandWordsBeforeDirectExecution() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("alias hi='PRINT \"hello\"'")
        session.submit("hi")
        session.submit("alias hi")

        #expect(host.output == ["hello", "alias hi='PRINT \"hello\"'"])
    }

    @Test("alias expansion preserves trailing arguments for shell mode")
    func aliasExpansionPreservesTrailingArgumentsForShellMode() {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.shellModeEnabled = true
        host.systemOutputs["git status --short"] = " M file.bas\n"

        session.submit("alias gs='git status'")
        session.submit("gs --short")

        #expect(host.systemCommands == ["git status --short"])
        #expect(host.output == [" M file.bas"])
    }

    @Test("alias lists removes and clears aliases")
    func aliasListsRemovesAndClearsAliases() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("alias ll='ls -la'")
        session.submit("alias gs='git status'")
        session.submit("alias")
        #expect(host.output == ["alias gs='git status'", "alias ll='ls -la'"])

        host.output.removeAll()
        session.submit("unalias gs")
        session.submit("alias")
        #expect(host.output == ["alias ll='ls -la'"])

        host.output.removeAll()
        session.submit("unalias -a")
        session.submit("alias")
        #expect(host.output.isEmpty)
    }

    @Test("direct mode collects multi-line blocks before execution")
    func directModeCollectsMultilineBlocksBeforeExecution() {
        let host = TestHost()
        let session = BASICSession(host: host, promptTemplate: "READY> ")

        session.submit("for i = 1 to 3")
        #expect(session.prompt == "   ... ")
        #expect(host.output.isEmpty)

        session.submit("print i")
        #expect(session.prompt == "   ... ")
        #expect(host.output.isEmpty)

        session.submit("next i")
        #expect(session.prompt == "READY> ")
        #expect(host.output == ["1", "2", "3"])
    }

    @Test("direct mode multi-line functions can be defined and called")
    func directModeMultilineFunctionsCanBeDefinedAndCalled() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("function Twice(value as integer) as integer")
        session.submit("Twice = value * 2")
        session.submit("end function: print Twice(21)")

        #expect(host.output == ["42"])
    }

    @Test("direct mode multi-line input can be cancelled")
    func directModeMultilineInputCanBeCancelled() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("if 1 then")
        #expect(session.prompt.hasSuffix(BASICSession.continuationPrompt))
        session.submit(".")
        #expect(!session.prompt.hasSuffix(BASICSession.continuationPrompt))

        session.submit("print \"after\"")
        #expect(host.output == ["after"])
    }

    @Test("Shell mode passes Unix pipes and redirection syntax to the system shell")
    func shellModePassesUnixPipesAndRedirectionSyntaxToTheSystemShell() {
        let host = TestHost()
        let session = BASICSession(host: host)
        let command = "printf alpha | tr a-z A-Z > out.txt 2> err.txt"
        host.systemStatuses[command] = 0

        session.shellModeEnabled = true
        session.submit(command)

        #expect(host.systemCommands == [command])
        #expect(host.output == [])
        session.submit("PRINT STATUS")
        #expect(host.output == ["0"])
    }

    @Test("Shell mode can run fallback commands on inherited terminal hosts")
    func shellModeCanRunFallbackCommandsOnInheritedTerminalHosts() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.currentDirectory = "/tmp/project"
        host.columns = 100
        host.rows = 33
        host.supportsForegroundTTYProcesses = true
        host.processResults["/bin/sh"] = BASICProcessResult(stdout: "", stderr: "", exitCode: 5)

        session.shellModeEnabled = true
        session.submit("git status")
        session.submit("PRINT STATUS")

        #expect(host.systemCommands.isEmpty)
        #expect(host.processRequests.count == 1)
        #expect(host.processRequests[0].executable == "/bin/sh")
        #expect(host.processRequests[0].arguments == ["-lc", "git status"])
        #expect(host.processRequests[0].workingDirectory == "/tmp/project")
        #expect(host.processRequests[0].columns == 100)
        #expect(host.processRequests[0].rows == 33)
        #expect(host.processRequests[0].ioMode == .inheritedTerminal)
        #expect(host.output == ["5"])
    }

    @Test("PWD exposes current directory as command and expression")
    func pwdExposesCurrentDirectoryAsCommandAndExpression() {
        let host = TestHost()
        host.currentDirectory = "work"
        let session = BASICSession(host: host)

        session.submit("PWD")
        session.submit("PRINT PWD$")

        #expect(host.output == ["work", "work"])
    }

    @Test("Environment options affect ENVIRON and child commands")
    func environmentOptionsAffectEnvironAndChildCommands() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.systemOutputs["env-check"] = "ok\n"

        session.submit("SETENV \"BASICSHELL_TEST\", \"alpha\"")
        session.submit("PRINT ENVIRON$(\"BASICSHELL_TEST\")")
        session.submit("SYSTEM \"env-check\"")

        #expect(host.output == ["alpha", "ok\n"])
        #expect(host.systemEnvironmentPatches.last?.values["BASICSHELL_TEST"] == "alpha")
        #expect(host.systemEnvironmentPatches.last?.removals.contains("BASICSHELL_TEST") == false)

        session.submit("UNSETENV \"BASICSHELL_TEST\"")
        session.submit("PRINT \"[\" + ENVIRON$(\"BASICSHELL_TEST\") + \"]\"")
        session.submit("SYSTEM \"env-check\"")

        #expect(host.output == ["alpha", "ok\n[]", "ok\n"])
        #expect(host.systemEnvironmentPatches.last?.values["BASICSHELL_TEST"] == nil)
        #expect(host.systemEnvironmentPatches.last?.removals.contains("BASICSHELL_TEST") == true)
    }

    @Test("EXPORT publishes BASIC scalar values as child environment strings")
    func exportPublishesBASICScalarValuesAsChildEnvironmentStrings() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.systemOutputs["env-check"] = "ok\n"

        session.submit("LET TITLE$ = \"BASICShell\"")
        session.submit("LET COUNT% = 42")
        session.submit("EXPORT TITLE$")
        session.submit("EXPORT COUNT%")
        session.submit("EXPORT DIRECT=plain")
        session.submit("SYSTEM \"env-check\"")

        let patch = host.systemEnvironmentPatches.last
        #expect(patch?.values["TITLE"] == "BASICShell")
        #expect(patch?.values["COUNT"] == "42")
        #expect(patch?.values["DIRECT"] == "plain")
    }

    @Test("WHICH and TYPE resolve commands and update STATUS")
    func whichAndTypeResolveCommandsAndUpdateStatus() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.executablePaths["swift"] = "/usr/bin/swift"

        session.submit("which swift")
        session.submit("PRINT STATUS")
        session.submit("type cd")
        session.submit("type missing")
        session.submit("PRINT ERRORLEVEL")

        #expect(host.output == [
            "/usr/bin/swift",
            "0",
            "cd is a BASICShell builtin",
            "missing not found",
            "1"
        ])
    }

    @Test("EXPORT and WHICH can run inside BASIC programs")
    func exportAndWhichCanRunInsideBASICPrograms() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.executablePaths["swift"] = "/usr/bin/swift"
        host.systemOutputs["env-check"] = "ok\n"

        session.program.loadSource("""
        let title$ = "Program"
        export title$
        which "swift"
        system "env-check"
        """)
        session.submit("run")

        #expect(host.output == ["/usr/bin/swift", "ok\n"])
        #expect(host.systemEnvironmentPatches.last?.values["TITLE"] == "Program")
    }

    @Test("PUSHD POPD and DIRS maintain a session directory stack")
    func pushdPopdAndDirsMaintainSessionDirectoryStack() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.currentDirectory = "/tmp/home"

        session.submit("pushd /tmp/work")
        session.submit("pushd /tmp/project")
        session.submit("dirs")
        session.submit("popd")
        session.submit("popd")

        #expect(host.currentDirectory == "/tmp/home")
        #expect(host.output == [
            "/tmp/work /tmp/home",
            "/tmp/project /tmp/work /tmp/home",
            "/tmp/project /tmp/work /tmp/home",
            "/tmp/work /tmp/home",
            "/tmp/home"
        ])
    }

    @Test("SYSTEM records status and errorlevel")
    func systemRecordsStatusAndErrorlevel() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.systemStatuses["fail-ish"] = 17

        session.submit("SYSTEM \"fail-ish\"")
        session.submit("PRINT STATUS")
        session.submit("PRINT ERRORLEVEL")

        #expect(host.systemCommands == ["fail-ish"])
        #expect(host.output == ["17", "17"])
    }

    @Test("EXEC runs structured argv processes and records output status")
    func execRunsStructuredArgvProcessesAndRecordsOutputStatus() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.currentDirectory = "/tmp/project"
        host.columns = 120
        host.rows = 40
        host.processResults["tool"] = BASICProcessResult(
            stdout: "out\n",
            stderr: "err\n",
            exitCode: 9
        )

        session.submit("LET TOKEN$ = \"abc\"")
        session.submit("EXPORT TOKEN$")
        session.submit("EXEC \"tool\", \"one two\", \"three\"")
        session.submit("PRINT STATUS")

        #expect(host.output == ["out\nerr\n9"])
        #expect(host.processRequests.count == 1)
        #expect(host.processRequests[0].executable == "tool")
        #expect(host.processRequests[0].arguments == ["one two", "three"])
        #expect(host.processRequests[0].workingDirectory == "/tmp/project")
        #expect(host.processRequests[0].columns == 120)
        #expect(host.processRequests[0].rows == 40)
        #expect(host.processRequests[0].environment.values["TOKEN"] == "abc")
    }

    @Test("EXEC captures stdout and stderr into BASIC variables")
    func execCapturesStdoutAndStderrIntoBasicVariables() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.processResults["tool"] = BASICProcessResult(
            stdout: "out\n",
            stderr: "err\n",
            exitCode: 3
        )

        session.submit("EXEC \"tool\", \"arg\" TO out$ ERRORS TO err$")
        session.submit("PRINT out$; err$; STATUS")

        #expect(host.output == ["out\nerr\n3"])
        #expect(host.processRequests.count == 1)
        #expect(host.processRequests[0].executable == "tool")
        #expect(host.processRequests[0].arguments == ["arg"])
    }

    @Test("EXEC command string runs through the shell and captures streams")
    func execCommandStringRunsThroughTheShellAndCapturesStreams() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.processResults["/bin/sh"] = BASICProcessResult(
            stdout: "out\n",
            stderr: "err\n",
            exitCode: 7
        )

        session.submit("EXEC \"printf out; printf err >&2\" TO out$ ERRORS TO err$")
        session.submit("PRINT out$; err$; STATUS")

        #expect(host.output == ["out\nerr\n7"])
        #expect(host.processRequests.count == 1)
        #expect(host.processRequests[0].executable == "/bin/sh")
        #expect(host.processRequests[0].arguments == ["-lc", "printf out; printf err >&2"])
    }

    @Test("EXEC TTY TRUE requests inherited terminal process mode")
    func execTTYTrueRequestsInheritedTerminalProcessMode() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.processResults["top"] = BASICProcessResult(stdout: "", stderr: "", exitCode: 0)

        session.submit("EXEC \"top\" TTY TRUE")
        session.submit("PRINT STATUS")

        #expect(host.output == ["0"])
        #expect(host.processRequests.count == 1)
        #expect(host.processRequests[0].executable == "/bin/sh")
        #expect(host.processRequests[0].arguments == ["-lc", "top"])
        #expect(host.processRequests[0].ioMode == .inheritedTerminal)
    }

    @Test("EXEC argv form can request inherited terminal process mode")
    func execArgvFormCanRequestInheritedTerminalProcessMode() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.processResults["top"] = BASICProcessResult(stdout: "", stderr: "", exitCode: 0)

        session.submit("EXEC \"top\", \"-l\", \"1\" TTY TRUE")

        #expect(host.processRequests.count == 1)
        #expect(host.processRequests[0].executable == "top")
        #expect(host.processRequests[0].arguments == ["-l", "1"])
        #expect(host.processRequests[0].ioMode == .inheritedTerminal)
    }

    @Test("EXEC TIMEOUT passes a timeout to the process host")
    func execTimeoutPassesATimeoutToTheProcessHost() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.processResults["tool"] = BASICProcessResult(stdout: "done\n", stderr: "", exitCode: 0)

        session.submit("EXEC \"tool\", \"arg\" TIMEOUT 1.5")

        #expect(host.output == ["done\n"])
        #expect(host.processRequests.count == 1)
        #expect(host.processRequests[0].timeoutSeconds == 1.5)
    }

    @Test("EXEC TIMEOUT rejects non-positive values")
    func execTimeoutRejectsNonPositiveValues() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("EXEC \"tool\" TIMEOUT 0")

        #expect(host.processRequests.isEmpty)
        #expect(host.output.first?.contains("EXEC TIMEOUT must be greater than zero") == true)
    }

    @Test("EXEC TTY TRUE rejects captured stream targets")
    func execTTYTrueRejectsCapturedStreamTargets() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("EXEC \"top\" TTY TRUE TO out$")

        #expect(host.processRequests.isEmpty)
        #expect(host.output.first?.contains("EXEC TTY TRUE cannot capture stdout or stderr") == true)
    }

    @Test("EXEC rejects file-path style TO targets")
    func execRejectsFilePathStyleToTargets() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.submit("EXEC \"tool\" TO \"stdout.txt\"")

        #expect(host.processRequests.isEmpty)
        #expect(host.output.first?.contains("Syntax error") == true)
    }

    @Test("PIPE runs structured pipeline stages and records output status")
    func pipeRunsStructuredPipelineStagesAndRecordsOutputStatus() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.currentDirectory = "/tmp/project"
        host.columns = 132
        host.rows = 44
        host.pipelineResult = BASICProcessResult(
            stdout: "ALPHA\n",
            stderr: "warn\n",
            exitCode: 4
        )

        session.submit("LET TOKEN$ = \"abc\"")
        session.submit("EXPORT TOKEN$")
        session.submit("PIPE \"printf\", \"alpha\" TO \"tr\", \"a-z\", \"A-Z\"")
        session.submit("PRINT STATUS")

        #expect(host.output == ["ALPHA\nwarn\n4"])
        #expect(host.pipelineRequests.count == 1)
        #expect(host.pipelineRequests[0].count == 2)
        #expect(host.pipelineRequests[0][0].executable == "printf")
        #expect(host.pipelineRequests[0][0].arguments == ["alpha"])
        #expect(host.pipelineRequests[0][0].workingDirectory == "/tmp/project")
        #expect(host.pipelineRequests[0][0].columns == 132)
        #expect(host.pipelineRequests[0][0].rows == 44)
        #expect(host.pipelineRequests[0][0].environment.values["TOKEN"] == "abc")
        #expect(host.pipelineRequests[0][1].executable == "tr")
        #expect(host.pipelineRequests[0][1].arguments == ["a-z", "A-Z"])
    }

    @Test("PIPE can feed BASIC string input into a process")
    func pipeCanFeedBasicStringInputIntoProcess() {
        let host = TestHost()
        let session = BASICSession(host: host)
        host.pipelineResult = BASICProcessResult(
            stdout: "BETA\nALPHA\n",
            stderr: "",
            exitCode: 0
        )

        session.submit("LET PAYLOAD$ = \"beta\" + CHR$(10) + \"alpha\" + CHR$(10)")
        session.submit("PIPE PAYLOAD$ TO \"sort\"")

        #expect(host.output == ["BETA\nALPHA\n"])
        #expect(host.pipelineRequests.count == 1)
        #expect(host.pipelineRequests[0].count == 1)
        #expect(host.pipelineRequests[0][0].executable == "sort")
        #expect(host.pipelineRequests[0][0].standardInput == "beta\nalpha\n")
    }

    @Test("Default process runner wires structured pipelines")
    func defaultProcessRunnerWiresStructuredPipelines() throws {
        let result = try BASICSystemCommand.runPipeline([
            BASICProcessRequest(executable: "/bin/echo", arguments: ["alpha"], workingDirectory: nil, columns: nil, rows: nil),
            BASICProcessRequest(executable: "/usr/bin/tr", arguments: ["a-z", "A-Z"], workingDirectory: nil, columns: nil, rows: nil)
        ])

        #expect(result.stdout == "ALPHA\n")
        #expect(result.stderr == "")
        #expect(result.exitCode == 0)
    }

    @Test("Default process runner feeds standard input into pipelines")
    func defaultProcessRunnerFeedsStandardInputIntoPipelines() throws {
        let result = try BASICSystemCommand.runPipeline([
            BASICProcessRequest(executable: "/usr/bin/sort", standardInput: "beta\nalpha\n")
        ])

        #expect(result.stdout == "alpha\nbeta\n")
        #expect(result.stderr == "")
        #expect(result.exitCode == 0)
    }

    @Test("Default process runner reports foreground process lifecycle")
    func defaultProcessRunnerReportsForegroundProcessLifecycle() throws {
        let observer = ProcessObserverProbe()
        let result = try BASICSystemCommand.runProcess(
            BASICProcessRequest(executable: "/bin/echo", arguments: ["observer"]),
            observer: observer
        )

        #expect(result.stdout == "observer\n")
        #expect(result.stderr == "")
        #expect(result.exitCode == 0)
        #expect(observer.started.count == 1)
        #expect(observer.ended == observer.started)
        #expect(observer.started[0].processID > 0)
        #expect(observer.started[0].processGroupID > 0)
        #expect(observer.started[0].command == "/bin/echo observer")
    }

    @Test("Default process runner reports pipeline lifecycle")
    func defaultProcessRunnerReportsPipelineLifecycle() throws {
        let observer = ProcessObserverProbe()
        let result = try BASICSystemCommand.runPipeline([
            BASICProcessRequest(executable: "/bin/echo", arguments: ["alpha"], workingDirectory: nil, columns: nil, rows: nil),
            BASICProcessRequest(executable: "/usr/bin/tr", arguments: ["a-z", "A-Z"], workingDirectory: nil, columns: nil, rows: nil)
        ], observer: observer)

        #expect(result.stdout == "ALPHA\n")
        #expect(result.stderr == "")
        #expect(result.exitCode == 0)
        #expect(observer.started.count == 1)
        #expect(observer.ended == observer.started)
        #expect(observer.started[0].processID > 0)
        #expect(observer.started[0].processGroupID > 0)
        #expect(observer.started[0].command == "/bin/echo alpha | /usr/bin/tr a-z A-Z")
    }

    @Test("Default process runner terminates timed out processes")
    func defaultProcessRunnerTerminatesTimedOutProcesses() throws {
        let result = try BASICSystemCommand.runProcess(
            BASICProcessRequest(executable: "/bin/sleep", arguments: ["2"], timeoutSeconds: 0.05)
        )

        #expect(result.stdout == "")
        #expect(result.stderr.contains("Process timed out after 0.05 seconds"))
        #expect(result.exitCode == 124)
    }

    @Test("EXIT and QUIT direct commands can request process status")
    func exitAndQuitDirectCommandsCanRequestProcessStatus() {
        let host = TestHost()
        let session = BASICSession(host: host)

        #expect(session.submit("EXIT") == false)
        #expect(session.requestedExitStatus == 0)

        #expect(session.submit("QUIT 7") == false)
        #expect(session.requestedExitStatus == 7)

        host.systemStatuses["fail-ish"] = 23
        session.submit("SYSTEM \"fail-ish\"")
        #expect(session.submit("EXIT STATUS") == false)
        #expect(session.requestedExitStatus == 23)

        #expect(session.submit("QUIT ERRORLEVEL") == false)
        #expect(session.requestedExitStatus == 23)
    }

    @Test("EXIT status validates shell exit code range")
    func exitStatusValidatesShellExitCodeRange() {
        let host = TestHost()
        let session = BASICSession(host: host)

        #expect(session.submit("EXIT 999") == true)
        #expect(host.output == ["Runtime error: Exit status must be between 0 and 255"])
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

    @Test("Execution control can target stepping to a logical task")
    func executionControlCanTargetSteppingToLogicalTask() throws {
        let host = TestHost()
        let control = BASICExecutionControl()
        control.setMode(.stepInto)
        control.setTargetTaskID(999)
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "one"
        print "two"
        """)

        try session.runProgram(executionControl: control)

        #expect(host.output == ["one", "two"])
        #expect(session.debugTasks.first?.state == .completed)
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
        circle (10,11), 5, 4
        paint (1,1), 5, 3
        pset (20,20), 4
        draw "R5D5L5U5"
        """)
        session.submit("run")

        #expect(host.screenMode?.number == 1)
        #expect(host.screenMode?.width == 0)
        #expect(host.screenMode?.height == 0)
        #expect(host.output == ["2", "0"])
        #expect(host.lines.count == 5)
        #expect(host.lines.first?.0 == 0)
        #expect(host.lines.first?.1 == 0)
        #expect(host.lines.first?.2 == 4)
        #expect(host.lines.first?.3 == 4)
        #expect(host.lines.first?.4 == 3)
        #expect(host.lines[1].0 == 20)
        #expect(host.lines[1].1 == 20)
        #expect(host.lines[1].2 == 25)
        #expect(host.lines[1].3 == 20)
        #expect(host.lines[4].0 == 20)
        #expect(host.lines[4].1 == 25)
        #expect(host.lines[4].2 == 20)
        #expect(host.lines[4].3 == 20)
        #expect(host.circles.count == 1)
        #expect(host.circles.first?.0 == 10)
        #expect(host.circles.first?.1 == 11)
        #expect(host.circles.first?.2 == 5)
        #expect(host.circles.first?.3 == 4)
        #expect(host.fills.count == 1)
        #expect(host.fills.first?.0 == 1)
        #expect(host.fills.first?.1 == 1)
        #expect(host.fills.first?.2 == 5)
        #expect(host.fills.first?.3 == 3)
    }

    @Test("SCREEN is native-canvas compatibility input")
    func screenIsNativeCanvasCompatibilityInput() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        screen 1
        pset (2,3), 4
        screen 2
        print point(2,3)
        """)
        session.submit("run")

        #expect(host.screenMode?.number == 2)
        #expect(host.screenMode?.width == 0)
        #expect(host.screenMode?.height == 0)
        #expect(host.screenMode?.colorCount == 0)
        #expect(host.output == ["4"])
    }

    @Test("CIRCLE aspect draws VTG ellipse primitive")
    func circleAspectDrawsEllipsePrimitive() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        screen 1
        circle (30,31), 10, 6, 0.5
        circle (40,41), 10, 7, 2
        """)
        session.submit("run")

        #expect(host.circles.isEmpty)
        #expect(host.ellipses.count == 2)
        #expect(host.ellipses[0].0 == 30)
        #expect(host.ellipses[0].1 == 31)
        #expect(host.ellipses[0].2 == 10)
        #expect(host.ellipses[0].3 == 5)
        #expect(host.ellipses[0].4 == 6)
        #expect(host.ellipses[1].0 == 40)
        #expect(host.ellipses[1].1 == 41)
        #expect(host.ellipses[1].2 == 5)
        #expect(host.ellipses[1].3 == 10)
        #expect(host.ellipses[1].4 == 7)
    }

    @Test("CIRCLE aspect must be positive")
    func circleAspectMustBePositive() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        screen 1
        circle (30,31), 10, 6, 0
        """)
        session.submit("run")

        #expect(host.output == ["Runtime error: CIRCLE aspect must be greater than zero"])
    }

    @Test("COLOR supplies default graphics foreground")
    func colorSuppliesDefaultGraphicsForeground() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        screen 1
        color 2
        pset (2,3)
        line (0,0)-(4,4)
        circle (10,11), 5
        paint (1,1), 2
        pset (20,20)
        draw "R5"
        """)
        session.submit("run")

        #expect(host.graphicsColor == 2)
        #expect(host.pixels["2,3"] == 2)
        #expect(host.lines.first?.4 == 2)
        #expect(host.lines.last?.4 == 2)
        #expect(host.circles.first?.3 == 2)
        #expect(host.fills.first?.2 == 2)
    }

    @Test("Graphics batcher groups points into horizontal runs")
    func graphicsBatcherGroupsPointsIntoHorizontalRuns() {
        let runs = BASICGraphicsBatcher.horizontalRuns(from: [
            BASICGraphicsPoint(x: 3, y: 2),
            BASICGraphicsPoint(x: 1, y: 1),
            BASICGraphicsPoint(x: 2, y: 1),
            BASICGraphicsPoint(x: 2, y: 1),
            BASICGraphicsPoint(x: 5, y: 1),
            BASICGraphicsPoint(x: 4, y: 1),
            BASICGraphicsPoint(x: 1, y: 3)
        ])

        #expect(runs == [
            BASICGraphicsHorizontalRun(x1: 1, x2: 2, y: 1),
            BASICGraphicsHorizontalRun(x1: 4, x2: 5, y: 1),
            BASICGraphicsHorizontalRun(x1: 3, x2: 3, y: 2),
            BASICGraphicsHorizontalRun(x1: 1, x2: 1, y: 3)
        ])
    }

    @Test("DRAW supports motion strings and inline palette color changes")
    func drawSupportsMotionStringsAndInlineColorChanges() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        screen 1
        pset (10,10), 1
        draw "C3R4D2BL2NUL1M20,20M+5,+0"
        """)
        session.submit("run")

        #expect(host.lines.count == 6)
        #expect(host.lines[0].0 == 10)
        #expect(host.lines[0].1 == 10)
        #expect(host.lines[0].2 == 14)
        #expect(host.lines[0].3 == 10)
        #expect(host.lines[0].4 == 3)
        #expect(host.lines[1].2 == 14)
        #expect(host.lines[1].3 == 12)
        #expect(host.lines[2].0 == 12)
        #expect(host.lines[2].1 == 12)
        #expect(host.lines[2].2 == 12)
        #expect(host.lines[2].3 == 11)
        #expect(host.lines[3].0 == 12)
        #expect(host.lines[3].1 == 12)
        #expect(host.lines[3].2 == 11)
        #expect(host.lines[3].3 == 12)
        #expect(host.lines[4].0 == 11)
        #expect(host.lines[4].1 == 12)
        #expect(host.lines[4].2 == 20)
        #expect(host.lines[4].3 == 20)
        #expect(host.lines[5].0 == 20)
        #expect(host.lines[5].1 == 20)
        #expect(host.lines[5].2 == 25)
        #expect(host.lines[5].3 == 20)
        #expect(host.graphicsColor == 3)
        #expect(host.paths.count == 3)
        #expect(host.paths[0].points == [
            BASICGraphicsPoint(x: 10, y: 10),
            BASICGraphicsPoint(x: 14, y: 10),
            BASICGraphicsPoint(x: 14, y: 12)
        ])
        #expect(host.paths[1].points == [
            BASICGraphicsPoint(x: 12, y: 12),
            BASICGraphicsPoint(x: 12, y: 11)
        ])
        #expect(host.paths[2].points == [
            BASICGraphicsPoint(x: 12, y: 12),
            BASICGraphicsPoint(x: 11, y: 12),
            BASICGraphicsPoint(x: 20, y: 20),
            BASICGraphicsPoint(x: 25, y: 20)
        ])
    }

    @Test("DRAW supports scale and quarter-turn angle commands")
    func drawSupportsScaleAndQuarterTurnAngleCommands() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        screen 1
        pset (10,10), 1
        draw "S8R2A1R2A2R2A3R2A0S2D4"
        """)
        session.submit("run")

        #expect(host.lines.count == 5)
        #expect(host.lines[0].0 == 10)
        #expect(host.lines[0].1 == 10)
        #expect(host.lines[0].2 == 14)
        #expect(host.lines[0].3 == 10)
        #expect(host.lines[1].0 == 14)
        #expect(host.lines[1].1 == 10)
        #expect(host.lines[1].2 == 14)
        #expect(host.lines[1].3 == 6)
        #expect(host.lines[2].0 == 14)
        #expect(host.lines[2].1 == 6)
        #expect(host.lines[2].2 == 10)
        #expect(host.lines[2].3 == 6)
        #expect(host.lines[3].0 == 10)
        #expect(host.lines[3].1 == 6)
        #expect(host.lines[3].2 == 10)
        #expect(host.lines[3].3 == 10)
        #expect(host.lines[4].0 == 10)
        #expect(host.lines[4].1 == 10)
        #expect(host.lines[4].2 == 10)
        #expect(host.lines[4].3 == 12)
    }

    @Test("DRAW validates scale and angle commands")
    func drawValidatesScaleAndAngleCommands() {
        let zeroScaleHost = TestHost()
        let zeroScaleSession = BASICSession(host: zeroScaleHost)

        zeroScaleSession.program.loadSource("""
        screen 1
        draw "S0R1"
        """)
        zeroScaleSession.submit("run")

        #expect(zeroScaleHost.output == ["Runtime error: DRAW scale must be greater than zero"])

        let badAngleHost = TestHost()
        let badAngleSession = BASICSession(host: badAngleHost)

        badAngleSession.program.loadSource("""
        screen 1
        draw "A4R1"
        """)
        badAngleSession.submit("run")

        #expect(badAngleHost.output == ["Runtime error: DRAW angle must be 0, 1, 2, or 3"])
    }

    @Test("COLOR accepts text background")
    func colorAcceptsTextBackground() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        color 2, 0
        print "GREEN ON BLACK"
        """)
        session.submit("run")

        #expect(host.output == ["\u{001B}[38;2;34;197;94;48;2;0;0;0mGREEN ON BLACK"])
    }

    @Test("COLOR accepts quoted full color strings")
    func colorAcceptsQuotedFullColorStrings() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        color "orange,alpha: 50%", "000000"
        print "TRANSLUCENT ORANGE"
        screen 1
        pset (2,3)
        line (0,0)-(4,4), "255,0,0,128"
        """)
        session.submit("run")

        #expect(host.output == ["\u{001B}[38;2;255;165;0;48;2;0;0;0mTRANSLUCENT ORANGE"])
        #expect(host.fullGraphicsColor?.cssHex == "#ffa50080")
        #expect(host.fullPixels["2,3"]?.cssHex == "#ffa50080")
        #expect(host.fullLines.first?.4.cssHex == "#ff000080")
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

    @Test("Implicit array declaration creates default dimensions")
    func implicitArrayDeclarationCreatesDefaultDimensions() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        scores(10) = 42
        print scores(10)
        print scores(0)
        names$(1) = "Ada"
        print names$(1)
        grid(2,3) = 23
        print grid(2,3)
        print len(scores)
        """)
        session.submit("run")

        #expect(host.output == ["42", "0", "Ada", "23", "11"])
    }

    @Test("Implicit array declaration enforces default upper bound")
    func implicitArrayDeclarationEnforcesDefaultUpperBound() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        scores(11) = 42
        """)
        session.submit("run")

        #expect(host.output == ["Runtime error: scores subscript out of range"])
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

    @Test("REFLECT returns metadata and system tags for record fields")
    func reflectReturnsMetadataAndSystemTagsForRecordFields() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        type StoreInfo
            Name as string json name "name" meta { label: "Store name", width: 40, required: true, "display-key": "store.name" }
            TaxRate as double meta { decimals: 3 }
        end type
        dim store as StoreInfo
        meta = reflect(store.Name)
        print meta("name")
        print meta("type")
        print meta("parent")
        print meta("path")
        print meta("label")
        print meta("width")
        print meta("required")
        print meta("display-key")
        """)
        session.submit("run")

        #expect(host.output == [
            "Name",
            "STRING",
            "store",
            "store.Name",
            "Store name",
            "40",
            "TRUE",
            "store.name"
        ])
    }

    @Test("REFLECT returns non-empty metadata for scalars and indexed variables")
    func reflectReturnsNonEmptyMetadataForScalarsAndIndexedVariables() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        count% = 7
        dim scores(2) as integer
        scalarMeta = reflect(count%)
        indexedMeta = reflect(scores(1))
        arrayMeta = reflect(scores)
        print scalarMeta("name")
        print scalarMeta("type")
        print indexedMeta("name")
        print indexedMeta("type")
        print indexedMeta("index")
        print arrayMeta("type")
        """)
        session.submit("run")

        #expect(host.output == [
            "count%",
            "INTEGER",
            "scores",
            "INTEGER",
            "(1)",
            "ARRAY OF INTEGER"
        ])
    }

    @Test("Reflection field helpers enumerate and edit record fields")
    func reflectionFieldHelpersEnumerateAndEditRecordFields() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        type Part
            Sku as string meta { label: "SKU" }
            Price as double meta { label: "Price" }
        end type
        dim part as Part
        part.Sku = "ABC"
        part.Price = 1.25
        print fieldcount(part)
        print fieldname$(part, 0)
        meta = fieldmeta(part, "Sku")
        print meta("label")
        print fieldvalue$(part, "Price")
        part = setfield(part, "Price", "2.5")
        print part.Price
        """)
        session.submit("run")

        #expect(host.output == [
            "2",
            "Sku",
            "SKU",
            "1.25",
            "2.5"
        ])
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

    @Test("TASKS commands report logical task status")
    func tasksCommandsReportLogicalTaskStatus() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print "task body"
        """)
        session.submit("run")
        session.submit("tasks")
        session.submit("task 1")

        let output = host.output.joined(separator: "\n")
        #expect(output.contains("task body"))
        #expect(output.contains("Tasks:"))
        #expect(output.contains("#1 COMPLETED Program"))
        #expect(output.contains("yields=0"))
    }

    @Test("BASIC worker lane rejects overlapping work")
    func basicWorkerLaneRejectsOverlappingWork() {
        let lane = BASICWorkerLane(label: "AIBasicTests.WorkerLane.Overlap")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)

        #expect(lane.submit {
            started.signal()
            _ = release.wait(timeout: .now() + 2)
            finished.signal()
        })
        #expect(started.wait(timeout: .now() + 2) == .success)
        #expect(lane.isRunning)
        #expect(!lane.submit {})

        release.signal()
        #expect(finished.wait(timeout: .now() + 2) == .success)
    }

    @Test("BASIC worker lane runs session programs asynchronously")
    func basicWorkerLaneRunsSessionProgramsAsynchronously() {
        let host = TestHost()
        let session = BASICSession(host: host)
        let lane = BASICWorkerLane(label: "AIBasicTests.WorkerLane.Session")
        let resultBox = ThreadSafeValueBox<BASICWorkerLaneRunResult>()
        let finished = DispatchSemaphore(value: 0)

        session.program.loadSource("""
        print "worker lane"
        """)

        #expect(session.runProgram(on: lane) { result in
            resultBox.store(result)
            finished.signal()
        })

        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(resultBox.value == .success)
        #expect(host.output == ["worker lane"])
        #expect(!lane.isRunning)
    }

    @Test("Foreground RUN commands can use a worker lane synchronously")
    func foregroundRunCommandsCanUseWorkerLaneSynchronously() {
        let host = TestHost()
        let session = BASICSession(host: host)
        let lane = BASICWorkerLane(label: "AIBasicTests.WorkerLane.Foreground")
        session.foregroundRunLane = lane

        session.program.loadSource("""
        print "foreground lane"
        """)
        session.submit("RUN")

        #expect(host.output == ["foreground lane"])
        #expect(!lane.isRunning)
        #expect(session.debugTasks.first?.state == .completed)
    }

    @Test("BASIC event loop runs callbacks in FIFO order")
    func basicEventLoopRunsCallbacksInFIFOOrder() {
        let eventLoop = BASICEventLoop()
        let log = ThreadSafeStringLog()

        eventLoop.post { log.append("first") }
        eventLoop.post { log.append("second") }

        #expect(eventLoop.pendingCount == 2)
        #expect(eventLoop.runUntilIdle() == 2)
        #expect(log.snapshot == ["first", "second"])
        #expect(eventLoop.isEmpty)
    }

    @Test("BASIC event loop drains callbacks posted by callbacks")
    func basicEventLoopDrainsCallbacksPostedByCallbacks() {
        let eventLoop = BASICEventLoop()
        let log = ThreadSafeStringLog()

        eventLoop.post {
            log.append("outer")
            eventLoop.post { log.append("inner") }
        }

        #expect(eventLoop.runUntilIdle() == 2)
        #expect(log.snapshot == ["outer", "inner"])
        #expect(eventLoop.isEmpty)
    }

    @Test("BASIC session owns a host event loop")
    func basicSessionOwnsHostEventLoop() {
        let host = TestHost()
        let session = BASICSession(host: host)
        let log = ThreadSafeStringLog()

        session.eventLoop.post { log.append("session event") }

        #expect(session.eventLoop.runUntilIdle() == 1)
        #expect(log.snapshot == ["session event"])
    }

    @Test("CURRENT pseudo variables expose execution context")
    func currentPseudoVariablesExposeExecutionContext() {
        let host = TestHost()
        let session = BASICSession(host: host)

        session.program.loadSource("""
        print CURRENT_TASK$
        print CURRENT_FUNCTION$
        print ContextName$()
        print CURRENT_FUNCTION$
        function ContextName$() as string
            print CURRENT_FUNCTION$
            return CURRENT_THREAD$
        end function
        """)
        session.submit("RUN")

        #expect(host.output.count == 5)
        guard host.output.count == 5 else { return }
        #expect(host.output[0].contains("Program"))
        #expect(host.output[1] == "[main]")
        #expect(host.output[2].uppercased().contains("CONTEXTNAME"))
        #expect(!host.output[3].isEmpty)
        #expect(host.output[4] == "[main]")
    }
}

private final class TestHost: BASICFileHost, BASICNetworkHost, BASICGraphicsHost, BASICSystemHost, BASICProcessHost, BASICForegroundTTYProcessHost, BASICExecutableResolverHost, BASICCommandHistoryHost, BASICBlockingKeyboardHost, BASICConsoleHost, BASICConfiguredLineInputHost, BASICLoggingHost {
    var output: [String] = []
    var pendingOutput = ""
    var hasPendingUnterminatedOutput = false
    var logs: [(level: String, issuer: String, module: String, text: String)] = []
    var isBASICLoggingEnabled = true
    var input: [String] = []
    var lineInputResults: [BASICLineInputResult] = []
    var lineInputOptions: [BASICLineInputOptions] = []
    var keys: [String] = []
    var commandHistory: [String] = []
    var files: [String: String] = [:]
    var fileData: [String: Data] = [:]
    var deniedFilePaths: Set<String> = []
    var directories: Set<String> = ["."]
    var httpRequests: [String] = []
    var httpResponses: [String: BASICHTTPResponse] = [:]
    var httpErrors: [String: String] = [:]
    var currentDirectory = "."
    var systemCommands: [String] = []
    var systemOutputs: [String: String] = [:]
    var systemStatuses: [String: Int] = [:]
    var systemEnvironmentPatches: [BASICEnvironmentPatch] = []
    var executablePaths: [String: String] = [:]
    var processRequests: [BASICProcessRequest] = []
    var processResults: [String: BASICProcessResult] = [:]
    var pipelineRequests: [[BASICProcessRequest]] = []
    var pipelineResult = BASICProcessResult(stdout: "", stderr: "", exitCode: 0)
    var supportsForegroundTTYProcesses = false
    var breakAfterOutputCount: Int?
    var breakOnBlockingKeyRead = false
    weak var executionControl: BASICExecutionControl?
    var screenMode: BASICScreenMode?
    var columns = 80
    var rows = 25
    var locations: [(Int, Int)] = []
    var pixels: [String: Int] = [:]
    var lines: [(Int, Int, Int, Int, Int)] = []
    var paths: [(points: [BASICGraphicsPoint], color: Int)] = []
    var circles: [(Int, Int, Int, Int)] = []
    var ellipses: [(Int, Int, Int, Int, Int)] = []
    var fills: [(Int, Int, Int, Int?)] = []
    var graphicsColor: Int?
    var fullPixels: [String: BASICColor] = [:]
    var fullLines: [(Int, Int, Int, Int, BASICColor)] = []
    var fullPaths: [(points: [BASICGraphicsPoint], color: BASICColor)] = []
    var fullCircles: [(Int, Int, Int, BASICColor)] = []
    var fullEllipses: [(Int, Int, Int, Int, BASICColor)] = []
    var fullFills: [(Int, Int, BASICColor, BASICColor?)] = []
    var fullGraphicsColor: BASICColor?

    func print(_ text: String, terminator: String) {
        pendingOutput += text
        if terminator.contains("\n") {
            if hasPendingUnterminatedOutput {
                output[output.count - 1] = pendingOutput
            } else {
                output.append(pendingOutput)
            }
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

    func log(level: String, issuer: String, module: String, text: String) {
        logs.append((level, issuer, module, text))
    }

    func readLine(prompt: String) -> String? {
        input.isEmpty ? nil : input.removeFirst()
    }

    func readLine(prompt: String, exitOnSpecialKey: Bool) -> BASICLineInputResult? {
        if !lineInputResults.isEmpty {
            return lineInputResults.removeFirst()
        }
        return readLine(prompt: prompt).map { BASICLineInputResult(text: $0) }
    }

    func readLine(prompt: String, exitOnSpecialKey: Bool, options: BASICLineInputOptions) -> BASICLineInputResult? {
        lineInputOptions.append(options)
        return readLine(prompt: prompt, exitOnSpecialKey: exitOnSpecialKey)
    }

    func readKey() -> String? {
        keys.isEmpty ? nil : keys.removeFirst()
    }

    func readBlockingKey() -> String? {
        if breakOnBlockingKeyRead {
            executionControl?.requestBreak()
            return nil
        }
        return keys.isEmpty ? nil : keys.removeFirst()
    }

    func screenColumns() -> Int {
        columns
    }

    func screenRows() -> Int {
        rows
    }

    func locate(row: Int, column: Int) throws {
        locations.append((row, column))
    }

    func loadTextFile(path: String) throws -> String {
        try requireFileAccess(path)
        return files[resolvedPath(path)] ?? ""
    }

    func saveTextFile(path: String, text: String) throws {
        try requireFileAccess(path)
        let resolved = resolvedPath(path)
        files[resolved] = text
        fileData[resolved] = Data(text.utf8)
    }

    func loadFileData(path: String) throws -> Data {
        try requireFileAccess(path)
        let resolved = resolvedPath(path)
        if let data = fileData[resolved] {
            return data
        }
        return Data((files[resolved] ?? "").utf8)
    }

    func saveFileData(path: String, data: Data) throws {
        try requireFileAccess(path)
        let resolved = resolvedPath(path)
        fileData[resolved] = data
        files[resolved] = String(decoding: data, as: UTF8.self)
    }

    func fileExists(path: String) throws -> Bool {
        try requireFileAccess(path)
        let resolved = resolvedPath(path)
        return files[resolved] != nil || fileData[resolved] != nil || directories.contains(resolved)
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

    func listDirectory(path: String) throws -> [String] {
        let resolved = resolvedPath(path)
        let prefix = resolved == "." ? "" : resolved.trimmingCharacters(in: CharacterSet(charactersIn: "/\\")) + "/"
        let fileNames = Set((Set(files.keys).union(fileData.keys)).compactMap { candidate -> String? in
            guard candidate.hasPrefix(prefix) else { return nil }
            let remainder = String(candidate.dropFirst(prefix.count))
            guard !remainder.isEmpty else { return nil }
            return remainder.split(separator: "/").first.map(String.init)
        })
        let directoryNames = Set(directories.compactMap { candidate -> String? in
            guard candidate != resolved, candidate.hasPrefix(prefix) else { return nil }
            let remainder = String(candidate.dropFirst(prefix.count))
            guard !remainder.isEmpty else { return nil }
            return remainder.split(separator: "/").first.map(String.init)
        })
        return fileNames.union(directoryNames).sorted()
    }

    func isDirectory(path: String) throws -> Bool {
        directories.contains(resolvedPath(path))
    }

    func createDirectory(path: String) throws {
        directories.insert(resolvedPath(path))
    }

    func removePath(path: String) throws {
        let resolved = resolvedPath(path)
        if directories.contains(resolved) {
            let prefix = resolved + "/"
            guard !files.keys.contains(where: { $0.hasPrefix(prefix) }),
                  !fileData.keys.contains(where: { $0.hasPrefix(prefix) }),
                  !directories.contains(where: { $0 != resolved && $0.hasPrefix(prefix) }) else {
                throw BASICError.runtime("Directory not empty")
            }
            directories.remove(resolved)
            return
        }
        guard files.removeValue(forKey: resolved) != nil || fileData.removeValue(forKey: resolved) != nil else {
            throw BASICError.runtime("File Not Found")
        }
        fileData.removeValue(forKey: resolved)
    }

    func renamePath(from source: String, to destination: String) throws {
        let sourcePath = resolvedPath(source)
        let destinationPath = resolvedPath(destination)
        if let text = files.removeValue(forKey: sourcePath) {
            files[destinationPath] = text
        }
        if let data = fileData.removeValue(forKey: sourcePath) {
            fileData[destinationPath] = data
        }
        if directories.remove(sourcePath) != nil {
            directories.insert(destinationPath)
        }
    }

    func httpGet(url: String) async throws -> BASICHTTPResponse {
        httpRequests.append(url)
        if let message = httpErrors[url] {
            throw BASICError.runtime(message)
        }
        guard let response = httpResponses[url] else {
            throw BASICError.runtime("No test HTTP response for \(url)")
        }
        return response
    }

    private func resolvedPath(_ path: String) -> String {
        if path.hasPrefix("/") || currentDirectory == "." {
            return path
        }
        return currentDirectory + "/" + path
    }

    private func requireFileAccess(_ path: String) throws {
        guard !deniedFilePaths.contains(resolvedPath(path)) else {
            throw BASICError.runtime("Permission denied")
        }
    }

    func runSystemCommand(_ command: String) throws -> String {
        try runSystemCommandResult(command, environment: .empty).output
    }

    func runSystemCommandResult(_ command: String, environment: BASICEnvironmentPatch) throws -> BASICSystemCommandResult {
        systemCommands.append(command)
        systemEnvironmentPatches.append(environment)
        return BASICSystemCommandResult(
            output: systemOutputs[command] ?? "",
            exitCode: systemStatuses[command] ?? 0
        )
    }

    func resolveExecutable(_ command: String, environment: BASICEnvironmentPatch) throws -> String? {
        executablePaths[command]
    }

    func commandHistoryEntries() -> [String] {
        commandHistory
    }

    func clearCommandHistory() {
        commandHistory.removeAll()
    }

    func deleteCommandHistoryEntry(at index: Int) throws {
        guard commandHistory.indices.contains(index) else {
            throw BASICError.runtime("History entry \(index + 1) does not exist")
        }
        commandHistory.remove(at: index)
    }

    func runProcess(_ request: BASICProcessRequest) throws -> BASICProcessResult {
        processRequests.append(request)
        return processResults[request.executable] ?? BASICProcessResult(stdout: "", stderr: "", exitCode: 0)
    }

    func runPipeline(_ requests: [BASICProcessRequest]) throws -> BASICProcessResult {
        pipelineRequests.append(requests)
        return pipelineResult
    }

    func setScreenMode(_ mode: BASICScreenMode) {
        screenMode = mode
    }

    func setGraphicsColor(_ color: Int) {
        graphicsColor = color
    }

    func setGraphicsColor(_ color: BASICColor) {
        fullGraphicsColor = color
        graphicsColor = color.legacyIndex
    }

    func clearGraphics(color: Int?) {
        pixels.removeAll()
    }

    func setPixel(x: Int, y: Int, color: Int) {
        pixels["\(x),\(y)"] = color
    }

    func setPixel(x: Int, y: Int, color: BASICColor) {
        fullPixels["\(x),\(y)"] = color
        pixels["\(x),\(y)"] = color.legacyIndex ?? 1
    }

    func getPixel(x: Int, y: Int) -> Int {
        pixels["\(x),\(y)"] ?? 0
    }

    func drawLine(x1: Int, y1: Int, x2: Int, y2: Int, color: Int) {
        lines.append((x1, y1, x2, y2, color))
    }

    func drawLine(x1: Int, y1: Int, x2: Int, y2: Int, color: BASICColor) {
        fullLines.append((x1, y1, x2, y2, color))
        lines.append((x1, y1, x2, y2, color.legacyIndex ?? 1))
    }

    func drawPath(points: [BASICGraphicsPoint], color: Int) {
        paths.append((points, color))
        guard points.count >= 2 else { return }
        for index in points.indices.dropLast() {
            let start = points[index]
            let end = points[points.index(after: index)]
            drawLine(x1: start.x, y1: start.y, x2: end.x, y2: end.y, color: color)
        }
    }

    func drawPath(points: [BASICGraphicsPoint], color: BASICColor) {
        fullPaths.append((points, color))
        paths.append((points, color.legacyIndex ?? 1))
        guard points.count >= 2 else { return }
        for index in points.indices.dropLast() {
            let start = points[index]
            let end = points[points.index(after: index)]
            drawLine(x1: start.x, y1: start.y, x2: end.x, y2: end.y, color: color)
        }
    }

    func drawCircle(cx: Int, cy: Int, radius: Int, color: Int) {
        circles.append((cx, cy, radius, color))
    }

    func drawCircle(cx: Int, cy: Int, radius: Int, color: BASICColor) {
        fullCircles.append((cx, cy, radius, color))
        circles.append((cx, cy, radius, color.legacyIndex ?? 1))
    }

    func drawEllipse(cx: Int, cy: Int, radiusX: Int, radiusY: Int, color: Int) {
        ellipses.append((cx, cy, radiusX, radiusY, color))
    }

    func drawEllipse(cx: Int, cy: Int, radiusX: Int, radiusY: Int, color: BASICColor) {
        fullEllipses.append((cx, cy, radiusX, radiusY, color))
        ellipses.append((cx, cy, radiusX, radiusY, color.legacyIndex ?? 1))
    }

    func paintFill(x: Int, y: Int, color: Int, borderColor: Int?) {
        fills.append((x, y, color, borderColor))
    }

    func paintFill(x: Int, y: Int, color: BASICColor, borderColor: BASICColor?) {
        fullFills.append((x, y, color, borderColor))
        fills.append((x, y, color.legacyIndex ?? 1, borderColor?.legacyIndex))
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
            if hasPendingUnterminatedOutput {
                output[output.count - 1] = pendingOutput
            } else {
                output.append(pendingOutput)
            }
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
