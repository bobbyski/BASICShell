//
//  StudioWasmRunTests.swift
//  BASICStudioTests
//
//  BASIC-45: ⚡ with Settings ▸ Console ▸ "⚡ builds with" set to WebAssembly
//  compiles the program in Studio, runs it in JavaScriptCore, and uses
//  Studio's console as the interpreter does: output, INPUT, errors and Stop.
//  Its ActiveUI windows are Studio's, as an interpreted program's are.
//

import ActiveUI
import BASICCore
import Foundation
import Testing
@testable import BASICStudio

@MainActor
@Suite("BASIC-45 · ⚡ as WebAssembly, in Studio", .serialized)
struct StudioWasmRunTests {
    private func start(_ program: String) -> StudioHarness {
        let studio = StudioHarness(program: program)
        studio.model.compiledRunTarget = .webAssembly
        studio.model.jitEditorProgram()
        return studio
    }

    private func waitUntilFinished(_ studio: StudioHarness) async throws {
        try await studio.waitUntil("the WebAssembly run to finish", timeout: .seconds(60)) { !studio.model.isJITRunning }
    }

    @Test("Prints, takes INPUT from the console, and returns to the prompt")
    func printsAndAsks() async throws {
        let studio = start("""
        print "Hello from WebAssembly"
        input "Name? "; who$
        print "Hi, "; who$; "! "; 6 * 7
        """)
        try await studio.answer("Ada", afterPrompt: "Name? ")
        try await waitUntilFinished(studio)
        let console = studio.model.consoleText
        #expect(console.contains("JIT\nHello from WebAssembly\nName? "), "\(console)")
        #expect(console.contains("Hi, Ada! 42\n"), "\(console)")
        #expect(console.hasSuffix(studio.model.prompt))
    }

    @Test("A runtime error is reported as the interpreter reports it")
    func error() async throws {
        let studio = start("print \"before\"\nprint 1 / 0")
        try await waitUntilFinished(studio)
        #expect(studio.model.consoleText.contains("before\n"))
        #expect(studio.model.consoleText.contains("Division by zero"), "\(studio.model.consoleText)")
    }

    @Test("Stop ends a loop that never would")
    func stop() async throws {
        let studio = start("n = 0\nwhile 1\n    n = n + 1\nwend")
        try await studio.waitUntil("the run to start") { studio.model.isJITRunning }
        try await Task.sleep(for: .milliseconds(300))
        studio.model.stopProgram()
        try await waitUntilFinished(studio)
        #expect(studio.model.consoleText.contains("Break at "), "\(studio.model.consoleText.suffix(200))")
    }

    @Test("BASIC-47 · Stop ends a loop whose every pass is slow, at once, not after thousands more passes")
    func stopSlowPasses() async throws {
        // Each pass searches two million characters. Polling every 4,096th
        // pass took over 30 seconds to see a Stop; the poll is sized by time
        // now, about every 10 ms, and Stop lands in about 0.1 s.
        let studio = start("""
        big$ = STRING$(2000000, "x")
        n = 0
        while 1
            p = INSTR(big$, "y")
            n = n + 1
        wend
        """)
        try await studio.waitUntil("the run to start") { studio.model.isJITRunning }
        try await Task.sleep(for: .seconds(1))
        let clock = ContinuousClock()
        let asked = clock.now
        studio.model.stopProgram()
        try await waitUntilFinished(studio)
        let took = clock.now - asked
        #expect(took < .seconds(2), "Stop took \(took)")
        #expect(studio.model.consoleText.contains("Break at "), "\(studio.model.consoleText.suffix(200))")
    }

