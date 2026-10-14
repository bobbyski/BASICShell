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
