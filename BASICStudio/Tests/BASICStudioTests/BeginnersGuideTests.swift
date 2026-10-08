//
//  BeginnersGuideTests.swift
//  BASICStudioTests
//
//  BASIC-39: every example in the Beginner's Guide runs exactly as printed
//  and gives the output the page shows, with scripted answers for its
//  INPUTs; Guess the Number is played to the end; and each mistake to try
//  gives the message the page quotes. The examples are read out of the
//  shipped manual.
//

import Foundation
import Testing
@testable import BASICStudio

@MainActor
@Suite("BASIC-39 · The Beginner's Guide's examples run as printed", .serialized)
struct BeginnersGuideTests {
    static func page() throws -> String {
        try #require(UserDoc.loadAll().first { $0.id == "TUTORIAL_BEGINNERS.md" }, "the guide ships").content
    }

    /// Every `basic` block on the page, in order.
    static func examples() throws -> [String] {
        var examples: [String] = []
        var rest = Substring(try page())
        while let open = rest.range(of: "```basic\n") {
            let body = rest[open.upperBound...]
            guard let close = body.range(of: "```") else { break }
            examples.append(String(body[..<close.lowerBound]))
            rest = body[close.upperBound...]
        }
        return examples
    }

    /// Runs `program` from the editor and answers what it printed.
    private func run(_ program: String) async throws -> String {
        let studio = StudioHarness(program: program)
        try await studio.run()
        return studio.lastRunOutput
    }

    /// What a line typed at the console printed.
    private func typed(_ line: String, in studio: StudioHarness) async throws -> String {
        let before = studio.model.consoleText.count
        try await studio.submit(line)
        return String(studio.model.consoleText.dropFirst(before))
    }

    @Test("The page has its thirteen examples")
    func thirteen() throws {
        #expect(try Self.examples().count == 13)
    }

    @Test("Say Hello: two lines typed at the console")
    func sayHello() async throws {
        let examples = try Self.examples()
        let studio = StudioHarness()
        #expect(try await typed(examples[0].trimmingCharacters(in: .newlines), in: studio).contains("\nHello, world!\n"))
        #expect(try await typed(examples[1].trimmingCharacters(in: .newlines), in: studio).contains("\n14\n"))
        #expect(try await typed("print (2 + 3) * 4", in: studio).contains("\n20\n"))
    }

    @Test("The programs print what the page shows")
    func programs() async throws {
        let examples = try Self.examples()
        let expected: [Int: String] = [
            2: "Hello!\nThis is my first program.\n2 + 2 =4\n",
            3: "Ada is 36 years old.\nNext year Ada will be 37\n",
            7: "1 squared is 1\n2 squared is 4\n3 squared is 9\n4 squared is 16\n5 squared is 25\n",
            8: "3...\n2...\n1...\nLiftoff!\n",
            9: "0: apple\n1: banana\n2: cherry\n",
            10: "42\nHello, Ada!\nHello, Grace!\n",
            11: "12\n",
        ]
        let page = try Self.page()
        for (index, output) in expected.sorted(by: { $0.key < $1.key }) {
            #expect(page.contains("```text\n" + output + "```"), "the page shows example \(index)'s output")
            let printed = try await run(examples[index])
            #expect(printed.hasPrefix(output), "example \(index) printed \(printed)")
        }
    }

    @Test("Joining strings: the program's variables are still there at the prompt")
    func joining() async throws {
        let examples = try Self.examples()
        let studio = StudioHarness(program: examples[3])
        try await studio.run()
        #expect(try await typed(examples[4].trimmingCharacters(in: .newlines), in: studio).contains("\nHello, Ada!\n"))
    }

    @Test("Asking Questions and Making Decisions, with the page's answers")
    func questions() async throws {
        let examples = try Self.examples()
        let name = StudioHarness(program: examples[5])
        name.model.runEditorProgram()
        try await name.answer("Grace", afterPrompt: "What is your name? ")
        try await name.waitUntilStopped()
        #expect(name.lastRunOutput.contains("Hello, Grace!\n"), "\(name.lastRunOutput)")

        for (age, verdict) in [("20", "You can vote."), ("12", "Not old enough to vote yet.")] {
            let studio = StudioHarness(program: examples[6])
            studio.model.runEditorProgram()
            try await studio.answer(age, afterPrompt: "How old are you? ")
            try await studio.waitUntilStopped()
            #expect(studio.lastRunOutput.contains(verdict + "\n"), "\(age): \(studio.lastRunOutput)")
        }
    }