    @Test("BASIC-46 · The debugger in a WebAssembly run: a breakpoint, the panes, step out, into and over, Continue")
    func debugger() async throws {
        let studio = StudioHarness(program: """
        DIM total AS DOUBLE
        name$ = "Ada"
        total = 0
        FOR i = 1 TO 3
            total = total + Twice(i)
        NEXT i
        PRINT name$; total

        FUNCTION Twice(x AS DOUBLE) AS DOUBLE
            LOCAL y = x * 2
            RETURN y
        END FUNCTION
        """)
        let model = studio.model
        model.runTarget = .webAssembly
        model.toggleDebuggerBreakpoint(atSourceLine: 11)
        model.runEditorProgram()
        func stopped(at line: Int) async throws {
            try await studio.waitUntil("a stop at line \(line)", timeout: .seconds(60)) { model.isProgramPaused }
            #expect(model.debuggerExecutionLine == line, "\(model.consoleText.suffix(200))")
        }
        func value(_ name: String, _ variables: [BASICVariableSnapshot]) -> String? {
            variables.first { $0.name == name }?.value
        }

        try await stopped(at: 11)
        #expect(model.isJITRunning, "compiled, and waiting")
        #expect(model.debuggerCallStack.map(\.name) == ["Twice", "[main]"])
        #expect(model.debuggerCallStack.map { $0.location?.lineNumber } == [11, 5])
        #expect(value("x", model.debuggerSelectedLocalVariables) == "1")
        #expect(value("y", model.debuggerSelectedLocalVariables) == "2")
        #expect(value("total", model.debuggerGlobalVariables) == "0")
        #expect(value("name$", model.debuggerGlobalVariables) == "Ada")
        #expect(model.inspectorPane == .debug, "the stop opens the Debug pane")
        let pane = DebugPaneModel(model)
        #expect(pane.button(.continueExecution).isEnabled && pane.button(.stepOut).isEnabled && pane.button(.step).isEnabled)
        #expect(!pane.button(.pause).isEnabled && !pane.button(.run).isEnabled)
        // The caller's frame: its own (no) locals.
        model.selectDebuggerCallStackFrame(model.debuggerCallStack[1])
        #expect(model.debuggerSelectedLocalVariables.isEmpty)

        model.stepOutDebugging()
        try await stopped(at: 6)
        #expect(model.debuggerCallStack.map(\.name) == ["[main]"])
        #expect(value("total", model.debuggerGlobalVariables) == "2")
        model.stepDebugging()
        try await stopped(at: 5)
        model.stepDebugging()
        try await stopped(at: 10)
        #expect(value("x", model.debuggerSelectedLocalVariables) == "2")
        model.stepOverDebugging()
        try await stopped(at: 11)
        #expect(value("y", model.debuggerSelectedLocalVariables) == "4")

        model.toggleDebuggerBreakpoint(atSourceLine: 11)
        model.continueDebugging()
        try await waitUntilFinished(studio)
        #expect(model.consoleText.contains("Ada12\n"), "\(model.consoleText.suffix(300))")
        #expect(!model.isProgramPaused && model.debuggerCallStack.isEmpty)
    }

