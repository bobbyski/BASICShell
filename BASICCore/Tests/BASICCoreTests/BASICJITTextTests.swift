//
//  BASICJITTextTests.swift
//  BASICCoreTests
//
//  The text Studio hands the compiler keeps each line where the editor has
//  it: a program leaves out blank lines, and they come back, so the line a
//  compiled run's error or debugger names is the editor's, as the
//  interpreter's is (BASIC-46).
//

import Foundation
import Testing
@testable import BASICCore

@Suite("The text a program is compiled from")
struct BASICJITTextTests {
    /// A windowed app's PATH is not a terminal's.
    ///
    /// Launched from Finder, the Dock or Xcode, an app gets
    /// `/usr/bin:/bin:/usr/sbin:/sbin` — no `/usr/local/bin`, which is where
    /// `buildtosystem.sh` installs the compiler. Studio then reported basicc
    /// missing and fell back to interpreting while the same compiler ran
    /// perfectly in a terminal, which is what "JIT fails with LLVM in Studio"
    /// was. Asking a login shell is what closes that gap.
    ///
    /// Skipped where basicc is not installed, because then there is nothing
    /// for either path to find and the test would be asserting the machine.
    @Test("A windowed app's PATH still finds an installed compiler")
    func compilerFoundWithoutATerminalPath() throws {
        let login = Process()
        login.executableURL = URL(fileURLWithPath: "/bin/sh")
        login.arguments = ["-lc", "command -v basicc"]
        let out = Pipe()
        login.standardOutput = out
        login.standardError = Pipe()
        try login.run()
        let installed = String(
            decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        login.waitUntilExit()
        try #require(!installed.isEmpty, "basicc is not installed on this machine")

        // Exactly what `ps eww` reports for a Studio launched from Xcode.
        let windowed = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        #expect(BASICJIT.compilerPath(environment: windowed) == installed)
    }

    /// BASICC still wins, and still has to be an executable that exists —
    /// the login shell must not quietly override a host's explicit choice.
    @Test("BASICC in the environment outranks the login shell")
    func overrideWins() {
        let override = ["BASICC": "/bin/echo", "PATH": "/usr/bin:/bin"]
        #expect(BASICJIT.compilerPath(environment: override) == "/bin/echo")
    }

    /// A host Xcode launched has DYLD_ paths to its own build products; basicc
    /// given them loads the host's TUIKit, not its own, and dies in dyld
    /// (2026-11-02). Everything else the host has still reaches the compiler.
    @Test("basicc runs without the host's DYLD_ variables")
    func compilerEnvironmentDropsDyld() {
        let host = [
            "DYLD_LIBRARY_PATH": "/Users/me/Build/Products/Debug",
            "DYLD_FRAMEWORK_PATH": "/Users/me/Build/Products/Debug",
            "PATH": "/usr/bin:/bin",
            "BASICC_RT_LIB": "/tmp/libBASICRTHost.a",
        ]
        #expect(BASICJIT.compilerEnvironment(host) == ["PATH": "/usr/bin:/bin", "BASICC_RT_LIB": "/tmp/libBASICRTHost.a"])
    }

    @Test("Blank lines come back, so every line is where the editor has it")
    func blankLines() {
        let program = BASICProgram()
        program.loadSource("print 1\n\nprint 2\n\n\nprint 3")
        let compiled = BASICJIT.compiledText(of: program)
        #expect(compiled.text == "print 1\n\nprint 2\n\n\nprint 3\n")
        #expect(compiled.editorLines == [1, nil, 3, nil, nil, 6])
        #expect(BASICJIT.text(of: program) == compiled.text)
    }

    @Test("Numbered lines keep their numbers")
    func numbered() {
        let program = BASICProgram()
        program.loadSource("10 PRINT \"A\"\n20 GOTO 10")
        #expect(BASICJIT.text(of: program) == "10 PRINT \"A\"\n20 GOTO 10\n")
    }
}

/// `JIT` as both BASICShell's prompt and BASICStudio's console read it.
@Suite("The JIT command")
struct BASICJITCommandTests {
    @Test("JIT, JIT SWIFT, JIT TRADITIONAL and JIT \"file\", in any case; anything else is not JIT")
    func forms() {
        #expect(BASICJIT.command("JIT") == BASICJIT.Command())
        #expect(BASICJIT.command("  jit  ") == BASICJIT.Command())
        #expect(BASICJIT.command("JIT SWIFT") == BASICJIT.Command(dialect: "swift"))
        #expect(BASICJIT.command("jit traditional \"bench.bas\"") == BASICJIT.Command(dialect: "traditional", file: "bench.bas"))
        #expect(BASICJIT.command("JIT \"mathbench.bas\"") == BASICJIT.Command(file: "mathbench.bas"))
        #expect(BASICJIT.command("JIT demos/x.bas") == BASICJIT.Command(file: "demos/x.bas"))
        #expect(BASICJIT.command("JITTER = 1") == nil)
        #expect(BASICJIT.command("RUN") == nil)
    }
}
