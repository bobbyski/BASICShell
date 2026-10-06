//
//  StudioGraphicsOnStopTests.swift
//  BASICStudioTests
//
//  A program that stops on a break or an error has its graphics hidden, so
//  the error and the prompt can be read; RUN or CLS shows them again, and
//  graphics the user hid stay hidden (BASIC-27).
//

import Foundation
import Testing
@testable import BASICStudio

@MainActor
@Suite("Graphics hidden when a program stops", .serialized)
struct StudioGraphicsOnStopTests {
    /// Draws a square, then divides by zero.
    private static let drawsThenFails = """
    vtg = VectorTerminal()
    vtg.rect("square", 0, 0, 10, 10, "none", "#ff0000", 0, 0, "", "", 1)
    vtg.present()
    PRINT 1 / 0
    """

    private func run(_ studio: StudioHarness) async throws {
        studio.model.vtgDataSink = { _ in }
        try await studio.run()
    }

    @Test("An error after drawing hides the graphics, says so once, and RUN shows them again")
    func errorThenRun() async throws {
        let studio = StudioHarness(program: Self.drawsThenFails)
        try await run(studio)
        #expect(studio.model.consoleText.contains("Division by zero"))
        #expect(!studio.model.areGraphicsLayersVisible)
        #expect(studio.model.graphicsHiddenOnStop)
        #expect(studio.model.graphicsHiddenNoticeCount == 1)

        studio.model.programText = "PRINT \"AGAIN\""
        try await studio.run()
        #expect(studio.model.areGraphicsLayersVisible)
        #expect(!studio.model.graphicsHiddenOnStop)
    }

    @Test("The notice is shown once a launch, however many times graphics are hidden")
    func noticeOnce() async throws {
        let studio = StudioHarness(program: Self.drawsThenFails)
        try await run(studio)
        try await run(studio)
        #expect(!studio.model.areGraphicsLayersVisible)
        #expect(studio.model.graphicsHiddenNoticeCount == 1)
    }

    @Test("CLS at the prompt shows the graphics again")
    func clsBringsThemBack() async throws {
        let studio = StudioHarness(program: Self.drawsThenFails)
        try await run(studio)
        #expect(!studio.model.areGraphicsLayersVisible)
        try await studio.submit("CLS")
        #expect(studio.model.areGraphicsLayersVisible)
    }

    @Test("Stopping a running program hides its graphics")
    func stopHides() async throws {
        let studio = StudioHarness(program: """
        vtg = VectorTerminal()
        WHILE 1
            vtg.rect("square", 0, 0, 10, 10, "none", "#ff0000", 0, 0, "", "", 1)
            vtg.present()
            LOCAL slept = AWAIT SLEEP(5)
        WEND
        """)
        studio.model.vtgDataSink = { _ in }
        studio.model.runEditorProgram()
        try await studio.waitUntil("the program to draw") { studio.model.isProgramRunning }
        try await Task.sleep(for: .milliseconds(100))
        studio.model.stopProgram()
        try await studio.waitUntilStopped()
        #expect(!studio.model.areGraphicsLayersVisible)
        #expect(studio.model.graphicsHiddenOnStop)
    }

    @Test("Graphics the user hid stay hidden across RUN, and the user's toggle wins")
    func userHiddenStaysHidden() async throws {
        let studio = StudioHarness(program: Self.drawsThenFails)
        studio.model.setGraphicsLayersVisible(false)
        try await run(studio)
        #expect(!studio.model.graphicsHiddenOnStop, "already hidden by the user: nothing was hidden for them")
        try await studio.run()
        #expect(!studio.model.areGraphicsLayersVisible)

        // Hidden on stop, then shown and hidden again by hand: the user's now.
        studio.model.setGraphicsLayersVisible(true)
        try await run(studio)
        #expect(studio.model.graphicsHiddenOnStop)
        studio.model.toggleGraphicsLayersVisible()
        studio.model.toggleGraphicsLayersVisible()
        #expect(!studio.model.areGraphicsLayersVisible)
        #expect(!studio.model.graphicsHiddenOnStop)
        try await studio.run()
        #expect(!studio.model.areGraphicsLayersVisible)
    }

    @Test("Nothing is hidden when the program ends normally, never drew, or the setting is off")
    func nothingHidden() async throws {
        let ends = StudioHarness(program: """
        vtg = VectorTerminal()
        vtg.rect("square", 0, 0, 10, 10, "none", "#ff0000", 0, 0, "", "", 1)
        vtg.present()
        END
        """)
        try await run(ends)
        #expect(ends.model.areGraphicsLayersVisible)

        let textOnly = StudioHarness(program: "PRINT 1 / 0")
        try await run(textOnly)
        #expect(textOnly.model.areGraphicsLayersVisible)
        #expect(textOnly.model.graphicsHiddenNoticeCount == 0)

        let settingOff = StudioHarness(program: Self.drawsThenFails)
        settingOff.model.hidesGraphicsOnStop = false
        try await run(settingOff)
        #expect(settingOff.model.areGraphicsLayersVisible)
    }

    @Test("The settings are saved and read back, on by default")
    func settingsRoundTrip() throws {
        let fresh = StudioSettings()
        #expect(fresh.hidesGraphicsOnStop)
        #expect(fresh.showsGraphicsHiddenNotice)
        let saved = StudioSettings(hidesGraphicsOnStop: false, showsGraphicsHiddenNotice: false)
        let data = try JSONEncoder().encode(saved)
        let read = try JSONDecoder().decode(StudioSettings.self, from: data)
        #expect(!read.hidesGraphicsOnStop)
        #expect(!read.showsGraphicsHiddenNotice)
        // Settings written before these existed read as on.
        let old = try JSONDecoder().decode(StudioSettings.self, from: Data("{}".utf8))
        #expect(old.hidesGraphicsOnStop && old.showsGraphicsHiddenNotice)
    }
}
