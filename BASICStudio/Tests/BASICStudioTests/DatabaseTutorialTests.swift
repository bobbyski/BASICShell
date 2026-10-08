//
//  DatabaseTutorialTests.swift
//  BASICStudioTests
//
//  BASIC-41: every step of the database tutorial runs exactly as printed, in
//  order, on one database file, as a reader runs them, and prints what the
//  page says. The steps are read out of the shipped manual.
//

import BASICCore
import Foundation
import Testing
@testable import BASICStudio

@MainActor
@Suite("BASIC-41 · The database tutorial's steps run as printed", .serialized)
struct DatabaseTutorialTests {
    /// The tutorial's whole programs, in order: every `basic` block that
    /// opens a database.
    static func steps() throws -> [String] {
        let page = try #require(UserDoc.loadAll().first { $0.id == "TUTORIAL_DATABASE.md" }, "the tutorial ships")
        var programs: [String] = []
        var rest = Substring(page.content)
        while let open = rest.range(of: "```basic\n") {
            let body = rest[open.upperBound...]
            guard let close = body.range(of: "```") else { break }
            let code = String(body[..<close.lowerBound])
            if code.contains("SqlDatabase(") {
                programs.append(code)
            }
            rest = body[close.upperBound...]
        }
        return programs
    }

    /// A folder of its own for the database files, as the program's folder.
    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("db-tutorial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func studio(in folder: URL) throws -> StudioHarness {
        let studio = StudioHarness()
        try studio.model.changeDirectory(path: folder.path)
        return studio
    }

    /// Runs `program` and answers its `INPUT`s, each after its prompt.
    private func run(_ program: String, in studio: StudioHarness, answering answers: [(prompt: String, line: String)] = []) async throws -> String {
        studio.model.programText = program
        studio.model.runEditorProgram()
        for answer in answers {
            try await studio.answer(answer.line, afterPrompt: answer.prompt)
        }
        try await studio.waitUntilStopped()
        return studio.lastRunOutput
    }

    @Test("The tutorial has its seven steps")
    func sevenSteps() throws {
        #expect(try Self.steps().count == 7)
    }

    @Test("Steps 1 to 6 in order on one file: made, kept between runs, listed, added to, searched, changed and removed")
    func theReadingList() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let steps = try Self.steps()
        let studio = try studio(in: folder)
        let file = folder.appendingPathComponent("books.sqlite")

        // 1: the file appears in the program's folder.
        #expect(try await run(steps[0], in: studio).hasPrefix("The reading list is ready."))
        #expect(FileManager.default.fileExists(atPath: file.path))

        // 2, twice: the first run's book is still there for the second.
        #expect(try await run(steps[1], in: studio).hasPrefix("Books in the list: 1"))
        #expect(try await run(steps[1], in: studio).hasPrefix("Books in the list: 2"))

        // 3: the two Emmas, as the page shows.
        #expect(try await run(steps[2], in: studio).hasPrefix("1815  Emma, by Jane Austen\n1815  Emma, by Jane Austen\n"))

        // 4: two typed books, then the whole list in order.
        let added = try await run(steps[3], in: studio, answering: [
            ("Title (Return to stop)? ", "Pride and Prejudice"), ("Author? ", "Jane Austen"), ("Year? ", "1813"),
            ("Title (Return to stop)? ", "Dune"), ("Author? ", "Frank Herbert"), ("Year? ", "1965"),
            ("Title (Return to stop)? ", ""),
        ])
        #expect(added.contains("1813  Pride and Prejudice, by Jane Austen\n1815  Emma, by Jane Austen\n1815  Emma, by Jane Austen\n1965  Dune, by Frank Herbert\n"), "\(added)")

        // 5: her books and no one else's; then a name not in the list.
        let austen = try await run(steps[4], in: studio, answering: [("Books by which author? ", "Jane Austen")])
        #expect(austen.contains("1813  Pride and Prejudice\n1815  Emma\n1815  Emma\n"), "\(austen)")
        #expect(!austen.contains("Dune"))
        let nobody = try await run(steps[4], in: studio, answering: [("Books by which author? ", "Ada Lovelace")])
        #expect(nobody.contains("Nothing by Ada Lovelace in the list."), "\(nobody)")

        // 6: both Emmas out, Dune's year changed.
        let changed = try await run(steps[5], in: studio, answering: [
            ("Take out which title (Return for none)? ", "Emma"),
            ("Change the year of which title (Return for none)? ", "Dune"), ("The right year? ", "1966"),
        ])
        #expect(changed.contains("Took out 2 books."), "\(changed)")
        #expect(changed.contains("Changed 1 books."), "\(changed)")
        #expect(changed.contains("1813  Pride and Prejudice, by Jane Austen\n1966  Dune, by Frank Herbert\n"), "\(changed)")

        // Starting over: the page's command, at the prompt, takes the file away.
        let page = try #require(UserDoc.loadAll().first { $0.id == "TUTORIAL_DATABASE.md" }).content
        #expect(page.contains("File.Rm \"books.sqlite\""))
        try await studio.submit("File.Rm \"books.sqlite\"")
        try await studio.waitUntil("the file to go") { !FileManager.default.fileExists(atPath: file.path) }
    }

    @Test("Step 7, twice: a data store numbers each book and keeps it")
    func dataStore() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let step = try Self.steps()[6]
        let studio = try studio(in: folder)
        let first = try await run(step, in: studio)
        #expect(first.hasPrefix("Saved Emma as book number 1\nLoaded it back: Emma, by Jane Austen, 1815\nBooks on the shelf: 1\n"), "\(first)")
        let second = try await run(step, in: studio)
        #expect(second.hasPrefix("Saved Emma as book number 2\n"), "\(second)")
        #expect(second.contains("Books on the shelf: 2"))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("shelf.sqlite").path))
    }

    @Test("The three mistakes stop with the messages the page quotes")
    func mistakes() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let steps = try Self.steps()
        let studio = try studio(in: folder)
        _ = try await run(steps[1], in: studio)

        // Glued: an apostrophe ends the title early.
        let gluedLine = """
            db.Execute("INSERT INTO Book (Title, Author, Year) VALUES ('" + title$ + "', '" + author$ + "', " + STR$(year) + ")")
        """
        let page = try #require(UserDoc.loadAll().first { $0.id == "TUTORIAL_DATABASE.md" }).content
        #expect(page.contains(gluedLine), "the page prints this line")
        let glued = steps[3].replacingOccurrences(
            of: "    db.Execute(\"INSERT INTO Book (Title, Author, Year) VALUES (?, ?, ?)\", title$, author$, year)",
            with: gluedLine
        )
        _ = try await run(glued, in: studio, answering: [
            ("Title (Return to stop)? ", "Charlotte's Web"), ("Author? ", "E. B. White"), ("Year? ", "1952"),
        ])
        #expect(studio.model.consoleText.contains("near \"s\": syntax error"))

        // A misspelled column.
        _ = try await run(steps[2].replacingOccurrences(of: "ORDER BY Year", with: "ORDER BY Yaer"), in: studio)
        #expect(studio.model.consoleText.contains("no such column: Yaer"))

        // Reading before Read.
        let early = steps[1].replacingOccurrences(
            of: "IF answer.Read() THEN PRINT \"Books in the list: \"; answer.Number(\"Books\")",
            with: "PRINT answer.Number(\"Books\")"
        )
        _ = try await run(early, in: studio)
        #expect(studio.model.consoleText.contains("Recordset.Number needs a successful Read first"))
    }
}
