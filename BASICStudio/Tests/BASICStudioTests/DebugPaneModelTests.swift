//
//  DebugPaneModelTests.swift
//  BASICStudioTests
//
//  P1 unit 6: the Debug inspector's projection. The text rules are tested
//  directly; the rows are tested against real paused programs, since the
//  snapshots have no public initializers.
//

import BASICCore
import CoreGraphics
import Foundation
import Testing
@testable import BASICStudio

@Suite("DebugPaneModel rules")
struct DebugPaneModelRuleTests {
    @Test("D10 · Task metadata: each fact only when it says something, singular or plural")
    func taskMetadata() {
        #expect(DebugPaneModel.taskMetadata(parentID: nil, childCount: 0, waiterCount: 0, yieldCount: 0, location: nil).isEmpty)
        #expect(DebugPaneModel.taskMetadata(
            parentID: 1, childCount: 1, waiterCount: 1, yieldCount: 3,
            location: BASICBreakpointLocation(lineNumber: 12)
        ) == ["parent #1", "1 child", "1 waiter", "yields 3", "line 12"])
        #expect(DebugPaneModel.taskMetadata(parentID: nil, childCount: 2, waiterCount: 4, yieldCount: 0, location: nil) == ["2 children", "4 waiters"])
    }

    @Test("D11 · Locations: line, then statement past the first, then the file's name")
    func locationText() {
        #expect(DebugPaneModel.locationText(BASICBreakpointLocation(lineNumber: 7)) == "line 7")
        #expect(DebugPaneModel.locationText(BASICBreakpointLocation(lineNumber: 7, statementNumber: 2)) == "line 7 stmt 2")
        #expect(DebugPaneModel.locationText(BASICBreakpointLocation(fileName: "/a/b/game.bas", lineNumber: 7)) == "line 7 game.bas")
        #expect(DebugPaneModel.locationText(BASICBreakpointLocation(fileName: "", lineNumber: 7)) == "line 7")
    }

    @Test("D10 · What a suspended task is waiting for")
    func suspensionText() {
        #expect(DebugPaneModel.suspensionText(nil) == nil)
        #expect(DebugPaneModel.suspensionText(.debugger) == "paused in debugger")
        #expect(DebugPaneModel.suspensionText(.hostOperation("HTTP")) == "waiting for host operation: HTTP")
        #expect(DebugPaneModel.suspensionText(.join(taskID: 4)) == "waiting for task #4")
    }

    @Test("D13 · Call-stack metadata: override, and the receiver when it is not the declarer")
    func callStackMetadata() {
        #expect(DebugPaneModel.callStackMetadata(isOverride: false, receiverClassName: nil, declaringClassName: nil) == nil)
        #expect(DebugPaneModel.callStackMetadata(isOverride: true, receiverClassName: nil, declaringClassName: "Shape") == "override")
        #expect(DebugPaneModel.callStackMetadata(isOverride: false, receiverClassName: "circle", declaringClassName: "Circle") == nil)
        #expect(DebugPaneModel.callStackMetadata(isOverride: true, receiverClassName: "Circle", declaringClassName: "Shape") == "override, on Circle")
    }

    @Test("D12 · Only a ready, running or suspended task can be cancelled")
    func canCancel() {
        #expect(!DebugPaneModel.canCancel(nil))
        for state in [BASICTaskState.ready, .running, .suspended] {
            #expect(DebugPaneModel.canCancel(state), "\(state)")
        }
        for state in [BASICTaskState.completed, .cancelled, .failed] {
            #expect(!DebugPaneModel.canCancel(state), "\(state)")
        }
    }

    @Test("D10 · State kinds follow the task states one for one")
    func stateKinds() {
        let pairs: [(BASICTaskState, DebugPaneModel.StateKind)] = [
            (.ready, .ready), (.running, .running), (.suspended, .suspended),
            (.completed, .completed), (.cancelled, .cancelled), (.failed, .failed),
        ]
        for (state, kind) in pairs {
            #expect(DebugPaneModel.StateKind(state) == kind)
        }
    }

    @Test("D17 · The code view: 62% (at least 260) until dragged, 160 minimum, variables keep 140")
    func codePaneHeight() {
        #expect(DebugPaneModel.resolvedCodePaneHeight(totalHeight: 1000, dragged: nil) == 620)
        #expect(DebugPaneModel.resolvedCodePaneHeight(totalHeight: 500, dragged: nil) == 310)
        #expect(DebugPaneModel.resolvedCodePaneHeight(totalHeight: 380, dragged: nil) == 240)
        #expect(DebugPaneModel.resolvedCodePaneHeight(totalHeight: 1000, dragged: 100) == 160)
        #expect(DebugPaneModel.resolvedCodePaneHeight(totalHeight: 1000, dragged: 950) == 860)
        #expect(DebugPaneModel.resolvedCodePaneHeight(totalHeight: 200, dragged: nil) == 160)
    }

    @Test("D17 · Dragging the divider down grows the code view, within the same limits")
    func dragging() {
        #expect(DebugPaneModel.draggedCodePaneHeight(startHeight: 400, translation: 50, availableHeight: 1000) == 450)
        #expect(DebugPaneModel.draggedCodePaneHeight(startHeight: 400, translation: -400, availableHeight: 1000) == 160)
        #expect(DebugPaneModel.draggedCodePaneHeight(startHeight: 400, translation: 900, availableHeight: 1000) == 860)
    }

    @Test("D18 · Sections: Tasks, Call Stack and Files open; Locals and Globals closed")
    func sections() {
        #expect(DebugPaneModel.sections.map(\.title) == ["Tasks", "Call Stack", "Local Variables", "Globals", "Files"])
        #expect(DebugPaneModel.sections.map(\.isExpandedByDefault) == [true, true, false, false, true])
    }
}