    @Test("BASIC-46 · Step starts a WebAssembly run at its first line; Pause stops a running one; Stop ends a stopped one")
    func debuggerPauseAndStop() async throws {
        let studio = StudioHarness(program: "n = 0\nWHILE 1\n    n = n + 1\nWEND")
        let model = studio.model
        model.runTarget = .webAssembly
        model.stepDebugging()
        try await studio.waitUntil("a stop at the first line", timeout: .seconds(60)) { model.isProgramPaused }
        #expect(model.debuggerExecutionLine == 1)
        model.continueDebugging()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.isJITRunning && !model.isProgramPaused)
        #expect(DebugPaneModel(model).button(.pause).isEnabled)
        model.pauseProgram()
        try await studio.waitUntil("Pause to stop it") { model.isProgramPaused }
        #expect((2...4).contains(model.debuggerExecutionLine ?? 0), "\(String(describing: model.debuggerExecutionLine))")
        #expect(Int(model.debuggerGlobalVariables.first { $0.name == "n" }?.value ?? "") ?? 0 > 0)
        model.stopProgram()
        try await waitUntilFinished(studio)
        #expect(model.consoleText.contains("Break at "), "\(model.consoleText.suffix(200))")
        #expect(!model.isProgramPaused)
    }

    @Test("The timing test: ▶ Run as WebAssembly prints the interpreter's checksums, and both say when they started and ended")
    func timingTest() async throws {
        let studio = StudioHarness()
        let model = studio.model
        let example = try #require(model.bundledExamples.first { $0.path == "language/timing-test" })
        model.loadBundledExample(example)

        /// Each section's line, without its time: what must be the same.
        func checksums(_ console: String) -> [String] {
            let run = console.components(separatedBy: "TIMING TEST").last ?? ""
            return run.split(separator: "\n").compactMap { line in
                guard let range = line.range(of: "checksum") else { return nil }
                return String(line[..<range.upperBound]) + (line[range.upperBound...].components(separatedBy: "   ").first ?? "")
            }
        }
        func timed(_ console: String) -> Bool {
            let run = console.components(separatedBy: "TIMING TEST").last ?? ""
            return run.contains("Started at ") && run.contains("Ended at ") && run.contains("Elapsed ") && run.contains(" ms\n")
        }

        let clock = ContinuousClock()
        model.runTarget = .interpreter
        var started = clock.now
        model.runEditorProgram()
        try await studio.waitUntilStopped(timeout: .seconds(180))
        let interpretedTook = clock.now - started
        let interpreted = model.consoleText
        let expected = checksums(interpreted)
        #expect(expected.count == 5, "\(interpreted.suffix(600))")
        #expect(timed(interpreted), "\(interpreted.suffix(600))")

        model.runTarget = .webAssembly
        started = clock.now
        model.runEditorProgram()
        try await waitUntilFinished(studio)
        let compiledTook = clock.now - started
        let compiled = model.consoleText
        #expect(checksums(compiled) == expected, "\(compiled.suffix(600))")
        #expect(timed(compiled), "\(compiled.suffix(600))")
        print("timing test: interpreter \(interpretedTook), WebAssembly \(compiledTook) (compiling included)")
        for (engine, console) in [("interpreter", interpreted), ("WebAssembly", compiled)] {
            let run = console.components(separatedBy: "TIMING TEST").last ?? ""
            for line in run.split(separator: "\n") where line.contains(" ms") || line.hasPrefix("Elapsed") {
                print("timing test, \(engine): \(line)")
            }
        }
    }

    @Test("A runtime error names the editor's line, blank lines and all, as the interpreter's does")
    func errorLineAfterBlankLines() async throws {
        for target in [StudioRunTarget.interpreter, .webAssembly] {
            let studio = StudioHarness(program: "print 1\n\nprint 2\n\nprint 1 / 0")
            studio.model.runTarget = target
            studio.model.runEditorProgram()
            try await studio.waitUntil("the error", timeout: .seconds(60)) {
                !studio.model.isProgramRunning && !studio.model.isJITRunning && studio.model.consoleText.contains("zero")
            }
            #expect(studio.model.consoleText.contains("Division by zero at 5"), "\(target): \(studio.model.consoleText.suffix(200))")
        }
    }

    @Test("A program that does not compile says why, and runs nothing")
    func refused() async throws {
        let studio = start("print \"unterminated")
        try await waitUntilFinished(studio)
        #expect(studio.model.consoleText.contains("Unterminated string"), "\(studio.model.consoleText.suffix(300))")
    }

    /// The first control of `type` the program made.
    private func control<T: AUIView>(_ type: T.Type, in bridge: StudioAUIBridge) -> (Int, T)? {
        bridge.views.sorted { $0.key < $1.key }.lazy.compactMap { id, view in (view as? T).map { (id, $0) } }.first
    }

    @Test("A program's window: clicks and a selection reach its handlers, run() returns when it closes")
    func window() async throws {
        let studio = StudioHarness(program: """
        GLOBAL clicks = 0
        let w = AUIWindow("Picker")
        let l = AUILabel("none yet")
        let b = AUIButton("Count")
        let li = AUIList()
        li.add("Ada")
        li.add("Grace")
        w.add(l)
        w.add(b)
        w.add(li)
        b.onclick("Counted")
        on aui select call Picked
        w.run()
        print "clicks "; clicks; " label "; l.text$()

        function Counted()
            clicks = clicks + 1
        end function

        function Picked(event as BASICAUIEvent)
            l.text("picked " + event.Text$)
        end function
        """)
        let bridge = studio.model.auiBridge
        bridge.showsWindows = false
        studio.model.compiledRunTarget = .webAssembly
        studio.model.jitEditorProgram()
        try await studio.waitUntil("the window", timeout: .seconds(60)) {
            (try? bridge.perform(.isOpen(id: 1))) == .flag(true) && bridge.views.count == 3
        }
        let (_, button) = try #require(control(AUIButton.self, in: bridge))
        button.onClick?()
        button.onClick?()
        let (_, list) = try #require(control(AUITable.self, in: bridge))
        #expect(list.rowCount() == 2)
        list.selectedRows = [1]
        list.onSelectionChange?([1])
        let (_, label) = try #require(control(AUILabel.self, in: bridge))
        try await studio.waitUntil("the handler") { label.text == "picked Grace" }
        _ = try bridge.perform(.close(id: 1))
        try await waitUntilFinished(studio)
        #expect(studio.model.consoleText.contains("clicks 2 label picked Grace"), "\(studio.model.consoleText.suffix(300))")
        #expect(bridge.views.isEmpty, "the program's controls go when it ends")
    }

    /// What the console's VTG view was sent, as text.
    private final class Drawn {
        var data = Data()
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    @Test("Graphics go to the console's canvas, its mouse reaches the program, and touch controls are Studio's")
    func graphicsMouseAndTouch() async throws {
        let studio = StudioHarness(program: """
        GLOBAL clicked = 0
        let vtg = VectorTerminal()
        let touch = TouchControls()
        touch.Joystick("stick", "BOTTOMRIGHT", 40, 40, 160)
        vtg.line("diagonal", 10, 20, 300, 200, "#5eead4", 3)
        vtg.present()
        on mouse down call Pressed
        print "ready"
        while clicked = 0
            yield
        wend
        print "clicked at "; clicked

        function Pressed(e as BASICMouseEvent)
            clicked = e.x
        end function
        """)
        let drawn = Drawn()
        studio.model.vtgDataSink = { drawn.data.append($0) }
        studio.model.compiledRunTarget = .webAssembly
        studio.model.jitEditorProgram()
        try await studio.waitUntil("the program to be ready", timeout: .seconds(60)) {
            studio.model.consoleText.contains("ready\n")
        }
        #expect(studio.model.touchControls.snapshot().map(\.control.id) == ["stick"])
        studio.model.postVTGMouseEvent(subtype: "DOWN", x: 42, y: 7, button: 0, buttons: 1, duration: 0)
        try await waitUntilFinished(studio)
        #expect(studio.model.consoleText.contains("clicked at 42"), "\(studio.model.consoleText.suffix(300))")
        try await studio.waitUntil("the drawing to reach the console") { drawn.text.contains("_VTG;line,id=diagonal") }
        #expect(studio.model.touchControls.isEmpty, "the program's controls go when it ends")
        #expect(!studio.model.session.sendsHostEventsToCompiledProgram, "the interpreter has its events back")
    }

    @Test("A bundled example's IMPORTs are found as the interpreter finds them: Data ▸ gradebook prints the same")
    func gradebook() async throws {
        let studio = StudioHarness()
        let model = studio.model
        let example = try #require(model.bundledExamples.first { $0.path == "data/gradebook" })
        model.loadBundledExample(example)
        model.runEditorProgram()
        try await studio.waitUntilStopped()
        let interpreted = model.consoleText
        let start = try #require(interpreted.range(of: "TEACHER GRADE BOOK"))
        let expected = String(interpreted[start.lowerBound...]).components(separatedBy: model.prompt).first ?? ""
        #expect(expected.contains("Intro to BASIC"), "\(interpreted.suffix(400))")

        model.compiledRunTarget = .webAssembly
        model.jitEditorProgram()
        try await waitUntilFinished(studio)
        let compiled = model.consoleText
        let tail = String(compiled[try #require(compiled.range(of: "TEACHER GRADE BOOK", options: .backwards)).lowerBound...])
        #expect(tail.components(separatedBy: model.prompt).first == expected, "\(compiled.suffix(600))")
    }

    @Test("IMPORT \"ActiveUI\": its own classes, a BASIC handler, and AUIApplication.run in a window of Studio's")
    func importActiveUI() async throws {
        let studio = StudioHarness(program: """
        IMPORT "ActiveUI"
        GLOBAL clicks = 0
        DIM Caption AS AUILabel
        Caption = NEW AUILabel("Ready")
        DIM Go AS AUIButton
        Go = NEW AUIButton("Count")
        FUNCTION Clicked() AS DOUBLE
          clicks = clicks + 1
          Caption.text = "clicked"
          RETURN 0
        END FUNCTION
        Go.onClick = FUNCTION() AS DOUBLE = Clicked()
        DIM Column AS AUIStack
        Column = NEW AUIStack(AUIStack_Axis.vertical, 12, AUIStack_CrossAxisAlignment.leading, AUIStack_LayoutMode.flow)
        Column.addChild(Caption)
        Column.addChild(Go)
        PRINT "label "; Caption.text
        AUIApplication.run(Column, AUIRootPlacement.centered)
        PRINT "closed with "; clicks; " clicks, label "; Caption.text
        """)
        let bridge = studio.model.auiBridge
        bridge.showsWindows = false
        studio.model.compiledRunTarget = .webAssembly
        studio.model.jitEditorProgram()
        try await studio.waitUntil("the app's window", timeout: .seconds(60)) { bridge.appWindows.count == 1 }
        let app = try #require(bridge.appWindows.first)
        let button = try #require(app.root.children.compactMap { $0 as? AUIButton }.first)
        let label = try #require(app.root.children.compactMap { $0 as? AUILabel }.first)
        #expect(studio.model.consoleText.contains("label Ready"), "\(studio.model.consoleText.suffix(300))")
        button.onClick?()
        button.onClick?()
        try await studio.waitUntil("the handler") { label.text == "clicked" }
        bridge.closeAppWindow(app.window)
        try await waitUntilFinished(studio)
        #expect(studio.model.consoleText.contains("closed with 2 clicks, label clicked"), "\(studio.model.consoleText.suffix(300))")
        #expect(bridge.appWindows.isEmpty)
    }

    /// The requirement (Bobby, 2026-10-09): Apps ▸ Grade Book — a project,
    /// directory imports, an SQLite store, a window of pages — runs as
    /// WebAssembly in Studio, as it does in the interpreter.
    @Test("Apps ▸ Grade Book runs as a project: its window opens, its database is made, it closes cleanly")
    func gradeBookProject() async throws {
        let studio = StudioHarness()
        let model = studio.model
        let examples = FileManager.default.temporaryDirectory.appendingPathComponent("gradebook-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: examples) }
        model.examplesFolderOverride = examples
        let example = try #require(model.bundledExamples.first { $0.projectFolder?.hasSuffix("GradeBook.basproj") == true })
        model.loadBundledExample(example)
        let project = try #require(model.projectDirectoryURL)
        let bridge = model.auiBridge
        bridge.showsWindows = false
        model.compiledRunTarget = .webAssembly
        model.jitEditorProgram()
        try await studio.waitUntil("Grade Book's window", timeout: .seconds(90)) {
            !bridge.windows.isEmpty && (try? bridge.perform(.isOpen(id: bridge.windows.keys.min()!))) == .flag(true)
        }
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("GradeBook.sqlite").path),
                "\(model.consoleText.suffix(600))")
        // Make a book through its Books page, as a teacher would.
        let fields = bridge.views.values.compactMap { $0 as? AUITextField }
        let classField = try #require(fields.first { $0.placeholder?.hasPrefix("Class") == true })
        let periodField = try #require(fields.first { $0.placeholder?.hasPrefix("Period") == true })
        classField.text = "Algebra I"
        periodField.text = "2"
        let make = try #require(bridge.views.values.compactMap { $0 as? AUIButton }.first { $0.title == "Make book" })
        make.onClick?()
        try await studio.waitUntil("the book to be made", timeout: .seconds(30)) { classField.text.isEmpty }
        _ = try bridge.perform(.close(id: bridge.windows.keys.min()!))
        try await waitUntilFinished(studio)
        #expect(model.consoleText.contains("Grade Book closed. Everything is saved in"), "\(model.consoleText.suffix(600))")
        #expect(!model.consoleText.contains("error"), "\(model.consoleText.suffix(600))")

        // Again, over the book the first run made: `store.Load("Book",
        // rows.Number("Id"))` reads it back — a call whose second argument
        // makes a call of its own, which once overwrote the first ("Unknown
        // CLASS Id", Bobby's iPad).
        let before = model.consoleText.count
        model.jitEditorProgram()
        try await studio.waitUntil("Grade Book's window again", timeout: .seconds(90)) {
            let id = bridge.windows.keys.max()
            return id.map { (try? bridge.perform(.isOpen(id: $0))) == .flag(true) } ?? false
        }
        // The book it read back is the open one, named over the tabs.
        try await studio.waitUntil("the book read back", timeout: .seconds(30)) {
            bridge.views.values.compactMap { $0 as? AUILabel }.contains { $0.text.contains("Algebra I") }
        }
        _ = try bridge.perform(.close(id: bridge.windows.keys.max()!))
        try await waitUntilFinished(studio)
        let second = String(model.consoleText.dropFirst(before))
        #expect(second.contains("Grade Book closed. Everything is saved in"), "\(second.suffix(600))")
        #expect(!second.contains("error"), "\(second.suffix(600))")
    }

    @Test("A BASIC class inheriting ActiveUI's AUIView: ActiveUI calls its override")
    func inheritAUIView() async throws {
        let studio = start("""
        IMPORT "ActiveUI"
        GLOBAL refreshed = 0
        CLASS Badge
          INHERITS AUIView
          PUBLIC count AS DOUBLE
          OVERRIDES FUNCTION refreshSelf() AS VOID
            refreshed = refreshed + 1
            ME.count = ME.count + 1
          END FUNCTION
        END CLASS
        DIM B AS Badge
        B = NEW Badge()
        DIM Column AS AUIStack
        Column = NEW AUIStack(AUIStack_Axis.vertical, 12, AUIStack_CrossAxisAlignment.leading, AUIStack_LayoutMode.flow)
        Column.addChild(B)
        Column.refresh()
        PRINT "refreshed "; refreshed; ", count "; B.count
        """)
        try await waitUntilFinished(studio)
        #expect(studio.model.consoleText.contains("refreshed 1, count 1\n"), "\(studio.model.consoleText.suffix(400))")
    }

    @Test("IMPORT \"TUIKit\": an App on a headless terminal calls BASIC back inside run, and stops")
    func importTUIKit() async throws {
        let studio = start("""
        IMPORT "TUIKit"
        DIM D AS HeadlessDriver
        D = NEW HeadlessDriver(40, 8, FALSE)
        DIM A AS App
        A = NEW App(D, NULL)
        DIM W AS Window
        W = NEW Window(0, 0, 40, 8)
        FUNCTION Finish() AS DOUBLE
          W.showTooltip("Hello from BASIC", 2, 2)
          A.stop()
          RETURN 0
        END FUNCTION
        A.schedule(50, FUNCTION() AS DOUBLE = Finish())
        A.run(W)
        DIM Lines AS VARIANT
        Lines = D.snapshotText()
        FOR I = 0 TO LEN(Lines) - 1
          PRINT "|"; Lines(I); "|"
        NEXT I
        """)
        try await waitUntilFinished(studio)
        #expect(studio.model.consoleText.contains("│ Hello from BASIC │"), "\(studio.model.consoleText.suffix(600))")
    }

    @Test("On the Mac ▶ Run can be WebAssembly too: chosen in Settings, kept, and run as iPad runs it")
    func runAsWebAssemblyOnTheMac() async throws {
        let studio = StudioHarness(program: "print \"run as \"; 6 * 7")
        #expect(studio.model.effectiveRunTarget == .interpreter, "the interpreter by default")
        studio.model.runTarget = .webAssembly
        #expect(StudioSettings(runTarget: .webAssembly).runTarget == .webAssembly)
        let saved = try JSONEncoder().encode(StudioSettings(runTarget: .webAssembly))
        #expect(try JSONDecoder().decode(StudioSettings.self, from: saved).runTarget == .webAssembly)
        studio.model.runEditorProgram()
        #expect(studio.model.isJITRunning, "compiled, not interpreted")
        try await waitUntilFinished(studio)
        #expect(studio.model.consoleText.contains("RUN\nrun as 42\n"), "\(studio.model.consoleText.suffix(200))")
    }

    @Test("On the Mac the choice is the person's, and LLVM is the default")
    func choice() {
        #expect(StudioCompiledRunTarget.isChoosable)
        let studio = StudioHarness()
        #expect(studio.model.compiledRunTarget == .llvm)
        #expect(studio.model.effectiveCompiledRunTarget == .llvm)
        studio.model.compiledRunTarget = .webAssembly
        #expect(studio.model.effectiveCompiledRunTarget == .webAssembly)
    }
}
