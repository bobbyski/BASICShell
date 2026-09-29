//
//  StudioFeatureTests.swift
//  BASICStudioTests
//
//  Level 2 of ACTIVEUI_TRANSITION.md §10: programs run, and leave the console,
//  the log and the debugger as they should. No shell is involved.
//

import BASICCore
import Foundation
import Testing
@testable import BASICStudio

/// One test per row of the feature inventory that the model alone can prove.
/// The IDs (C1, L2, D3…) are the inventory's, in Documents/STUDIO_FEATURES.md.
///
/// Serialized: each test's program runs on its model's own execution lane, but
/// the sound and graphics hosts behind them are per process.
@Suite("Studio features, headless", .serialized)
@MainActor
struct StudioFeatureTests {
    @Test("C1 · Run prints the program's output, then the prompt")
    func runPrintsOutput() async throws {
        let studio = StudioHarness(program: """
        PRINT "HELLO"
        PRINT 2 + 3
        """)
        try await studio.run()
        #expect(studio.lastRunOutput.hasPrefix("HELLO\n5\n"), "\(studio.model.consoleText.debugDescription)")
        #expect(studio.model.consoleText.hasSuffix(studio.model.prompt))
        #expect(!studio.model.isProgramRunning)
        #expect(!studio.model.isProgramPaused)
    }

    @Test("C2 · INPUT reads a line typed at the console")
    func inputReadsALine() async throws {
        let studio = StudioHarness(program: """
        INPUT "NAME"; N$
        PRINT "HI "; N$
        """)
        studio.model.runEditorProgram()
        try await studio.answer("BOBBY", afterPrompt: "NAME")
        try await studio.waitUntilStopped()
        #expect(studio.lastRunOutput.contains("HI BOBBY\n"))
    }

    @Test("C3 · A command typed at the prompt runs immediately")
    func consoleCommandRuns() async throws {
        let studio = StudioHarness()
        try await studio.submit("PRINT 6 * 7")
        #expect(studio.model.consoleText.contains("PRINT 6 * 7\n42\n"), "\(studio.model.consoleText.debugDescription)")
        #expect(studio.model.command.isEmpty)
    }

    @Test("C4 · Stop ends a program that would run forever")
    func stopEndsARunawayProgram() async throws {
        let studio = StudioHarness(program: """
        PRINT "LOOPING"
        10 GOTO 10
        """)
        studio.model.runEditorProgram()
        try await studio.waitUntil("the program to start") { studio.model.consoleText.contains("LOOPING") }
        #expect(studio.model.isProgramRunning)
        studio.model.stopProgram()
        try await studio.waitUntilStopped()
        #expect(!studio.model.isProgramPaused)
        #expect(studio.model.consoleText.hasSuffix(studio.model.prompt))
    }

    @Test("C5 · NEW clears the editor, the console and the debugger")
    func clearProgramResets() async throws {
        let studio = StudioHarness(program: "PRINT \"GONE\"")
        try await studio.run()
        studio.model.clearProgram()
        #expect(studio.model.programText.isEmpty)
        #expect(studio.model.consoleText == studio.model.prompt)
        #expect(studio.model.debuggerCallStack.isEmpty)
        #expect(studio.model.currentProgramURL == nil)
    }

    @Test("E1 · A syntax error in the editor becomes a diagnostic on its line")
    func syntaxErrorBecomesADiagnostic() async throws {
        let studio = StudioHarness(program: """
        PRINT "FINE"
        PRINT (
        """)
        #expect(studio.model.editorDiagnostics.contains { $0.lineNumber == 2 })
        studio.model.programText = "PRINT \"FINE\""
        #expect(studio.model.editorDiagnostics.isEmpty)
    }

    @Test("L1 · LOG in a program lands in the Log pane as a user entry")
    func logStatementReachesTheLog() async throws {
        let studio = StudioHarness(program: """
        LOG INFO, "from the program"
        """)
        try await studio.run()
        let entry = try #require(studio.model.logEntries.last { $0.text.contains("from the program") })
        #expect(entry.issuer == .user)
        #expect(entry.level == "INFO")
        #expect(studio.model.filteredLogEntries.contains(entry))
        #expect(studio.model.availableLogLevels.contains("INFO"))
    }

    @Test("L2 · The level filter and Studio's own entries are toggles over one list")
    func logFilters() async throws {
        let studio = StudioHarness(program: """
        LOG INFO, "an info"
        LOG WARN, "a warning"
        """)
        try await studio.run()
        studio.model.toggleLogLevel("WARN")
        #expect(studio.model.filteredLogEntries.map(\.text) == ["a warning"])
        studio.model.toggleLogLevel("WARN")
        studio.model.showBasicLogs = true
        #expect(studio.model.filteredLogEntries.contains { $0.issuer == .basic && $0.text == "program finished" })
        studio.model.clearLogs()
        #expect(studio.model.logEntries.isEmpty)
    }

