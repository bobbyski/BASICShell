//
//  StudioTypedJITTests.swift
//  BASICStudioTests
//
//  `JIT` typed at Studio's console does what ⚡ does, as it does at
//  BASICShell's prompt (JIT.md): the editor's program, or a file named after
//  it, compiled and run. Driven with "⚡ builds with" set to WebAssembly, which
//  needs no compiler on the PATH.
//

import BASICCore
import Foundation
import Testing
@testable import BASICStudio

@MainActor
@Suite("JIT typed at the console", .serialized)
struct StudioTypedJITTests {
    private func studio(_ program: String) -> StudioHarness {
        let studio = StudioHarness(program: program)
        studio.model.compiledRunTarget = .webAssembly
        return studio
    }

    private func type(_ command: String, into studio: StudioHarness) async throws {
        studio.model.command = command
        studio.model.submitCommand()
        try await studio.waitUntil("the JIT run to finish", timeout: .seconds(60)) {
            !studio.model.isJITRunning && studio.model.consoleText.hasSuffix(studio.model.prompt)
        }
    }

    @Test("JIT runs the editor's program compiled, echoed once, as ⚡ does")
    func runsTheEditorsProgram() async throws {
        let studio = studio("print \"compiled\"; 6 * 7")
        try await type("jit", into: studio)
        let console = studio.model.consoleText
        #expect(console.contains("jit\ncompiled42\n"), "\(console)")
        #expect(!console.contains("JIT\n"), "echoed once, as typed: \(console)")
    }

    @Test("JIT \"file.bas\" runs that file and leaves the editor's program alone")
    func runsANamedFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("studio-jit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("other.bas").path
        try "print \"from the file\"".write(toFile: file, atomically: true, encoding: .utf8)
        let studio = studio("print \"from the editor\"")
        try await type("JIT \"\(file)\"", into: studio)
        #expect(studio.model.consoleText.contains("from the file\n"), "\(studio.model.consoleText)")
        #expect(!studio.model.consoleText.contains("from the editor"))
        #expect(studio.model.programText == "print \"from the editor\"")
    }

    @Test("A file that is not there, and JIT SWIFT on WebAssembly, say why and run nothing")
    func refusals() async throws {
        let studio = studio("print \"never\"")
        try await type("JIT \"/no/such/file.bas\"", into: studio)
        #expect(studio.model.consoleText.contains("JIT: /no/such/file.bas does not exist"), "\(studio.model.consoleText)")
        try await type("JIT SWIFT", into: studio)
        #expect(studio.model.consoleText.contains("JIT: SWIFT needs ⚡ to build with LLVM"), "\(studio.model.consoleText)")
        #expect(!studio.model.consoleText.contains("never"))
    }
}
