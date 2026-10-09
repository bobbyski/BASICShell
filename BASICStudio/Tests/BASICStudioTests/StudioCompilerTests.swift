//
//  StudioCompilerTests.swift
//  BASICStudioTests
//
//  BASIC-44: Studio compiles a program in process, from its text, and gets
//  what basicc gets from the same program in a file: the same BIR and the
//  same LLVM IR.
//

import BASICCompilerKit
import BASICDialectTraditional
import Foundation
import Testing
@testable import BASICStudio

@Suite("BASIC-44 · Studio compiles in process, as basicc does")
struct StudioCompilerTests {
    static let program = """
    name$ = "Ada"
    age = 36
    print name$; " is "; age; " years old."
    dim fruit$(2)
    fruit$(0) = "apple"
    for i = 0 to 2
        print i; ": "; fruit$(i)
    next i
    print Double(21)
    function Double(n as integer) as integer
        return n * 2
    end function
    """

    /// The program as basicc reads it: from a file.
    private func file() throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("studio-compiler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("probe.bas").path
        try Self.program.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("The BIR from the editor's text is basicc's BIR from the file")
    func bir() throws {
        let path = try file()
        let fromFile = BIRPrinter().render(try Compilation(dialect: TraditionalDialect()).bir(sourcePath: path))
        #expect(try StudioCompiler.bir(source: Self.program, name: "probe") == fromFile)
        #expect(fromFile.contains("module probe"))
    }

    @Test("The LLVM IR from the editor's text is basicc's LLVM IR from the file, without debug info")
    func llvmIR() throws {
        let path = try file()
        let fromFile = try Compilation(dialect: TraditionalDialect(), options: CompileOptions(emitDebugInfo: false)).llvmIR(sourcePath: path)
        let inProcess = try StudioCompiler.llvmIR(source: Self.program, name: "probe")
        #expect(inProcess == fromFile)
        #expect(inProcess.contains("define i32 @main("))
        #expect(!inProcess.contains("!dbg"))
    }
}
