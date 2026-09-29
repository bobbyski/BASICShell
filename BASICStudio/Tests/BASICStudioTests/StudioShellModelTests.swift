//
//  StudioShellModelTests.swift
//  BASICStudioTests
//
//  P1 unit 4: the window's chrome as values.
//

import CoreGraphics
import Foundation
import Testing
@testable import BASICStudio

@Suite("StudioShellModel", .serialized)
@MainActor
struct StudioShellModelTests {
    @Test("The toolbar's order, symbols and help, as the SwiftUI shell has always drawn them")
    func toolbarOrder() {
        let shell = StudioShellModel(StudioHarness().model)
        #expect(shell.toolbar.map(\.command) == StudioShellModel.Command.allCases)
        #expect(shell.toolbar.map(\.symbol) == [
            "play.fill", "bolt.fill", "stop.fill",
            "terminal", "square.and.pencil", "ladybug", "book", "list.bullet.rectangle",
            "keyboard", "eye.fill", "list.number", "magnifyingglass",
        ])
        #expect(shell.toolbar.map(\.help) == [
            "Run", "Compile, then run — no debugger on this path", "Stop",
            "Console", "Editor", "Debug", "Documentation", "Log",
            "Command Bar", "Graphics Visible", "Editor Line Numbers", "Find",
        ])
        #expect(StudioShellModel.dividerAfter == .stop)
    }

    @Test("T1 T2 T3 · Idle: Run and JIT on, Stop off and gray")
    func idleButtons() {
        let shell = StudioShellModel(StudioHarness().model)
        #expect(shell.button(.run).isEnabled && shell.button(.run).tint == .normal)
        #expect(shell.button(.jit).isEnabled && shell.button(.jit).tint == .normal)
        #expect(!shell.button(.stop).isEnabled && shell.button(.stop).tint == .dimmed)
        #expect(shell.isCommandBarJITEnabled)
    }

    @Test("T1 T2 T3 · Running: Run and JIT off and gray, Stop on and red")
    func runningButtons() async throws {
        let studio = StudioHarness(program: """
        PRINT "GO"
        10 GOTO 10
        """)
        studio.model.runEditorProgram()
        try await studio.waitUntil("the program to start") { studio.model.consoleText.contains("GO") }
        let shell = StudioShellModel(studio.model)
        #expect(!shell.button(.run).isEnabled && shell.button(.run).tint == .dimmed)
        #expect(!shell.button(.jit).isEnabled && shell.button(.jit).tint == .dimmed)
        #expect(shell.button(.stop).isEnabled && shell.button(.stop).tint == .alert)
        #expect(!shell.isCommandBarJITEnabled)

        StudioShellModel.perform(.stop, on: studio.model)
        try await studio.waitUntilStopped()
        #expect(StudioShellModel(studio.model).button(.run).isEnabled)
    }

    @Test("T4 T5 · The pane buttons switch panes and show which is up")
    func paneButtons() {
        let model = StudioHarness().model
        StudioShellModel.perform(.editor, on: model)
        var shell = StudioShellModel(model)
        #expect(shell.mainPane == .editor)
        #expect(shell.button(.editor).tint == .selected && shell.button(.console).tint == .normal)
        StudioShellModel.perform(.console, on: model)
        shell = StudioShellModel(model)
        #expect(shell.mainPane == .console)
        #expect(shell.button(.console).tint == .selected && shell.button(.editor).tint == .normal)
    }

    @Test("T6 T7 T8 T15 · Inspector buttons toggle, and one replaces another")
    func inspectorButtons() {
        let model = StudioHarness().model
        StudioShellModel.perform(.debug, on: model)
        #expect(StudioShellModel(model).inspector == .debug)
        #expect(StudioShellModel(model).button(.debug).tint == .selected)
        StudioShellModel.perform(.logs, on: model)
        #expect(StudioShellModel(model).inspector == .logs)
        #expect(StudioShellModel(model).button(.debug).tint == .normal)
        StudioShellModel.perform(.logs, on: model)
        #expect(StudioShellModel(model).inspector == nil)
        StudioShellModel.perform(.docs, on: model)
        #expect(StudioShellModel(model).button(.docs).tint == .selected)
    }

    @Test("T9 T10 T11 · Command bar, graphics and gutter toggles")
    func toggles() {
        let model = StudioHarness().model
        StudioShellModel.perform(.commandBar, on: model)
        #expect(StudioShellModel(model).showsCommandBar)
        #expect(StudioShellModel(model).button(.commandBar).tint == .selected)

        StudioShellModel.perform(.graphics, on: model)
        let hidden = StudioShellModel(model).button(.graphics)
        #expect(hidden.symbol == "eye.slash.fill" && hidden.help == "Graphics Hidden" && hidden.tint == .alert)
        StudioShellModel.perform(.graphics, on: model)
        #expect(StudioShellModel(model).button(.graphics).tint == .on)

        let gutter = model.isEditorGutterVisible
        StudioShellModel.perform(.gutter, on: model)
        #expect(model.isEditorGutterVisible == !gutter)
    }

    @Test("T12 · Find goes to the editor and asks for the find widget")
    func find() {
        let model = StudioHarness().model
        StudioShellModel.perform(.find, on: model)
        #expect(model.selectedPane == .editor)
        #expect(model.editorFindRequest == 1)
    }

    @Test("T13 T14 · Theme and screen-size menus list every choice and check the current one")
    func menus() {
        let model = StudioHarness().model
        StudioShellModel.chooseTheme(EditorTheme.allCases.count - 1, on: model)
        let theme = StudioShellModel(model).themeMenu
        #expect(theme.items.count == EditorTheme.allCases.count)
        #expect(theme.items.filter(\.isChecked).map(\.title) == [EditorTheme.allCases.last!.label])
        #expect(theme.label == EditorTheme.allCases.last!.label)
        #expect(theme.symbol == "paintpalette" && theme.help == "Editor Theme")

        StudioShellModel.chooseScreenSize(0, on: model)
        let size = StudioShellModel(model).screenSizeMenu
        #expect(size.items.count == TerminalScreenSize.allCases.count)
        #expect(size.items.filter(\.isChecked).map(\.title) == [TerminalScreenSize.allCases[0].label])
        #expect(size.symbol == "rectangle.inset.filled" && size.help == "Screen Size")
    }

    @Test("I1 · The inspector keeps at least 260 and leaves the main pane 420")
    func inspectorWidth() {
        #expect(StudioShellModel.clampedInspectorWidth(360, availableWidth: 1200) == 360)
        #expect(StudioShellModel.clampedInspectorWidth(100, availableWidth: 1200) == 260)
        #expect(StudioShellModel.clampedInspectorWidth(900, availableWidth: 1200) == 780)
        // Too narrow for both: the inspector still gets its 260.
        #expect(StudioShellModel.clampedInspectorWidth(360, availableWidth: 500) == 260)
    }

    @Test("I1 · Dragging the divider left widens the inspector, within the same limits")
    func dragging() {
        #expect(StudioShellModel.draggedInspectorWidth(startWidth: 360, translation: -40, availableWidth: 1200) == 400)
        #expect(StudioShellModel.draggedInspectorWidth(startWidth: 360, translation: 200, availableWidth: 1200) == 260)
        #expect(StudioShellModel.draggedInspectorWidth(startWidth: 360, translation: -900, availableWidth: 1200) == 780)
    }

    @Test("W2 I2 · Window minimum 760×520; the inspector opens at 360")
    func sizes() {
        #expect(StudioShellModel.minimumWindowSize == CGSize(width: 760, height: 520))
        #expect(StudioShellModel.defaultInspectorWidth == 360)
    }
}
