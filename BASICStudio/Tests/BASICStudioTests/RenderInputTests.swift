//
//  RenderInputTests.swift
//  BASICStudioTests
//
//  P1 unit 8: what the editor and the console are handed.
//

import AppKit
import Foundation
import Testing
@testable import BASICStudio

@Suite("Render inputs", .serialized)
@MainActor
struct RenderInputTests {
    @Test("E4 E5 E8 · The main editor: editable, the gutter as set, diagnostics and find, no debugger marks")
    func mainEditor() {
        let model = StudioHarness(program: "PRINT (").model
        model.isEditorGutterVisible = true
        model.showFind()
        model.toggleDebuggerBreakpoint(atSourceLine: 1)
        let input = EditorRenderInput.mainEditor(model)
        #expect(input.text == "PRINT (")
        #expect(!input.isReadOnly && input.showsLineNumbers)
        #expect(!input.diagnostics.isEmpty)
        #expect(input.findRequest == 1 && input.replaceRequest == 0)
        #expect(input.executionLine == nil && input.breakpointLines.isEmpty)
        #expect(input.fontFamily == model.fontFamily && input.fontSize == model.fontSize && input.theme == model.editorTheme)
    }

    @Test("D5 D6 · The debug code view: read-only, numbered, the paused line and the breakpoints")
    func debugCodeView() async throws {
        let studio = StudioHarness(program: """
        PRINT 1
        PRINT 2
        """)
        studio.model.isEditorGutterVisible = false
        studio.model.openDebugger()
        studio.model.toggleDebuggerBreakpoint(atSourceLine: 2)
        try await studio.run()
        let input = EditorRenderInput.debugCodeView(studio.model)
        #expect(input.isReadOnly && input.showsLineNumbers)
        #expect(input.executionLine == 2 && input.breakpointLines == [2])
        #expect(input.diagnostics.isEmpty && input.findRequest == 0 && input.replaceRequest == 0)
        studio.model.continueDebugging()
        try await studio.waitUntilStopped()
    }

    @Test("C6 C18 · The console input mirrors the model")
    func consoleInput() async throws {
        let studio = StudioHarness(program: "PRINT \"X\"")
        try await studio.run()
        studio.model.setGraphicsLayersVisible(false)
        let input = ConsoleRenderInput(studio.model)
        #expect(input.consoleText == studio.model.consoleText)
        #expect(input.trimmedCharacters == studio.model.consoleTrimmedCharacters)
        #expect(input.scrollbackLines == studio.model.consoleScrollbackLines)
        #expect(input.screenSize == studio.model.terminalScreenSize)
        #expect(!input.graphicsLayersVisible)
    }

    @Test("P2 precondition · The console view builds, attaches and renders with no window")
    func consoleViewRendersHeadless() async throws {
        let studio = StudioHarness(program: "PRINT \"HEADLESS\"")
        try await studio.run()
        let view = AIBasicTerminalContainerView()
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.attach(to: studio.model)
        view.render(ConsoleRenderInput(studio.model))
        view.render(ConsoleRenderInput(studio.model))
        #expect(view.model === studio.model)
    }

    @Test("P2 precondition · The editor controller makes its web view, and takes input before the page is ready")
    func editorControllerBeforeReady() {
        let controller = MonacoEditorController()
        let webView = controller.makeWebView()
        #expect(controller.webView === webView)
        controller.sync(EditorRenderInput.mainEditor(StudioHarness(program: "PRINT 1").model))
        controller.dismantle(webView)
    }
}
