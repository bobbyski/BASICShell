//
//  ActiveUITutorialTests.swift
//  BASICStudioTests
//
//  BASIC-34: every step of the ActiveUI tutorial runs exactly as printed, and
//  does what the page says it does. The steps are read out of the shipped
//  manual, so a step edited on the page is the step tested. The windows stay
//  off screen; the test is the person clicking and typing.
//

import ActiveUI
import AppKit
import BASICCore
import Foundation
import Testing
@testable import BASICStudio

@MainActor
@Suite("BASIC-34 · The ActiveUI tutorial's steps run as printed", .serialized)
struct ActiveUITutorialTests {
    /// The tutorial's whole programs, in order: every `basic` block that
    /// shows its window with `win.run()`.
    static func steps() throws -> [String] {
        let page = try #require(UserDoc.loadAll().first { $0.id == "TUTORIAL_ACTIVEUI.md" }, "the tutorial ships")
        var programs: [String] = []
        var rest = Substring(page.content)
        while let open = rest.range(of: "```basic\n") {
            let body = rest[open.upperBound...]
            guard let close = body.range(of: "```") else { break }
            let code = String(body[..<close.lowerBound])
            if code.contains("win.run()") {
                programs.append(code)
            }
            rest = body[close.upperBound...]
        }
        return programs
    }

    /// A step, running in a window kept off screen, and the person using it.
    @MainActor
    private struct Session {
        let studio: StudioHarness
        var bridge: StudioAUIBridge { studio.model.auiBridge }

        init(_ program: String, dialogAnswer: Int = 0) async throws {
            studio = StudioHarness(program: program)
            studio.model.auiBridge.showsWindows = false
            studio.model.auiBridge.presentDialog = { _, _, _, done in done(dialogAnswer) }
            studio.model.runEditorProgram()
            let bridge = studio.model.auiBridge
            try await studio.waitUntil("the window") {
                bridge.windows.keys.contains { (try? bridge.perform(.isOpen(id: $0))) == .flag(true) }
            }
        }

        func all<T: AUIView>(_ type: T.Type) -> [T] {
            bridge.views.sorted { $0.key < $1.key }.compactMap { $0.value as? T }
        }

        func button(_ title: String) throws -> AUIButton {
            try #require(all(AUIButton.self).first { $0.title == title }, "a button \(title)")
        }

        var labels: [String] { all(AUILabel.self).map(\.text) }
        var field: AUITextField? { all(AUITextField.self).first }
        var list: AUITable? { all(AUITable.self).first }

        func click(_ title: String) throws {
            try button(title).onClick?()
        }

        func type(_ text: String) {
            field?.text = text
        }

        func pressReturn() {
            field?.onSubmit?(field?.text ?? "")
        }

        func waitForLabel(_ text: String) async throws {
            try await studio.waitUntil("a label saying \"\(text)\"") { labels.contains(text) }
        }

        /// Closes the window, as the person does, and answers what the
        /// program printed after it.
        func close() async throws -> String {
            let window = try #require(bridge.windows.keys.first)
            _ = try bridge.perform(.close(id: window))
            try await studio.waitUntilStopped()
            return studio.lastRunOutput
        }
    }

    @Test("The tutorial has its six steps")
    func sixSteps() throws {
        #expect(try Self.steps().count == 6)
    }

    @Test("Step 1: a window with its label; closing it ends the program, which then prints")
    func windowAndLabel() async throws {
        let session = try await Session(try Self.steps()[0])
        #expect(session.labels == ["Nothing to do yet."])
        #expect(session.bridge.windows.values.first?.title == "To Do")
        #expect(try await session.close().hasPrefix("The window has closed."))
    }

    @Test("Step 2: Add changes the label")
    func button() async throws {
        let session = try await Session(try Self.steps()[1])
        #expect(session.labels == ["Press the button."])
        try session.click("Add")
        try await session.waitForLabel("You pressed Add.")
        _ = try await session.close()
    }

