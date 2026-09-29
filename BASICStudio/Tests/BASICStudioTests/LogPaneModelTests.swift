//
//  LogPaneModelTests.swift
//  BASICStudioTests
//
//  P1 unit 1: the Log inspector's projection. These are the "before"
//  measurements, captured when the logic moved out of LogPane.
//

import Foundation
import Testing
@testable import BASICStudio

@Suite("LogPaneModel")
@MainActor
struct LogPaneModelTests {
    private func model(entries: [(LogIssuer, String, String)] = []) -> StudioModel {
        let model = StudioHarness().model
        model.clearLogs()
        for (issuer, level, text) in entries {
            model.appendLog(level: level, issuer: issuer, text: text)
        }
        return model
    }

    @Test("L6 · With no entries, Clear is disabled and the Levels menu says so")
    func empty() {
        let pane = LogPaneModel(model())
        #expect(!pane.canClear)
        #expect(pane.levelsMenuHeader == nil)
        #expect(pane.levelsMenu.isEmpty)
        #expect(pane.rows.isEmpty)
        #expect(LogPaneModel.noLevelsTitle == "No Levels")
    }

    @Test("L7 · The Levels menu: all checked and 'All Selected' until one is chosen, then 'Show All'")
    func levelsMenu() {
        let studio = model(entries: [(.user, "INFO", "a"), (.user, "WARN", "b")])
        var pane = LogPaneModel(studio)
        #expect(pane.levelsMenuHeader == "All Selected")
        #expect(pane.levelsMenu == [.init(level: "INFO", isChecked: true), .init(level: "WARN", isChecked: true)])

        studio.toggleLogLevel("warn")
        pane = LogPaneModel(studio)
        #expect(pane.levelsMenuHeader == "Show All")
        #expect(pane.levelsMenu == [.init(level: "INFO", isChecked: false), .init(level: "WARN", isChecked: true)])
        #expect(pane.rows.map(\.text) == ["b"])
    }

    @Test("L2 · Rows are the filtered entries: BASIC's own are hidden until shown")
    func rowsFollowTheIssuerFilters() {
        let studio = model(entries: [(.user, "INFO", "mine"), (.basic, "RUN", "studio's")])
        #expect(LogPaneModel(studio).rows.map(\.text) == ["mine"])
        studio.showBasicLogs = true
        studio.showUserLogs = false
        #expect(LogPaneModel(studio).rows.map(\.text) == ["studio's"])
    }

    @Test("L4 · The trace button names what it will do")
    func traceButton() {
        let studio = model()
        #expect(LogPaneModel(studio).traceButtonTitle == "TRON")
        studio.toggleTraceLogging()
        #expect(LogPaneModel(studio).traceButtonTitle == "TROFF")
        #expect(LogPaneModel(studio).isTraceLoggingEnabled)
    }

    @Test("L5 · A row carries time, issuer, level, module and text")
    func rowFields() throws {
        let studio = model(entries: [(.user, "info", "hello")])
        let row = try #require(LogPaneModel(studio).rows.first)
        #expect(row.issuer == "U")
        #expect(row.level == "INFO")
        #expect(row.levelKind == .run)
        #expect(row.module == "BASIC")
        #expect(row.text == "hello")
        #expect(row.time.wholeMatch(of: /\d\d:\d\d:\d\d\.\d\d\d/) != nil)
    }

    @Test("L5 · A fixed timestamp formats as HH:mm:ss.SSS")
    func timeFormat() {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second, parts.nanosecond) = (2026, 9, 28, 13, 4, 5, 250_000_000)
        let date = Calendar.current.date(from: parts)!
        let entry = StudioLogEntry(timestamp: date, issuer: .basic, level: "RUN", module: "m", text: "t")
        #expect(LogPaneModel.row(entry).time == "13:04:05.250")
    }

    @Test("L5 · Level tints: the same words, any case, as LogPane always used")
    func levelKinds() {
        let expected: [(String, LogPaneModel.LevelKind)] = [
            ("ERROR", .error), ("err", .error), ("Fatal", .error),
            ("WARN", .warning), ("warning", .warning),
            ("DEBUG", .debug), ("TRACE", .debug), ("INPUT", .debug),
            ("TARGET", .target),
            ("RUN", .run), ("INFO", .run),
            ("PAUSE", .pause),
            ("GAMEPAD", .plain), ("", .plain),
        ]
        for (level, kind) in expected {
            #expect(LogPaneModel.LevelKind(level: level) == kind, "\(level)")
        }
    }

    @Test("L3 · Toggles mirror the model")
    func toggles() {
        let studio = model(entries: [(.user, "INFO", "x")])
        studio.isLoggingEnabled = false
        let pane = LogPaneModel(studio)
        #expect(!pane.isLoggingEnabled)
        #expect(pane.showsUserLogs)
        #expect(!pane.showsBasicLogs)
        #expect(pane.canClear)
    }
}
