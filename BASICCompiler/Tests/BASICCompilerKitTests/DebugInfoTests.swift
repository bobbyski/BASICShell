@testable import BASICCompilerKit
import BASICDialectTraditional
import Foundation
import Testing

/// DWARF (D10, J1.4): what `lldb ./program` needs to stop on a BASIC line.
///
/// Read back with `dwarfdump` rather than by driving `lldb`: the debugger
/// wants a terminal and a debugging entitlement a test run may not have,
/// while the line table and the DIEs are the whole of what it reads, and
/// `dwarfdump` reads them the same way on any machine.
struct DebugInfoTests {
    /// A two-file program: the second file holds the function, so a
    /// breakpoint there has to come through the IMPORT.
    static let helpers = """
        FUNCTION Square(n AS DOUBLE) AS DOUBLE
            LOCAL result = n * n
            RETURN result
        END FUNCTION
        """

    static let main = """
        IMPORT "Helpers.bas"
        GLOBAL Total = 0
        FOR I = 1 TO 3
            Total = Total + Square(I)
        NEXT I
        PRINT Total
        """

    /// Builds the program in a fresh directory and hands back the object and
    /// the IR the build left in `<output>.build/`.
    static func build(emitDebugInfo: Bool = true) throws -> (directory: URL, object: String, ir: String, output: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("basicc-dwarf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try helpers.write(to: directory.appendingPathComponent("Helpers.bas"), atomically: true, encoding: .utf8)
        try main.write(to: directory.appendingPathComponent("main.bas"), atomically: true, encoding: .utf8)
        let output = directory.appendingPathComponent("program").path
        let source = directory.appendingPathComponent("main.bas").path
        try TestBuild.onDeepStack {
            try Compilation(dialect: TraditionalDialect(), options: CompileOptions(emitDebugInfo: emitDebugInfo))
                .build(sourcePath: source, output: output)
        }
        let ir = try String(contentsOfFile: output + ".build/main.ll", encoding: .utf8)
        return (directory, output + ".build/main.o", ir, output)
    }

    @Test func aDebugBuildDescribesTheProgramAsBASIC() throws {
        let built = try Self.build()
        defer { try? FileManager.default.removeItem(at: built.directory) }

        // Both files, by their own names: a line in Helpers.bas is not a line
        // in main.bas, even though IMPORT spliced one into the other.
        let lines = try ProcessRunner.xcrun("dwarfdump", ["--debug-line", built.object]).stdout
        #expect(lines.contains("\"main.bas\""))
        #expect(lines.contains("\"Helpers.bas\""))

        // Every row of the line table, as (line, file index).
        let rows = lines.split(separator: "\n").compactMap { row -> (line: Int, file: Int)? in
            let fields = row.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, fields[0].hasPrefix("0x"),
                  let line = Int(fields[1]), let file = Int(fields[3]) else { return nil }
            return (line, file)
        }
        // RETURN lowers to nothing but a `ret` — a terminator — and a line
        // with no instruction of its own is the line a breakpoint cannot find.
        #expect(rows.contains { $0.line == 3 && $0.file == 2 }, "no row for RETURN in Helpers.bas")
        #expect(rows.contains { $0.line == 4 && $0.file == 1 }, "no row for the loop body in main.bas")
        #expect(rows.contains { $0.line == 5 && $0.file == 1 }, "no row for NEXT in main.bas")

        let info = try ProcessRunner.xcrun("dwarfdump", ["--debug-info", built.object]).stdout
        for name in ["\"SQUARE\"", "\"F.SQUARE\"", "\"N\"", "\"RESULT\"", "\"TOTAL\"", "\"DOUBLE\""] {
            #expect(info.contains(name), "no DIE named \(name)")
        }

        // It still runs: debug information changes nothing the program does.
        let run = try ProcessRunner.run(built.output, [])
        #expect(run.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "14")
    }

    @Test func minusG0LeavesTheIRWithoutDebugInformation() throws {
        let built = try Self.build(emitDebugInfo: false)
        defer { try? FileManager.default.removeItem(at: built.directory) }
        #expect(!built.ir.contains("!dbg"))
        #expect(!built.ir.contains("llvm.dbg.cu"))
    }

    @Test func everyInstructionInADescribedFunctionHasALocation() throws {
        let built = try Self.build()
        defer { try? FileManager.default.removeItem(at: built.directory) }

        // LLVM refuses a call without a location inside a function that has a
        // subprogram, so this is checked for every instruction rather than
        // left to clang to report as an error in someone's build.
        var inDescribedFunction = false
        for line in built.ir.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("define ") {
                inDescribedFunction = line.contains("!dbg")
            } else if line == "}" {
                inDescribedFunction = false
            } else if inDescribedFunction, line.hasPrefix("  ") {
                #expect(line.contains(", !dbg !"), "no location: \(line)")
            }
        }
        #expect(built.ir.contains("define i32 @main(i32 %argc, ptr %argv) !dbg"))
    }
}
