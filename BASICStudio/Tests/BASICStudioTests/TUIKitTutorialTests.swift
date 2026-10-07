//
//  TUIKitTutorialTests.swift
//  BASICStudioTests
//
//  BASIC-33: every step of the TUIKit tutorial runs exactly as printed, and
//  does what the page says it does. The programs are read out of the shipped
//  manual, so a step that is edited on the page is the step that is tested.
//

import BASICCore
import Foundation
import Testing
@testable import BASICStudio

@MainActor
@Suite("BASIC-33 · The TUIKit tutorial's steps run as printed", .serialized)
struct TUIKitTutorialTests {
    /// The keys a terminal sends.
    private static let tab: [UInt8] = [9]
    private static let returnKey: [UInt8] = [13]
    private static let escape: [UInt8] = [27]

    /// The tutorial's whole programs, in order: every `basic` block that ends
    /// by calling `Main()`.
    static func steps() throws -> [String] {
        let page = try #require(UserDoc.loadAll().first { $0.id == "TUTORIAL_TUIKIT.md" }, "the tutorial ships")
        var programs: [String] = []
        var rest = Substring(page.content)
        while let open = rest.range(of: "```basic\n") {
            let body = rest[open.upperBound...]
            guard let close = body.range(of: "```") else { break }
            let code = String(body[..<close.lowerBound])
            if code.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("Main()") {
                programs.append(code)
            }
            rest = body[close.upperBound...]
        }
        return programs
    }

    /// A step, running, and the keys a person presses.
    @MainActor
    private struct Session {
        let studio: StudioHarness

        init(_ program: String) async throws {
            studio = StudioHarness(program: program)
            studio.model.runEditorProgram()
            try await studio.waitUntil("the application to start") { studio.model.activeTUIDriver != nil }
        }

        var screen: String { studio.model.consoleText }

        func press(_ bytes: [UInt8]) async throws {
            studio.model.activeTUIDriver?.incoming.yield(.bytes(bytes))
            // Long enough for a lone Esc to be read as the Escape key.
            try await Task.sleep(for: .milliseconds(150))
        }

        func type(_ text: String) async throws {
            for byte in text.utf8 {
                try await press([byte])
            }
        }

        func waitFor(_ text: String) async throws {
            try await studio.waitUntil("\"\(text)\" on the screen") { screen.contains(text) }
        }

        /// Esc until the program has ended, and what it printed after.
        func quit(escapes: Int) async throws -> String {
            for _ in 0..<escapes {
                try await press(TUIKitTutorialTests.escape)
            }
            try await studio.waitUntilStopped()
            return studio.lastRunOutput
        }
    }

    @Test("The tutorial has its six steps")
    func sixSteps() throws {
        #expect(try Self.steps().count == 6)
    }

    @Test("Step 1: a blank application that Esc ends, then prints")
    func emptyApplication() async throws {
        let session = try await Session(try Self.steps()[0])
        let printed = try await session.quit(escapes: 1)
        #expect(printed.hasPrefix("The program has ended."), "\(printed)")
    }

    @Test("Step 2: a File menu whose Quit ends the program")
    func menu() async throws {
        let session = try await Session(try Self.steps()[1])
        // "ile": the F is drawn apart, underlined as the shortcut.
        try await session.waitFor("ile")
        // Alt-F, as a terminal sends it, then Q.
        try await session.press([27, Character("f").asciiValue!])
        try await session.waitFor("uit")
        try await session.press([Character("q").asciiValue!])
        try await session.studio.waitUntilStopped()
        #expect(session.studio.lastRunOutput.hasPrefix("The program has ended."))
    }

    @Test("Step 3: a status row with its two segments")
    func statusRow() async throws {
        let session = try await Session(try Self.steps()[2])
        try await session.waitFor(" Greeter")
        try await session.waitFor("Esc quits")
        _ = try await session.quit(escapes: 1)
    }

    @Test("Step 4: a window with its label; the first Esc closes it, the second ends the program")
    func window() async throws {
        let session = try await Session(try Self.steps()[3])
        try await session.waitFor("Greeter")
        try await session.waitFor("Press the button.")
        try await session.press(Self.escape)
        #expect(session.studio.model.activeTUIDriver != nil, "one Esc closes the window and leaves the program running")
        let printed = try await session.quit(escapes: 1)
        #expect(printed.hasPrefix("The program has ended."))
    }

    @Test("Step 5: Tab to the button, Return, and the label says hello")
    func button() async throws {
        let session = try await Session(try Self.steps()[4])
        try await session.waitFor("Greet me")
        try await session.press(Self.tab)
        try await session.press(Self.returnKey)
        try await session.waitFor("Hello from BASIC.")
        _ = try await session.quit(escapes: 2)
    }

    @Test("Step 6: the field's name comes back in the label; an empty field asks for one")
    func field() async throws {
        let session = try await Session(try Self.steps()[5])
        try await session.waitFor("Type your name, then press the button.")
        // Tab to the field, Tab past it to the button: an empty field.
        try await session.press(Self.tab)
        try await session.press(Self.tab)
        try await session.press(Self.returnKey)
        try await session.waitFor("Type your name first.")
        // Back to the field, a name, on to the button.
        try await session.press([27, 91, 90])   // Shift-Tab
        try await session.type("Ada")
        try await session.press(Self.tab)
        try await session.press(Self.returnKey)
        try await session.waitFor("Hello, Ada.")
        _ = try await session.quit(escapes: 2)
    }

    @Test("Mistake: without app.run nothing is shown and the program ends at once")
    func withoutRun() async throws {
        let program = try Self.steps()[4].replacingOccurrences(of: "    app.run(shell)\n", with: "")
        let studio = StudioHarness(program: program)
        try await studio.run()
        #expect(studio.lastRunOutput.hasPrefix("The program has ended."))
        #expect(studio.model.activeTUIDriver == nil)
    }

    @Test("Mistake: without the stack, the button covers the label")
    func withoutStack() async throws {
        let step = try Self.steps()[4]
        let stacked = """
            let column = TUIStack("v")
            greeting = TUILabel("Press the button.")
            column.add(greeting)
            let go = TUIButton("Greet me")
            go.onclick("SayHello")
            column.add(go)
            win.add(column)
        """
        #expect(step.contains(stacked))
        let unstacked = step.replacingOccurrences(of: stacked, with: """
            greeting = TUILabel("Press the button.")
            win.add(greeting)
            let go = TUIButton("Greet me")
            go.onclick("SayHello")
            win.add(go)
        """)
        let session = try await Session(unstacked)
        try await session.waitFor("Greet me")
        try await Task.sleep(for: .milliseconds(300))
        #expect(!session.screen.contains("Press the button."), "the label is drawn over")
        session.studio.model.stopProgram()
        try await session.studio.waitUntilStopped()
    }

    @Test("Mistake: a misspelled handler does nothing when pressed, and is the error the program ends with")
    func misspelledHandler() async throws {
        let program = try Self.steps()[4].replacingOccurrences(of: "go.onclick(\"SayHello\")", with: "go.onclick(\"SayHelo\")")
        let session = try await Session(program)
        try await session.waitFor("Greet me")
        try await session.press(Self.tab)
        try await session.press(Self.returnKey)
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.studio.model.activeTUIDriver != nil, "pressing the button leaves it running")
        #expect(!session.screen.contains("Hello from BASIC."))
        let printed = try await session.quit(escapes: 2)
        #expect(!printed.contains("The program has ended."), "\(printed)")
        #expect(printed.uppercased().contains("SAYHELO"), "\(printed)")
    }
}
