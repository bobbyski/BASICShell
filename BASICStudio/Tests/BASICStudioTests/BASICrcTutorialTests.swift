//
//  BASICrcTutorialTests.swift
//  BASICStudioTests
//
//  BASIC-38: the BASICrc tutorial is BASICShell's, and is checked there by
//  Scripts/check-basicrc-tutorial.py. What it says about BASICStudio is
//  checked here: the environment lines work at the console, and shell mode
//  starts off.
//

import Foundation
import Testing
@testable import BASICStudio

@MainActor
@Suite("BASIC-38 · What the BASICrc tutorial says about BASICStudio", .serialized)
struct BASICrcTutorialTests {
    private static func page() throws -> String {
        try #require(UserDoc.loadAll().first { $0.id == "TUTORIAL_BASICRC.md" }, "the tutorial ships").content
    }

    @Test("SETENV and ENVIRON$ work at the console")
    func environment() async throws {
        #expect(try Self.page().contains("`SETENV` and `ENVIRON$` work the same"))
        let studio = StudioHarness()
        try await studio.submit("setenv \"BASICRC_TUTORIAL\", \"nano\"")
        try await studio.submit("print ENVIRON$(\"BASICRC_TUTORIAL\")")
        #expect(studio.model.consoleText.contains("\nnano\n"), "\(studio.model.consoleText.suffix(200))")
        try await studio.submit("unsetenv \"BASICRC_TUTORIAL\"")
    }

    @Test("Shell mode starts off, so a program's name is BASIC, until OPTION SHELLMODE ON")
    func shellModeOff() async throws {
        #expect(try Self.page().contains("Shell mode is off in BASICStudio's console"))
        let studio = StudioHarness()
        try await studio.submit("date")
        #expect(studio.model.consoleText.contains("Syntax error: Expected ="), "\(studio.model.consoleText.suffix(200))")
        try await studio.submit("option shellmode on")
        try await studio.submit("echo from the console")
        #expect(studio.model.consoleText.contains("\nfrom the console"), "\(studio.model.consoleText.suffix(200))")
    }
}
