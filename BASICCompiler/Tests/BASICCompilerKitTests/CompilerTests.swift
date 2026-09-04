@testable import BASICCompilerKit
import BASICDialectTraditional
import BASICSyntax
import Foundation
import Testing

/// Builds and runs programs through the whole pipeline, in a temp directory.
enum TestBuild {
    static let programsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Programs")

    /// The interpreter, when the sibling package has been built.
    static let interpreter: String? = {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BASICShell/.build/debug/BASICShell").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()

    struct Run {
        let stdout: String
        let exitCode: Int32
    }

    /// Compiles the program at `path` and runs it.
    static func run(path: String) throws -> Run {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("basicc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let output = workDir.appendingPathComponent("program").path
        try Compilation(dialect: TraditionalDialect()).build(sourcePath: path, output: output)
        let result = try ProcessRunner.run(output, [])
        return Run(stdout: result.stdout, exitCode: result.exitCode)
    }

    /// Compiles program text and runs it.
    static func run(source: String) throws -> Run {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("basicc-\(UUID().uuidString).bas").path
        try source.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        return try run(path: path)
    }

    /// Runs the interpreter on the program, when available.
    static func interpret(path: String) throws -> String? {
        guard let interpreter else { return nil }
        let result = try ProcessRunner.run(interpreter, [path])
        return result.stdout
    }

    /// Every `.bas` under Tests/Programs, sorted.
    static var programs: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: programsDirectory.path)) ?? [])
            .filter { $0.hasSuffix(".bas") }
            .sorted()
            .map { programsDirectory.appendingPathComponent($0).path }
    }
}

/// Golden BIR: the shape of what the front end produces, readable.
struct BIRGoldenTests {
    @Test func printAndAssign() throws {
        let module = try Compilation(dialect: TraditionalDialect()).bir(source: """
            A$ = "hi"
            PRINT A$; 1 + 2
            """, name: "golden")
        #expect(BIRPrinter().render(module) == """
            module golden
            global A$ : string
            function main() : void
              entry:
                store A$ <- "hi"
                print A$ (1 + 2) newline
                end

            """)
    }

    @Test func forLoopShape() throws {
        let module = try Compilation(dialect: TraditionalDialect()).bir(source: """
            FOR I = 1 TO 3
            NEXT
            """, name: "golden")
        let text = BIRPrinter().render(module)
        #expect(text.contains("local $for.end.1 : number"))
        #expect(text.contains("for.body:"))
        #expect(text.contains("store I <- (I + $for.step.2)"))
    }

    @Test func unreachableCodeIsDropped() throws {
        let module = try Compilation(dialect: TraditionalDialect()).bir(source: """
            10 GOTO 30
            20 PRINT "never"
            30 PRINT "end"
            """, name: "golden")
        #expect(!BIRPrinter().render(module).contains("never"))
    }
}

/// The compiler must not invent builtins the interpreter lacks.
struct IntrinsicTableTests {
    @Test func everyIntrinsicIsOneTheInterpreterHas() {
        // LEN and CHR$ are parsed as their own expression nodes, not looked up.
        let parsedSpecially: Set<String> = ["LEN", "CHR$", "ERR", "ERL"]
        for intrinsic in BIRIntrinsic.allCases where !parsedSpecially.contains(intrinsic.rawValue) {
            #expect(BASICKeywords.intrinsicFunctionNames.contains(intrinsic.rawValue), "\(intrinsic.rawValue)")
        }
    }
}

/// Diagnostics: what basicc refuses, and how it says so.
struct DiagnosticTests {
    @Test func orderingStringsInExpressionsIsRefusedLikeTheInterpreter() {
        // The interpreter's `<` on strings raises "Expected a number"; the
        // compiler says so at compile time rather than compiling something else.
        #expect(throws: CompileError.self) {
            try Compilation(dialect: TraditionalDialect()).bir(source: "PRINT \"a\" < \"b\"", name: "bad")
        }
    }

    @Test func mixedTypesAreAnError() {
        #expect(throws: CompileError.self) {
            try Compilation(dialect: TraditionalDialect()).bir(source: "A = 1\nA = \"x\"", name: "bad")
        }
    }

    @Test func missingLineFailsWhenReachedLikeTheInterpreter() throws {
        let run = try TestBuild.run(source: "10 PRINT \"A\"\n20 GOTO 99\n30 PRINT \"B\"")
        #expect(run.stdout == "A\nMissing line 99\n")
        #expect(run.exitCode == 1)
    }

    @Test func unsupportedFeaturesSaySo() {
        do {
            _ = try Compilation(dialect: TraditionalDialect()).bir(source: "OPTION LOCAL-LET", name: "bad")
            Issue.record("expected a compile error")
        } catch let error as CompileError {
            #expect(error.description.contains("not supported by basicc yet"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

/// Programs compiled, run, and checked against expected output — and
/// against the interpreter, which is the oracle, whenever it is built.
struct EndToEndTests {
    @Test func runtimeErrorsLookLikeTheInterpreters() throws {
        let run = try TestBuild.run(path: TestBuild.programsDirectory.appendingPathComponent("divzero.bas").path)
        #expect(run.stdout == "BEFORE\nRuntime error: Division by zero\n")
        #expect(run.exitCode == 1)
    }

    @Test func returnWithoutGosubFails() throws {
        let run = try TestBuild.run(source: "PRINT \"A\"\nRETURN\nPRINT \"B\"")
        #expect(run.stdout == "A\nRuntime error: RETURN without GOSUB\n")
        #expect(run.exitCode == 1)
    }

    @Test(arguments: TestBuild.programs)
    func programMatchesExpectedOutput(path: String) throws {
        let expectedPath = (path as NSString).deletingPathExtension + ".out"
        let expected = try String(contentsOfFile: expectedPath, encoding: .utf8)
        let run = try TestBuild.run(path: path)
        #expect(run.stdout == expected, "compiled output of \((path as NSString).lastPathComponent)")
    }

    @Test(arguments: TestBuild.programs)
    func programMatchesTheInterpreter(path: String) throws {
        guard let interpreted = try TestBuild.interpret(path: path) else { return }
        let run = try TestBuild.run(path: path)
        #expect(run.stdout == interpreted, "interpreter parity for \((path as NSString).lastPathComponent)")
    }
}
