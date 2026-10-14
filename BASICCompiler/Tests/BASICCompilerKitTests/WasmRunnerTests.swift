#if canImport(JavaScriptCore)
import BASICCompilerKit
import BASICDialectTraditional
import BASICWasm
@testable import BASICWasmRunner
import Foundation
import Testing

/// BASIC-45: programs compiled to WebAssembly run in JavaScriptCore against
/// the native runtime. The whole conformance suite is `basictest --target
/// wasm`; these pin the runner's own behaviors.
@Suite("WebAssembly runner", .serialized)
struct WasmRunnerTests {
    final class Console: WasmHost {
        var output = ""
        var lines: [String]
        init(lines: [String] = []) { self.lines = lines }
        func write(_ text: String) { output += text }
        func readLine(prompt: String) -> String? {
            output += prompt
            return lines.isEmpty ? nil : lines.removeFirst()
        }
        func inkey() -> String { "" }
    }

    /// Compiles and runs `source` on a thread with room for the front end
    /// and the runtime to recurse.
    static func run(_ source: String, lines: [String] = [], stopAfter: Double? = nil) throws -> (WasmRunOutcome, String) {
        try WasmTranslatorTests.onLargeStack {
            let compilation = Compilation(dialect: TraditionalDialect(), options: CompileOptions(emitDebugInfo: false))
            let ir = try compilation.dialect.lower(try compilation.bir(source: source, name: "test"), options: compilation.options).llvmIR
            let runner = WasmRunner(program: try WasmTranslator.translate(llvmIR: ir))
            if let stopAfter {
                DispatchQueue.global().asyncAfter(deadline: .now() + stopAfter) { runner.requestStop() }
            }
            let console = Console(lines: lines)
            let outcome = runner.run(host: console)
            return (outcome, console.output)
        }
    }

    /// A console with keys waiting, as INKEY$ reads them from a host.
    final class Keyboard: WasmHost {
        var output = ""
        var keys: [String]
        init(keys: [String]) { self.keys = keys }
        func write(_ text: String) { output += text }
        func readLine(prompt: String) -> String? { nil }
        func inkey() -> String { keys.isEmpty ? "" : keys.removeFirst() }
    }

    @Test("ON KEY(n) takes its key before INKEY$ does, and leaves the rest, as the interpreter does")
    func keyTrap() throws {
        let source = """
        10 ON KEY(11) GOSUB 100
        20 KEY(11) ON: S = TIMER()
        30 A$ = INKEY$: IF A$ = "" AND TIMER() - S < 2 THEN 30
        40 B$ = INKEY$: IF B$ = "" AND TIMER() - S < 2 THEN 40
        50 PRINT A$; B$; HITS
        60 END
        100 HITS = HITS + 1: RETURN
        """
        let output = try WasmTranslatorTests.onLargeStack { () -> String in
            let compilation = Compilation(dialect: TraditionalDialect(), options: CompileOptions(emitDebugInfo: false))
            let ir = try compilation.dialect.lower(try compilation.bir(source: source, name: "test"), options: compilation.options).llvmIR
            let keyboard = Keyboard(keys: ["x", "[H", "y"])
            _ = WasmRunner(program: try WasmTranslator.translate(llvmIR: ir)).run(host: keyboard)
            return keyboard.output
        }
        #expect(output == "xy1\n", "\(output)")
    }

    @Test("Output, input and a function, as the interpreter prints them")
    func basics() throws {
        let (outcome, output) = try Self.run("""
        input "Name? "; who$
        print "Hello, "; who$; "!"
        print Twice(21)
        function Twice(n as integer) as integer
            return n * 2
        end function
        """, lines: ["Ada"])
        #expect(outcome == .finished(0))
        #expect(output == "Name? Hello, Ada!\n42\n")
    }

    @Test("ON ERROR catches a runtime error through WebAssembly exception handling, and RESUME NEXT goes on")
    func onError() throws {
        let (outcome, output) = try Self.run("""
        on error goto handler
        print 1 / 0
        print "after"
        end
        handler:
        print "caught "; err
        resume next
        """)
        #expect(outcome == .finished(0))
        #expect(output == "caught 11\nafter\n", "\(output)")
    }

    @Test("An error nothing handles ends the run with the interpreter's message")
    func unhandled() throws {
        let (outcome, output) = try Self.run("print \"before\"\nprint 1 / 0\nprint \"never\"")
        #expect(outcome == .failed)
        #expect(output.hasPrefix("before\n"))
        #expect(output.contains("Division by zero"), "\(output)")
        #expect(!output.contains("never"))
    }

    @Test("Stop ends a loop that never would, with Break")
    func stop() throws {
        let (outcome, output) = try Self.run("count = 0\nwhile 1\n    count = count + 1\nwend", stopAfter: 0.3)
        #expect(outcome == .stopped)
        #expect(output.hasPrefix("Break at "), "\(output)")
    }

    @Test("A second run starts clean")
    func secondRun() throws {
        _ = try Self.run("dim a(3)\na(1) = 5\nprint a(1)")
        let (outcome, output) = try Self.run("print \"fresh\"")
        #expect(outcome == .finished(0))
        #expect(output == "fresh\n")
    }

    @Test("The entry-point table covers every runtime function (Scripts/generate-rt-entry-points.py)")
    func tableIsCurrent() throws {
        let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/BASICRT")
        var names: Set<String> = []
        for file in try FileManager.default.contentsOfDirectory(at: runtime, includingPropertiesForKeys: nil)
            where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let pattern = try NSRegularExpression(pattern: #"@_cdecl\("([^"]+)"\)"#)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                names.insert(String(text[Range(match.range(at: 1), in: text)!]))
            }
        }
        #expect(names == Set(RTEntryPoints.table.keys), "run Code/Scripts/generate-rt-entry-points.py")
    }
}
#endif