    @Test("Step 3: what was typed comes back; an empty box asks first")
    func field() async throws {
        let session = try await Session(try Self.steps()[2])
        try session.click("Add")
        try await session.waitForLabel("Type something to do first.")
        session.type("Buy milk")
        try session.click("Add")
        try await session.waitForLabel("You typed: Buy milk")
        _ = try await session.close()
    }

    @Test("Step 4: Add and Return both add to the list, and the box empties")
    func list() async throws {
        let session = try await Session(try Self.steps()[3])
        session.type("Buy milk")
        try session.click("Add")
        try await session.waitForLabel("Added Buy milk.")
        session.type("Walk the dog")
        session.pressReturn()
        try await session.waitForLabel("Added Walk the dog.")
        #expect(session.list?.rowCount() == 2)
        #expect(session.field?.text == "")
        _ = try await session.close()
    }

    @Test("Step 5: Clear All asks first; Cancel keeps the list, Clear empties it")
    func dialog() async throws {
        let cancelled = try await Session(try Self.steps()[4], dialogAnswer: 1)
        cancelled.type("Buy milk")
        try cancelled.click("Add")
        try await cancelled.waitForLabel("Added Buy milk.")
        try cancelled.click("Clear All")
        try await Task.sleep(for: .milliseconds(300))
        #expect(cancelled.list?.rowCount() == 1, "Cancel keeps the list")
        _ = try await cancelled.close()

        let cleared = try await Session(try Self.steps()[4], dialogAnswer: 0)
        cleared.type("Buy milk")
        try cleared.click("Add")
        try await cleared.waitForLabel("Added Buy milk.")
        try cleared.click("Clear All")
        try await cleared.waitForLabel("Cleared.")
        #expect(cleared.list?.rowCount() == 0)
        _ = try await cleared.close()
    }

    @Test("Step 6: the status line counts, a pick is named, and the count is printed after closing")
    func statusLine() async throws {
        let session = try await Session(try Self.steps()[5])
        try await session.waitForLabel("To do: 0")
        for task in ["Buy milk", "Walk the dog", "Call Ada"] {
            session.type(task)
            try session.click("Add")
            try await session.waitForLabel("Added \(task).")
        }
        try await session.waitForLabel("To do: 3")
        let list = try #require(session.list)
        list.selectedRows = [1]
        list.onSelectionChange?([1])
        try await session.waitForLabel("You picked Walk the dog.")
        let printed = try await session.close()
        #expect(printed.hasPrefix("The window has closed with 3 things still to do."), "\(printed)")
    }

    @Test("Mistake: without win.run() no window is shown and the last line prints at once")
    func withoutRun() async throws {
        let program = try Self.steps()[5].replacingOccurrences(of: "win.run()\n", with: "")
        let studio = StudioHarness(program: program)
        studio.model.auiBridge.showsWindows = false
        try await studio.run()
        #expect(studio.lastRunOutput.hasPrefix("The window has closed with 0 things still to do."), "\(studio.lastRunOutput)")
    }

    @Test("Mistake: a misspelled handler does nothing, and Return still adds")
    func misspelledHandler() async throws {
        let program = try Self.steps()[5].replacingOccurrences(of: "addButton.onclick(\"AddTask\")", with: "addButton.onclick(\"AddTsk\")")
        let session = try await Session(program)
        session.type("Buy milk")
        try session.click("Add")
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.list?.rowCount() == 0, "Add calls nothing")
        #expect(session.studio.model.isProgramRunning, "and the program carries on")
        session.pressReturn()
        try await session.waitForLabel("Added Buy milk.")
        _ = try await session.close()
    }

    @Test("Mistake: a control never added is changed but never seen")
    func controlLeftOut() async throws {
        let program = try Self.steps()[5].replacingOccurrences(of: "win.add(statusLine)\n", with: "")
        let session = try await Session(program)
        try await session.waitForLabel("To do: 0")
        let status = try #require(session.all(AUILabel.self).first { $0.text == "To do: 0" })
        let shown = status.parent != nil
        #expect(!shown, "the status line is not in the window")
        _ = try await session.close()
    }
}