@Suite("DebugPaneModel, against paused programs", .serialized)
@MainActor
struct DebugPaneModelProgramTests {
    private func enabled(_ pane: DebugPaneModel) -> [DebugPaneModel.Command] {
        pane.buttons.filter(\.isEnabled).map(\.command)
    }

    @Test("D7 · Idle: Run, Step and Step Over")
    func idleButtons() {
        let pane = DebugPaneModel(StudioHarness(program: "PRINT 1").model)
        #expect(enabled(pane) == [.run, .step, .stepOver])
        #expect(pane.buttons.map(\.title) == ["Run", "Continue", "Pause", "Step", "Step Over", "Step Out", "Cancel Task"])
    }

    @Test("D7 D10 D11 · Paused: the program's task is selected, so Cancel Task joins the stepping buttons")
    func pausedButtons() async throws {
        let studio = StudioHarness(program: """
        PRINT 1
        PRINT 2
        """)
        studio.model.openDebugger()
        studio.model.toggleDebuggerBreakpoint(atSourceLine: 2)
        try await studio.run()
        var pane = DebugPaneModel(studio.model)
        #expect(enabled(pane) == [.run, .continueExecution, .step, .stepOver, .stepOut, .cancelTask])
        #expect(pane.executionLine == 2)
        #expect(pane.breakpointLines == [2])

        let task = try #require(pane.tasks.first)
        #expect(task.isSelected && task.stateKind == .suspended && task.stateText == "SUSPENDED")
        let detail = try #require(pane.selectedTask)
        #expect(detail.idText == task.idText)
        #expect(detail.fields.map(\.label).prefix(2) == ["Name", "State"])

        // A click on the selected row deselects it, and Cancel Task goes off.
        DebugPaneModel.selectTask(id: task.id, on: studio.model)
        pane = DebugPaneModel(studio.model)
        #expect(pane.selectedTask == nil && !pane.tasks[0].isSelected)
        #expect(!pane.button(.cancelTask).isEnabled)
        DebugPaneModel.selectTask(id: task.id, on: studio.model)
        #expect(DebugPaneModel(studio.model).selectedTask?.idText == task.idText)

        DebugPaneModel.perform(.continueExecution, on: studio.model)
        try await studio.waitUntilStopped()
    }

    @Test("D13 D14 · Paused in a function: its frame, its line, its locals")
    func pausedInAFunction() async throws {
        let studio = StudioHarness(program: """
        function Add(a as integer, b as integer) as integer
            return a + b
        end function
        print Add(2, 3)
        """)
        studio.model.openDebugger()
        studio.model.toggleDebuggerBreakpoint(atSourceLine: 2)
        try await studio.run()
        #expect(studio.model.isProgramPaused)
        let pane = DebugPaneModel(studio.model)
        let frame = try #require(pane.callStack.first { $0.name.caseInsensitiveCompare("Add") == .orderedSame })
        #expect(pane.callStack.filter(\.isSelected).count == 1)
        let names = Set(pane.locals.map { $0.name.lowercased() })
        #expect(names.isSuperset(of: ["a", "b"]), "\(names)")

        DebugPaneModel.selectFrame(index: frame.index, on: studio.model)
        #expect(DebugPaneModel(studio.model).callStack.first { $0.index == frame.index }?.isSelected == true)

        DebugPaneModel.perform(.continueExecution, on: studio.model)
        try await studio.waitUntilStopped()
        #expect(studio.model.consoleText.contains("\n5\n"))
        #expect(DebugPaneModel(studio.model).callStack.isEmpty)
    }

    @Test("D15 · An open file: reference, Open, mode, position and path")
    func openFile() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-debug-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let studio = StudioHarness(program: """
        open "\(path)" for output as #1
        print #1, "hello"
        close #1
        """)
        studio.model.openDebugger()
        studio.model.toggleDebuggerBreakpoint(atSourceLine: 3)
        try await studio.run()
        #expect(studio.model.isProgramPaused)
        let file = try #require(DebugPaneModel(studio.model).files.first)
        #expect(file.reference.contains("1"))
        #expect(file.isOpen && file.statusText == "Open")
        #expect(file.hasPath && file.pathText.hasSuffix(URL(fileURLWithPath: path).lastPathComponent))
        #expect(file.positionText.contains(" / "))
        #expect(file.errorText == nil)

        DebugPaneModel.perform(.continueExecution, on: studio.model)
        try await studio.waitUntilStopped()
    }

    @Test("D3 · Globals are listed after a run")
    func globalsAfterARun() async throws {
        let studio = StudioHarness(program: "SCORE = 7")
        try await studio.run()
        let pane = DebugPaneModel(studio.model)
        #expect(pane.globals.contains { $0.name.uppercased() == "SCORE" && $0.value.contains("7") })
    }
}
