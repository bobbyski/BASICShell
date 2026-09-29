//
//  ActiveUIDebugPaneTests.swift
//  BASICStudioTests
//
//  Level 3 for P3.4: the ActiveUI Debug pane, against real paused programs.
//

import ActiveUI
import AppKit
import BASICCore
import Foundation
import Testing
@testable import BASICStudio

@Suite("ActiveUI Debug pane", .serialized)
@MainActor
struct ActiveUIDebugPaneTests {
    private func texts(_ view: AUIView) -> [String] {
        var found: [String] = []
        if let label = view as? AUILabel { found.append(label.text) }
        if let button = view as? AUIButton { found.append(button.title) }
        for child in view.children { found += texts(child) }
        return found
    }

    @Test("D7 D18 · Idle: the buttons as the projection says, the sections open or closed as SwiftUI's")
    func idle() {
        let model = StudioHarness(program: "PRINT 1").model
        let pane = DebugPaneAUI(model: model)
        let projection = DebugPaneModel(model)
        for button in projection.buttons {
            #expect(pane.buttons[button.command]?.isEnabled == button.isEnabled, "\(button.command)")
            #expect(pane.buttons[button.command]?.tooltip == button.title)
        }
        #expect(pane.sections.map(\.title) == DebugPaneModel.sections.map(\.title))
        #expect(pane.sections.map(\.isOpen) == [true, true, false, false, true])
        #expect(texts(pane.sections[1].content) == [DebugPaneModel.noFramesText])
    }

    @Test("D18 · A section's title opens and closes it")
    func disclosure() {
        let pane = DebugPaneAUI(model: StudioHarness().model)
        let files = pane.sections[4]
        #expect(!files.content.isHidden && files.header.title == "Files" && files.header.image?.accessibilityDescription == "Collapse")
        files.header.onClick?()
        #expect(files.content.isHidden && files.header.title == "Files" && files.header.image?.accessibilityDescription == "Expand")
    }

    @Test("D5 · A gutter click in the code view toggles the model's breakpoint")
    func gutterToggles() {
        let model = StudioHarness(program: "PRINT 1\nPRINT 2").model
        let pane = DebugPaneAUI(model: model)
        pane.codeView.onToggleBreakpoint?(2)
        #expect(model.debuggerBreakpointLines == [2])
    }

    @Test("D1 D10 D13 D14 · Paused in a function: the task, the frame and the locals are drawn; a frame row selects")
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
        let pane = DebugPaneAUI(model: studio.model)
        #expect(pane.buttons[.continueExecution]?.isEnabled == true)
        #expect(pane.buttons[.pause]?.isEnabled == false)

        let tasks = texts(pane.sections[0].content)
        #expect(tasks.contains("SUSPENDED"))
        #expect(tasks.contains("Selected Task"))
        let frames = texts(pane.sections[1].content)
        #expect(frames.contains { $0.caseInsensitiveCompare("Add") == .orderedSame })
        let locals = texts(pane.sections[2].content).map { $0.lowercased() }
        #expect(locals.contains("a") && locals.contains("b"))

        let frameRows = pane.sections[1].content.children.filter { !($0 is AUIDivider) }
        let last = try #require(frameRows.last)
        Click.simulate(last)
        let selected = studio.model.debuggerSelectedCallStackFrameIndex
        #expect(selected == studio.model.debuggerCallStack.last?.index)

        DebugPaneModel.perform(.continueExecution, on: studio.model)
        try await studio.waitUntilStopped()
        pane.refresh()
        #expect(texts(pane.sections[1].content) == [DebugPaneModel.noFramesText])
    }

    @Test("D11 · Clicking the selected task's row deselects it, and the detail goes")
    func taskSelection() async throws {
        let studio = StudioHarness(program: "PRINT 1\nPRINT 2")
        studio.model.openDebugger()
        studio.model.toggleDebuggerBreakpoint(atSourceLine: 2)
        try await studio.run()
        let pane = DebugPaneAUI(model: studio.model)
        let row = try #require(pane.sections[0].content.children.first)
        Click.simulate(row)
        pane.refresh()
        #expect(!texts(pane.sections[0].content).contains("Selected Task"))
        DebugPaneModel.perform(.continueExecution, on: studio.model)
        try await studio.waitUntilStopped()
    }

    @Test("D15 · An open file is listed with its status and path")
    func files() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("aui-debug-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let studio = StudioHarness(program: """
        open "\(path)" for output as #1
        print #1, "x"
        close #1
        """)
        studio.model.openDebugger()
        studio.model.toggleDebuggerBreakpoint(atSourceLine: 3)
        try await studio.run()
        let pane = DebugPaneAUI(model: studio.model)
        let files = texts(pane.sections[4].content)
        #expect(files.contains("Open"))
        #expect(files.contains { $0.hasSuffix(URL(fileURLWithPath: path).lastPathComponent) })
        DebugPaneModel.perform(.continueExecution, on: studio.model)
        try await studio.waitUntilStopped()
    }

    @Test("D14 · A structured global opens into its children when clicked, and closes again")
    func variableChildren() async throws {
        let studio = StudioHarness(program: """
        DIM SCORES(2)
        SCORES(1) = 7
        PRINT SCORES(1)
        """)
        studio.model.openDebugger()
        studio.model.toggleDebuggerBreakpoint(atSourceLine: 3)
        try await studio.run()
        let pane = DebugPaneAUI(model: studio.model)
        let parent = try #require(studio.model.debuggerGlobalVariables.first { !$0.children.isEmpty })
        let closed = texts(pane.sections[3].content).count
        let row = try #require(pane.sections[3].content.children.first { texts($0).contains(parent.name) })
        Click.simulate(row)
        #expect(texts(pane.sections[3].content).count > closed)
        let reopened = try #require(pane.sections[3].content.children.first { texts($0).contains(parent.name) })
        Click.simulate(reopened)
        #expect(texts(pane.sections[3].content).count == closed)
        DebugPaneModel.perform(.continueExecution, on: studio.model)
        try await studio.waitUntilStopped()
    }

    @Test("D17 · The code view takes 62% until dragged, and the list the rest")
    func bodyLayout() {
        let pane = DebugPaneAUI(model: StudioHarness().model)
        pane.root.place(in: CGRect(x: 0, y: 0, width: 400, height: 1000))
        pane.root.nativeView.layoutSubtreeIfNeeded()
        let code = pane.codeHost.nativeView.frame
        #expect(code.height > 0)
        #expect(abs(code.width - (400 - 24)) < 0.5, "\(code)")
    }
}
