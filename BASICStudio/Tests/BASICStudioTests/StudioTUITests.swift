//
//  StudioTUITests.swift
//  BASICStudioTests
//
//  A TUI program in the console pane (TUIKIT_PLAN.md phase 5).
//

import Foundation
import Testing
@testable import BASICStudio

@MainActor
@Suite("TUI programs in the console", .serialized)
struct StudioTUITests {
    /// One button, which stops the application when pressed.
    static let program = """
    GLOBAL app = TUIApp()
    let win = TUIWindow()
    let quit = TUIButton("Quit")
    quit.onclick("Quit")
    win.add(quit)
    app.run(win)
    print "CLOSED"

    function Quit()
        app.stop()
    end function
    """

    /// The alternate screen: in the console for as long as a session is up.
    static let alternateScreen = "\u{1B}[?1049h"

    @Test("P5 · A TUI program draws in the console, takes its keys, and gives the console back")
    func drawsTakesKeysAndGivesBack() async throws {
        let studio = StudioHarness(program: Self.program)
        studio.model.runEditorProgram()
        try await studio.waitUntil("the application to start") { studio.model.activeTUIDriver != nil }
        try await studio.waitUntil("the first frame") { studio.model.consoleText.contains("Quit") }
        #expect(studio.model.consoleText.contains(Self.alternateScreen))

        // Return presses the focused button, as the key a terminal sends.
        studio.model.activeTUIDriver?.incoming.yield(.bytes([13]))
        try await studio.waitUntilStopped()

        #expect(studio.model.activeTUIDriver == nil)
        #expect(studio.lastRunOutput.hasPrefix("CLOSED"))
        #expect(!studio.model.consoleText.contains(Self.alternateScreen), "the session's frames were taken back out")
    }

    @Test("P5 · Stop ends a TUI program")
    func stopEndsIt() async throws {
        let studio = StudioHarness(program: Self.program)
        studio.model.runEditorProgram()
        try await studio.waitUntil("the application to start") { studio.model.activeTUIDriver != nil }
        studio.model.stopProgram()
        try await studio.waitUntilStopped()
        #expect(studio.model.activeTUIDriver == nil)
        #expect(!studio.model.consoleText.contains(Self.alternateScreen))
    }
}
