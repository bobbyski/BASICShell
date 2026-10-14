import BASICCompilerKit
import BASICDialectSwift
import BASICDialectTraditional
import BASICWasm
#if canImport(JavaScriptCore)
import BASICWasmRunner
#endif
import Foundation

// basictest — the conformance runner (BASIC_COMPILER.md, Phase 4.8).
//
// Runs every `.bas` in a directory through basicc, compares its output with
// the `.out` file beside it, and — when an interpreter is given — with what
// BASICShell prints for the same program. The interpreter is the oracle:
// a disagreement is a compiler bug until proved otherwise.
//
// This is also the whole contract between the two dialects. They are allowed
// to differ inside — different object model, different string representation,
// different error channel — and are not allowed to differ here. Running the
// same programs under `--dialect traditional` and `--dialect swift` and
// getting the same bytes is what "same language, two substrates" means in
// practice; anything else is a claim.
//
//   basictest [dir] [--interpreter path] [--dialect name] [--update]
//
// `--update` rewrites the `.out` files from the interpreter's output.

struct Options {
    var directory = "Tests/Programs"
    var interpreter: String?
    var dialect: String?
    var update = false
    /// `llvm` (native binaries, the default) or `wasm` (BASIC-45: each
    /// program translated to WebAssembly and run here, in JavaScriptCore).
    var target = "llvm"

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--interpreter":
                index += 1
                interpreter = URL(fileURLWithPath: arguments[index]).standardizedFileURL.path
            case "--dialect":
                index += 1
                dialect = arguments[index]
            case "--update":
                update = true
            case "--target":
                index += 1
                target = arguments[index]
            case let path:
                directory = URL(fileURLWithPath: path).standardizedFileURL.path
            }
            index += 1
        }
    }
}

func run(_ executable: String, _ arguments: [String]) throws -> (stdout: String, exitCode: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = out
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), process.terminationStatus)
}

/// The program's output, compiled to WebAssembly and run in JavaScriptCore
/// in this process with no input, as a native one is run with none.
func runAsWebAssembly(_ path: String) throws -> String {
    #if canImport(JavaScriptCore)
    final class Capture: WasmHost {
        var output = ""
        func write(_ text: String) { output += text }
        func readLine(prompt: String) -> String? { output += prompt; return nil }
        func inkey() -> String { "" }
    }
    let ir = try Compilation(dialect: TraditionalDialect(), options: CompileOptions(emitDebugInfo: false)).llvmIR(sourcePath: path)
    let program = try WasmTranslator.translate(llvmIR: ir)
    let capture = Capture()
    let runner = WasmRunner(program: program)
    // A CHAIN finds its program beside this one, as a native build's does,
    // and compiles it as a chain target.
    runner.chainProgram = { file in
        let directory = (path as NSString).deletingLastPathComponent
        let names = (file as NSString).pathExtension.isEmpty ? [file + ".bas", file] : [file]
        guard let source = names.map({ (directory as NSString).appendingPathComponent($0) })
            .first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw WebAssemblyRunError(reason: "File not found: \(file)")
        }
        var options = CompileOptions(emitDebugInfo: false)
        options.chainTarget = true
        return try WasmTranslator.translate(llvmIR: try Compilation(dialect: TraditionalDialect(), options: options).llvmIR(sourcePath: source))
    }
    switch runner.run(host: capture) {
    case .notLoaded(let reason): throw WebAssemblyRunError(reason: "not loaded: \(reason)")
    case .trapped(let reason): throw WebAssemblyRunError(reason: "trapped: \(reason)")
    default: return capture.output
    }
    #else
    throw WebAssemblyRunError(reason: "no JavaScriptCore")
    #endif
}

struct WebAssemblyRunError: Error, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}

let options = Options(Array(CommandLine.arguments.dropFirst()))
let registry = DialectRegistry([TraditionalDialect(), SwiftDialect()])
let dialect: any DialectCompiler
do {
    dialect = try registry.dialect(named: options.dialect)
} catch {
    FileHandle.standardError.write(Data("basictest: \(error)\n".utf8))
    exit(2)
}

let programs = ((try? FileManager.default.contentsOfDirectory(atPath: options.directory)) ?? [])
    .filter { $0.hasSuffix(".bas") }
    .sorted()
guard !programs.isEmpty else {
    FileHandle.standardError.write(Data("basictest: no .bas files in \(options.directory)\n".utf8))
    exit(2)
}

let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("basictest-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDir) }

var failures = 0
for program in programs {
    let path = (options.directory as NSString).appendingPathComponent(program)
    let expectedPath = (path as NSString).deletingPathExtension + ".out"
    let binary = workDir.appendingPathComponent((program as NSString).deletingPathExtension).path
    var verdicts: [String] = []

    let interpreted: String? = try options.interpreter.map { try run($0, [path]).stdout }
    if options.update, let interpreted {
        try interpreted.write(toFile: expectedPath, atomically: true, encoding: .utf8)
    }

    do {
        let compiled: String
        if options.target == "wasm" {
            compiled = try runAsWebAssembly(path)
        } else {
            try Compilation(dialect: dialect).build(sourcePath: path, output: binary)
            compiled = try run(binary, []).stdout
        }
        if let expected = try? String(contentsOfFile: expectedPath, encoding: .utf8) {
            verdicts.append(compiled == expected ? "expected ✓" : "expected ✗")
        } else {
            verdicts.append("no .out")
        }
        if let interpreted {
            verdicts.append(compiled == interpreted ? "interpreter ✓" : "interpreter ✗")
        }
    } catch let error as CompileError {
        verdicts.append("compile error: \(error.diagnostics.first?.message ?? "")")
    } catch {
        verdicts.append("failed: \(error)")
    }

    let failed = verdicts.contains { $0.contains("✗") || $0.hasPrefix("compile error") || $0.hasPrefix("failed") }
    if failed { failures += 1 }
    print("\(failed ? "FAIL" : "PASS")  \(program)  —  \(verdicts.joined(separator: ", "))")
}

print("\(programs.count - failures) of \(programs.count) passed")
exit(failures == 0 ? 0 : 1)
