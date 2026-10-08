//
//  AsyncTutorialTests.swift
//  BASICStudioTests
//
//  BASIC-37: every step of the async tutorial runs exactly as printed, and
//  prints in the order the page shows: in this tutorial the order is the
//  lesson. The steps are read out of the shipped manual.
//

import BASICCore
import Foundation
import Testing
@testable import BASICStudio

@MainActor
@Suite("BASIC-37 · The async tutorial's steps run as printed", .serialized)
struct AsyncTutorialTests {
    /// Every whole program on the page, in order: the seven steps, then the
    /// mistake about a task's copy of the variables.
    static func programs() throws -> [String] {
        let page = try #require(UserDoc.loadAll().first { $0.id == "TUTORIAL_ASYNC.md" }, "the tutorial ships")
        var programs: [String] = []
        var rest = Substring(page.content)
        while let open = rest.range(of: "```basic\n") {
            let body = rest[open.upperBound...]
            guard let close = body.range(of: "```") else { break }
            programs.append(String(body[..<close.lowerBound]))
            rest = body[close.upperBound...]
        }
        return programs
    }

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("async-tutorial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Runs `program` in a folder of its own and answers what it printed.
    private func run(_ program: String, in folder: URL? = nil) async throws -> String {
        let studio = StudioHarness(program: program)
        if let folder { try studio.model.changeDirectory(path: folder.path) }
        try await studio.run(timeout: .seconds(30))
        return studio.lastRunOutput
    }

    @Test("The page has seven steps and one more whole program, in the mistakes")
    func eightPrograms() throws {
        #expect(try Self.programs().count == 8)
    }

    @Test("Step 1: AWAIT waits for the timer")
    func waiting() async throws {
        #expect(try await run(try Self.programs()[0]).hasPrefix("Wait for it...\nTwo seconds later.\n"))
    }

    @Test("Step 2: the cup comes out before the kettle boils")
    func oneTask() async throws {
        let printed = try await run(try Self.programs()[1])
        #expect(printed.hasPrefix("Putting the kettle on.\nWhile it boils, getting out a cup.\nThe kettle has boiled.\nPouring the tea.\n"), "\(printed)")
    }

    @Test("Step 3: the toast pops up first, though started second")
    func twoTasks() async throws {
        let printed = try await run(try Self.programs()[2])
        #expect(printed.hasPrefix("""
        Putting the kettle on, and the bread in the toaster.
        Both are going. Setting the table.
        The toast has popped up.
        The kettle has boiled.
        Breakfast: toast and tea.

        """), "\(printed)")
    }

    @Test("Step 4: running, suspended, completed, cancelled")
    func statuses() async throws {
        let printed = try await run(try Self.programs()[3])
        #expect(printed.hasPrefix("""
        Just started: RUNNING
        While it boils: SUSPENDED
        Once it has boiled: COMPLETED
        A second kettle, switched off: CANCELLED

        """), "\(printed)")
    }

    @Test("Step 5: BACKGROUND starts the doorbell and does not wait for it")
    func background() async throws {
        let printed = try await run(try Self.programs()[4])
        #expect(printed.hasPrefix("Carrying on without waiting.\nDing dong!\nDone.\n"), "\(printed)")
    }

    @Test("Step 6: the list is written and read back from the program's folder")
    func files() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let printed = try await run(try Self.programs()[5], in: folder)
        #expect(printed.hasPrefix("Wrote 10 bytes.\nThe list says:\nBread\nTea\n"), "\(printed)")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("shopping.txt").path))
    }

    @Test("Step 7: a page, or the message for when it cannot be fetched; a made-up address always gives the message")
    func webPage() async throws {
        let step = try Self.programs()[6]
        let printed = try await run(step)
        #expect(printed.contains("Status: 200") || printed.contains("Could not fetch the page."), "\(printed)")
        let invalid = try await run(step.replacingOccurrences(of: "https://example.com/", with: "https://example.invalid/"))
        #expect(invalid.hasPrefix("Asking for the page...\nCould not fetch the page. Is the computer on the internet?\n"), "\(invalid)")
    }

    @Test("Mistake: without AWAIT the ticket is printed, and the end warns it was never collected")
    func forgottenAwait() async throws {
        let program = try Self.programs()[1].replacingOccurrences(
            of: "water$ = AWAIT kettle\nPRINT \"Pouring the \"; water$; \".\"",
            with: "PRINT \"The kettle gave me: \"; kettle"
        )
        let studio = StudioHarness(program: program)
        try await studio.run()
        #expect(studio.lastRunOutput.contains("The kettle gave me: <TASK #"), "\(studio.lastRunOutput)")
        #expect(studio.model.consoleText.contains("is still running; use AWAIT, JOIN, CANCEL, or BACKGROUND"))
    }

    @Test("Mistake: a task started with no ticket stops the program")
    func ignoredTask() async throws {
        let program = try Self.programs()[1].replacingOccurrences(of: "GLOBAL kettle AS TASK = BoilKettle()", with: "BoilKettle()")
        let studio = StudioHarness(program: program)
        try await studio.run()
        #expect(studio.model.consoleText.contains("Task result was ignored; use AWAIT, assign it to a TASK variable, or launch it with BACKGROUND"))
    }

    @Test("Mistake: a task changes its own copy of the variables, not the program's")
    func copiedVariables() async throws {
        let printed = try await run(try Self.programs()[7])
        #expect(printed.hasPrefix("Inside the task, cups is 2\nCups poured: 0\n"), "\(printed)")
    }
}