    @Test("D1 · A breakpoint pauses on its line with a call stack; Continue finishes")
    func breakpointPausesAndContinues() async throws {
        let studio = StudioHarness(program: """
        PRINT "ONE"
        PRINT "TWO"
        PRINT "THREE"
        """)
        studio.model.openDebugger()
        studio.model.toggleDebuggerBreakpoint(atSourceLine: 2)
        #expect(studio.model.debuggerBreakpointLines == [2])
        try await studio.run()
        #expect(studio.model.isProgramPaused)
        #expect(studio.model.debuggerExecutionLine == 2)
        #expect(!studio.model.debuggerCallStack.isEmpty)
        #expect(studio.lastRunOutput.hasPrefix("ONE\n"))
        #expect(!studio.lastRunOutput.contains("TWO"))

        studio.model.continueDebugging()
        try await studio.waitUntilStopped()
        #expect(!studio.model.isProgramPaused)
        #expect(studio.model.debuggerExecutionLine == nil)
        #expect(studio.model.consoleText.contains("TWO\nTHREE\n"))
    }

    @Test("D2 · Step runs one statement and pauses again")
    func stepAdvancesOneLine() async throws {
        let studio = StudioHarness(program: """
        A = 1
        A = A + 1
        PRINT A
        """)
        studio.model.openDebugger()
        studio.model.toggleDebuggerBreakpoint(atSourceLine: 1)
        try await studio.run()
        #expect(studio.model.debuggerExecutionLine == 1)
        studio.model.stepOverDebugging()
        try await studio.waitUntilStopped()
        #expect(studio.model.isProgramPaused)
        #expect(studio.model.debuggerExecutionLine == 2)
        studio.model.continueDebugging()
        try await studio.waitUntilStopped()
        #expect(studio.model.consoleText.contains("RUN\n2\n"), "\(studio.model.consoleText.debugDescription)")
    }

    @Test("D21 · Pause stops a running program at its current statement; Continue resumes; Stop ends it")
    func pausePausesAndContinueResumes() async throws {
        let studio = StudioHarness(program: """
        10 A = A + 1
        20 GOTO 10
        """)
        studio.model.openDebugger()
        studio.model.runEditorProgram()
        try await studio.waitUntil("the loop to spin") { studio.model.isProgramRunning }
        try await Task.sleep(for: .milliseconds(50))
        DebugPaneModel.perform(.pause, on: studio.model)
        try await studio.waitUntilStopped()
        #expect(studio.model.isProgramPaused)
        let line = try #require(studio.model.debuggerExecutionLine)
        #expect([1, 2].contains(line))
        #expect(!studio.model.debuggerCallStack.isEmpty)

        studio.model.continueDebugging()
        try await studio.waitUntil("the loop to resume") { studio.model.isProgramRunning }
        #expect(!studio.model.isProgramPaused)
        studio.model.stopProgram()
        try await studio.waitUntilStopped()
        #expect(!studio.model.isProgramPaused)
    }

    @Test("D3 · Paused, the variables pane sees the program's globals")
    func pausedGlobalsAreVisible() async throws {
        let studio = StudioHarness(program: """
        TOTAL = 41
        TOTAL = TOTAL + 1
        PRINT TOTAL
        """)
        studio.model.openDebugger()
        studio.model.toggleDebuggerBreakpoint(atSourceLine: 3)
        try await studio.run()
        #expect(studio.model.isProgramPaused)
        let total = studio.model.debuggerGlobalVariables.first { $0.name.uppercased() == "TOTAL" }
        #expect(total?.value.contains("42") == true)
        studio.model.continueDebugging()
        try await studio.waitUntilStopped()
    }

    @Test("D4 · Toggling a breakpoint twice removes it")
    func breakpointToggleRemoves() {
        let studio = StudioHarness(program: "PRINT 1")
        studio.model.toggleDebuggerBreakpoint(atSourceLine: 1)
        studio.model.toggleDebuggerBreakpoint(atSourceLine: 1)
        #expect(studio.model.debuggerBreakpoints.isEmpty)
    }

    @Test("M1 · The Examples menu lists the bundled demos")
    func examplesAreBundled() {
        let studio = StudioHarness()
        #expect(!studio.model.bundledExamples.isEmpty)
    }

    @Test("M2 · Loading an example puts its source in the editor")
    func loadingAnExampleFillsTheEditor() throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first)
        studio.model.loadBundledExample(example)
        #expect(!studio.model.programText.isEmpty)
    }

    @Test("M3 · Find and Find and Replace go to the editor and ask it once each")
    func findRequests() {
        let studio = StudioHarness()
        studio.model.selectedPane = .console
        studio.model.showFind()
        #expect(studio.model.selectedPane == .editor)
        #expect(studio.model.editorFindRequest == 1)
        studio.model.showFindAndReplace()
        #expect(studio.model.editorReplaceRequest == 1)
    }

    @Test("M4 · Console menu toggles reach the model")
    func consoleMenuToggles() {
        let studio = StudioHarness()
        studio.model.setConsoleOverwriteMode(true)
        #expect(studio.model.isConsoleOverwriteMode)
        studio.model.setGraphicsLayersVisible(false)
        #expect(!studio.model.areGraphicsLayersVisible)
    }

    @Test("M5 · Show Debugger opens the Debug inspector")
    func showDebuggerOpensTheInspector() {
        let studio = StudioHarness()
        studio.model.openDebugger()
        #expect(studio.model.inspectorPane == .debug)
    }
}
