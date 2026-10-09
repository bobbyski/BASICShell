//
//  StudioWasmRunTests.swift
//  BASICStudioTests
//
//  BASIC-45: ⚡ with Settings ▸ Console ▸ "⚡ builds with" set to WebAssembly
//  compiles the program in Studio, runs it in JavaScriptCore, and uses
//  Studio's console as the interpreter does: output, INPUT, errors and Stop.
//

import Foundation
import Testing
@testable import BASICStudio

@MainActor
@Suite("BASIC-45 · ⚡ as WebAssembly, in Studio", .serialized)
struct StudioWasmRunTests {
    private func start(_ program: String) -> StudioHarness {
        let studio = StudioHarness(program: program)
        studio.model.compiledRunTarget = .webAssembly
        studio.model.jitEditorProgram()
        return studio
    }

    private func waitUntilFinished(_ studio: StudioHarness) async throws {
        try await studio.waitUntil("the WebAssembly run to finish", timeout: .seconds(60)) { !studio.model.isJITRunning }
    }

    @Test("Prints, takes INPUT from the console, and returns to the prompt")
    func printsAndAsks() async throws {
        let studio = start("""
        print "Hello from WebAssembly"
        input "Name? "; who$
        print "Hi, "; who$; "! "; 6 * 7
        """)
        try await studio.answer("Ada", afterPrompt: "Name? ")
        try await waitUntilFinished(studio)
        let console = studio.model.consoleText
        #expect(console.contains("JIT\nHello from WebAssembly\nName? "), "\(console)")
        #expect(console.contains("Hi, Ada! 42\n"), "\(console)")
        #expect(console.hasSuffix(studio.model.prompt))
    }

    @Test("A runtime error is reported as the interpreter reports it")
    func error() async throws {
        let studio = start("print \"before\"\nprint 1 / 0")
        try await waitUntilFinished(studio)
        #expect(studio.model.consoleText.contains("before\n"))
        #expect(studio.model.consoleText.contains("Division by zero"), "\(studio.model.consoleText)")
    }

    @Test("Stop ends a loop that never would")
    func stop() async throws {
        let studio = start("n = 0\nwhile 1\n    n = n + 1\nwend")
        try await studio.waitUntil("the run to start") { studio.model.isJITRunning }
        try await Task.sleep(for: .milliseconds(300))
        studio.model.stopProgram()
        try await waitUntilFinished(studio)
        #expect(studio.model.consoleText.contains("Break at "), "\(studio.model.consoleText.suffix(200))")
    }

    @Test("A program that does not compile says why, and runs nothing")
    func refused() async throws {
        let studio = start("print \"unterminated")
        try await waitUntilFinished(studio)
        #expect(studio.model.consoleText.contains("Unterminated string"), "\(studio.model.consoleText.suffix(300))")
    }

    @Test("On the Mac the choice is the person's, and LLVM is the default")
    func choice() {
        #expect(StudioCompiledRunTarget.isChoosable)
        let studio = StudioHarness()
        #expect(studio.model.compiledRunTarget == .llvm)
        #expect(studio.model.effectiveCompiledRunTarget == .llvm)
        studio.model.compiledRunTarget = .webAssembly
        #expect(studio.model.effectiveCompiledRunTarget == .webAssembly)
    }
}