    @Test("Guess the Number, played by halving: Higher and Lower lead to the number in at most seven tries")
    func guessTheNumber() async throws {
        let studio = StudioHarness(program: try Self.examples()[12])
        studio.model.runEditorProgram()
        var low = 1, high = 100, tries = 0
        while true {
            let guess = (low + high) / 2
            let before = studio.model.consoleText.count
            try await studio.answer(String(guess), afterPrompt: "Your guess? ")
            tries += 1
            try await studio.waitUntil("an answer to \(guess)") {
                let said = studio.model.consoleText.dropFirst(before)
                return said.contains("Higher!") || said.contains("Lower!") || said.contains("You got it in")
            }
            let said = String(studio.model.consoleText.dropFirst(before))
            if said.contains("You got it in") {
                #expect(said.contains("You got it in \(tries) tries!"), "\(said)")
                break
            }
            if said.contains("Higher!") { low = guess + 1 } else { high = guess - 1 }
            #expect(tries < 7, "halving finds any number from 1 to 100 in seven tries")
        }
        try await studio.waitUntilStopped()
        #expect(studio.lastRunOutput.hasPrefix("I'm thinking of a number from 1 to 100.\n"))
    }

    /// A mistake: `example` with `old` changed to `new`, run, and the page's
    /// quoted message checked against what Studio printed.
    private func mistake(_ example: Int, _ old: String, _ new: String, says message: String) async throws -> String {
        let page = try Self.page()
        #expect(page.contains(message), "the page quotes \(message)")
        let source = try Self.examples()[example]
        #expect(source.contains(old))
        let printed = try await run(source.replacingOccurrences(of: old, with: new))
        #expect(printed.contains(message), "\(printed)")
        return printed
    }

    @Test("Mistakes: a missing quote and a misspelled PRINT stop the program before it starts")
    func syntaxErrors() async throws {
        let quote = try await mistake(2, "print \"Hello!\"\n", "print \"Hello!\n", says: "print \"Hello!\n      ^\nSyntax error: Unterminated string")
        #expect(!quote.contains("This is my first program."))
        let misspelled = try await mistake(2, "print \"This is my first program.\"", "pirnt \"This is my first program.\"",
                                           says: "pirnt \"This is my first program.\"\n      ^\nSyntax error: Expected =")
        #expect(!misspelled.contains("Hello!"))
    }

    @Test("Mistake: a FOR without its NEXT runs once, with no message")
    func noNext() async throws {
        #expect(try Self.page().contains("```text\n1 squared is 1\n```"))
        let source = try Self.examples()[7]
        #expect(source.hasSuffix("next i\n"))
        let printed = try await run(source.replacingOccurrences(of: "next i\n", with: ""))
        #expect(printed.hasPrefix("1 squared is 1\n"), "\(printed)")
        #expect(!printed.contains("2 squared"))
        #expect(!printed.lowercased().contains("error"))
    }

    @Test("Mistake: a WHILE that never ends runs until Stop, and says where it was")
    func endless() async throws {
        #expect(try Self.page().contains("Break at 4"))
        let source = try Self.examples()[8].replacingOccurrences(of: "    count = count - 1\n", with: "")
        let studio = StudioHarness(program: source)
        studio.model.runEditorProgram()
        try await studio.waitUntil("the loop to go round") { studio.model.consoleText.components(separatedBy: "3...").count > 10 }
        studio.model.stopProgram()
        try await studio.waitUntilStopped()
        let output = studio.lastRunOutput
        #expect((2...4).contains { output.contains("3...\nBreak at \($0)\n") }, "any of the loop's lines: \(output.suffix(80))")
    }

    @Test("Mistake: an index past the end is a runtime error, after the lines that were fine")
    func pastTheEnd() async throws {
        let printed = try await mistake(9, "for i = 0 to 2", "for i = 0 to 3",
                                        says: "    print i; \": \"; fruit$(i)\n    ^\nRuntime error: fruit$ subscript out of range at 6")
        #expect(printed.hasPrefix("0: apple\n1: banana\n2: cherry\n"))
    }

    @Test("Mistakes: the wrong kind of value for a parameter is a type error")
    func typeErrors() async throws {
        _ = try await mistake(10, "print Double(21)", "print Double(2.5)",
                              says: "print Double(2.5)\n^\nType error: Cannot assign non-integer value to n at 1")
        _ = try await mistake(10, "print Double(21)", "Greet(42)", says: "Cannot assign non-string value to who")
    }
}
