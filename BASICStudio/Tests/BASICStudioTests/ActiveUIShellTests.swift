//
//  ActiveUIShellTests.swift
//  BASICStudioTests
//
//  Level 3 (ACTIVEUI_TRANSITION.md §10): the ActiveUI shell built with no
//  window, and its controls asserted. The SwiftUI shell has no equivalent.
//

import ActiveUI
import AppKit
import Foundation
import Testing
@testable import BASICStudio

@Suite("ActiveUI shell", .serialized)
@MainActor
struct ActiveUIShellTests {
    private func shell(program: String = "") -> StudioActiveUIShell {
        StudioActiveUIShell(model: StudioHarness(program: program).model)
    }

    /// Lets the shell's scheduled refresh run.
    private func settle(_ shell: StudioActiveUIShell) async throws {
        let before = shell.refreshCount
        shell.scheduleRefresh()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while shell.refreshCount == before, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("P2.3 · The menu bar: the SwiftUI shell's menus, in its order")
    func menuBarOrder() {
        let menus = shell().menuBar.menus
        #expect(menus.map(\.title) == ["BASICStudio", "File", "Edit", "View", "Examples", "Console", "Debug", "Window", "Help"])
    }

    @Test("P2.3 M6–M9 · File: Load, Open Project, Save, Save As, Set Working Directory, with their shortcuts, then Close")
    func fileMenu() throws {
        let file = try #require(shell().menuBar.menus.first { $0.title == "File" })
        let titles = file.items.map(\.title).filter { !$0.isEmpty }
        #expect(Array(titles.prefix(5)) == ["Load...", "Open Project…", "Save", "Save As...", "Set Working Directory..."])
        let openProject = try #require(file.items.first { $0.title == "Open Project…" })
        #expect(openProject.shortcut == AUIKeyboardShortcut("o", modifiers: [.command, .shift]))
        #expect(titles.last == "Close")
        let saveAs = try #require(file.items.first { $0.title == "Save As..." })
        #expect(saveAs.shortcut == AUIKeyboardShortcut("s", modifiers: [.command, .shift]))
    }

    @Test("P2.3 M3 · Edit ends with Studio's Find pair, and has no second ⌘F")
    func editMenu() throws {
        let edit = try #require(shell().menuBar.menus.first { $0.title == "Edit" })
        let find = edit.items.filter { $0.shortcut == AUIKeyboardShortcut("f", modifiers: .command) }
        #expect(find.map(\.title) == ["Find"])
        #expect(edit.items.last?.title == "Find and Replace")
    }

    @Test("P2.3 M4 · Console's toggles check themselves from the model when the menu opens")
    func consoleMenuChecks() throws {
        let studio = shell()
        let console = try #require(studio.menuBar.menus.first { $0.title == "Console" })
        let overwrite = try #require(console.items.first { $0.title == "Overwrite Mode" })
        #expect(overwrite.stateProvider?() == .off)
        studio.model.setConsoleOverwriteMode(true)
        #expect(overwrite.stateProvider?() == .on)
        overwrite.perform()
        #expect(!studio.model.isConsoleOverwriteMode)
    }

    @Test("P2.5 · The toolbar: every StudioShellModel button, then the two pull-downs")
    func toolbar() {
        let studio = shell()
        #expect(Set(studio.toolbarItems.keys) == Set(StudioShellModel.Command.allCases))
        #expect(studio.toolbarItems[.run]?.tooltip == "Run")
        #expect(studio.toolbarItems[.run]?.isEnabled == true)
        #expect(studio.toolbarItems[.stop]?.isEnabled == false)
        #expect(studio.toolbarItems[.graphics]?.image != nil)
        #expect(studio.themeItem.label == studio.model.editorTheme.label)
    }

    @Test("P2.4 · The console fills its pane: the Auto Layout hand-off does not leave an empty box")
    func consoleFillsItsPane() {
        let studio = shell()
        studio.root.place(in: CGRect(x: 0, y: 0, width: 1000, height: 700))
        // A nested child is laid out in the native layout pass, which a
        // window runs by itself; with no window, run it here.
        studio.root.nativeView.layoutSubtreeIfNeeded()
        #expect(!studio.consoleHost.isHidden)
        #expect(studio.editorHost.isHidden)
        #expect(studio.commandBar.isHidden)
        // The sidebar takes its column; the console fills the rest of the
        // window, less the main pane's 16-point padding on each side.
        let frame = studio.console.frame
        let content = studio.sidebar.contentPane.nativeView.frame
        #expect(content.width > 700 && content.width < 1000, "content \(content)")
        #expect(abs(frame.width - (content.width - 32)) < 1 && abs(frame.height - (700 - 32)) < 1,
                "console \(frame), content \(content), root \(studio.root.nativeView.frame)")
        #expect(studio.console.translatesAutoresizingMaskIntoConstraints)
    }

    @Test("P2.6 · A model change refreshes the shell on the next turn: the editor shows, Stop lights while running")
    func refreshFollowsTheModel() async throws {
        let studio = shell(program: """
        PRINT "GO"
        10 GOTO 10
        """)
        StudioShellModel.perform(.editor, on: studio.model)
        try await settle(studio)
        #expect(studio.consoleHost.isHidden && !studio.editorHost.isHidden)

        StudioShellModel.perform(.console, on: studio.model)
        StudioShellModel.perform(.commandBar, on: studio.model)
        studio.model.runEditorProgram()
        try await settle(studio)
        #expect(!studio.consoleHost.isHidden && !studio.commandBar.isHidden)
        #expect(studio.toolbarItems[.stop]?.isEnabled == true)
        #expect(studio.toolbarItems[.run]?.isEnabled == false)
        #expect(studio.commandBarJIT.isEnabled == false)

        studio.model.stopProgram()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while studio.model.isProgramRunning, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await settle(studio)
        #expect(studio.toolbarItems[.stop]?.isEnabled == false)
    }

    @Test("P2.6 · Refreshing with nothing changed redraws nothing")
    func idleRefreshIsFree() {
        let studio = shell()
        let image = studio.toolbarItems[.run]?.image
        studio.refresh()
        studio.refresh()
        #expect(studio.toolbarItems[.run]?.image === image)
    }

    @Test("P2.5 B5 · The command field and the model's command stay one value")
    func commandField() async throws {
        let studio = shell()
        studio.commandField.onChange?("PRINT 1")
        #expect(studio.model.command == "PRINT 1")
        studio.model.command = "LIST"
        try await settle(studio)
        #expect(studio.commandField.text == "LIST")
    }

    @Test("P2.8 · A synchronous caller on another thread reaches the shell with one hop")
    func reachableFromAnotherThread() async {
        let studio = shell()
        let pane: StudioPane = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let shown = StudioActiveUIShell.onMain {
                    StudioShellModel.perform(.editor, on: studio.model)
                    studio.refresh()
                    return studio.model.selectedPane
                }
                continuation.resume(returning: shown)
            }
        }
        #expect(pane == .editor)
        #expect(!studio.editorHost.isHidden)
    }
}
