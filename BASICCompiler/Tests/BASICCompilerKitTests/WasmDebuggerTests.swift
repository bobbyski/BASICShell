#if canImport(JavaScriptCore)
import BASICCompilerKit
import BASICCore
import BASICDialectTraditional
import BASICRT
import BASICWasm
@testable import BASICWasmRunner
import Foundation
import Testing

/// BASIC-46: a module translated for debugging stops at breakpoints, steps,
/// pauses, and shows its call stack and variables, as the interpreter's
/// debugger does.
@Suite("WebAssembly debugger", .serialized)
struct WasmDebuggerTests {
    static let program = """
    DIM total AS DOUBLE
    name$ = "Ada"
    total = 0
    FOR i = 1 TO 3
        total = total + Twice(i)
    NEXT i
    PRINT name$; total

    FUNCTION Twice(x AS DOUBLE) AS DOUBLE
        LOCAL y = x * 2
        RETURN y
    END FUNCTION
    """

    /// Compiles `source` with debug info, translates it for debugging, and
    /// runs it with `debugger`; `answer` decides how each stop goes on.
    static func debug(_ source: String, debugger: WasmDebugger, stopAfter: Double? = nil,
                      answer: @escaping (WasmDebugger.Pause) -> WasmDebugger.Command?) throws -> (WasmRunOutcome, String) {
        try WasmTranslatorTests.onLargeStack {
            let compilation = Compilation(dialect: TraditionalDialect(), options: CompileOptions(emitDebugInfo: true))
            let ir = try compilation.dialect.lower(try compilation.bir(source: source, name: "test"), options: compilation.options).llvmIR
            let program = try WasmTranslator.translate(llvmIR: ir, debug: true)
            let runner = WasmRunner(program: program)
            runner.debugger = debugger
            debugger.onPause = { pause in
                if let command = answer(pause) { debugger.resume(command) } else { runner.requestStop() }
            }
            if let stopAfter {
                DispatchQueue.global().asyncAfter(deadline: .now() + stopAfter) { runner.requestStop() }
            }
            let console = WasmRunnerTests.Console()
            let outcome = runner.run(host: console)
            return (outcome, console.output)
        }
    }

    static func value(_ name: String, in variables: [BASICVariableSnapshot]) -> String? {
        variables.first { $0.name == name }?.value
    }

    @Test("A debug build runs as a normal one, and a normal one has no hook")
    func sameOutput() throws {
        let (outcome, output) = try Self.debug(Self.program, debugger: WasmDebugger()) { _ in .run }
        #expect(outcome == .finished(0))
        #expect(output == "Ada12\n", "\(output)")
        let compilation = Compilation(dialect: TraditionalDialect(), options: CompileOptions(emitDebugInfo: false))
        let ir = try compilation.dialect.lower(try compilation.bir(source: Self.program, name: "test"), options: compilation.options).llvmIR
        let normal = try WasmTranslator.translate(llvmIR: ir)
        #expect(normal.debugInfo == nil)
        #expect(!normal.imports.contains { $0.name == WasmTranslator.debugImport })
    }

    @Test("A breakpoint stops each time the run comes to its line: where, the call stack, locals and globals")
    func breakpoint() throws {
        let debugger = WasmDebugger()
        debugger.setBreakpoints([BASICBreakpointLocation(lineNumber: 11)])
        var pauses: [WasmDebugger.Pause] = []
        let (outcome, output) = try Self.debug(Self.program, debugger: debugger) { pause in
            pauses.append(pause)
            return .run
        }
        #expect(outcome == .finished(0))
        #expect(output == "Ada12\n")
        try #require(pauses.count == 3)
        let first = pauses[0]
        #expect(first.location.lineNumber == 11)
        #expect(first.source == "    RETURN y")
        #expect(first.callStack.map(\.name) == ["TWICE", "[main]"])
        #expect(first.callStack.map(\.kind) == ["Function", "Program"])
        #expect(first.callStack.map { $0.location?.lineNumber } == [11, 5], "the call is on line 5")
        #expect(first.frameLocals.count == 2)
        #expect(Self.value("X", in: first.frameLocals[0]) == "1")
        #expect(Self.value("Y", in: first.frameLocals[0]) == "2")
        #expect(first.frameLocals[1].isEmpty)
        #expect(Self.value("TOTAL", in: first.globals) == "0")
        #expect(Self.value("NAME$", in: first.globals) == "Ada")
        #expect(Self.value("I", in: first.globals) == "1")
        #expect(first.globals.first { $0.name == "NAME$" }?.typeName == "STRING")
        #expect(Self.value("X", in: pauses[2].frameLocals[0]) == "3")
        #expect(Self.value("TOTAL", in: pauses[2].globals) == "6")
    }

    @Test("Step into, over and out, from the first statement")
    func stepping() throws {
        let debugger = WasmDebugger(command: .stepInto)
        let script: [WasmDebugger.Command] = [.stepOver, .stepOver, .stepOver, .stepOver, .stepInto, .stepOver, .stepOut, .run]
        var lines: [Int] = []
        let (outcome, output) = try Self.debug(Self.program, debugger: debugger) { pause in
            lines.append(pause.location.lineNumber)
            return script[safe: lines.count - 1] ?? .run
        }
        #expect(outcome == .finished(0))
        #expect(output == "Ada12\n")
        // 1 DIM, 2, 3, 4 FOR, 5 the call; into Twice at 10, over to 11; out
        // to the statement after the call: NEXT, on 6.
        #expect(lines == [1, 2, 3, 4, 5, 10, 11, 6], "\(lines)")
    }

    @Test("Pause stops a loop that never ends, and Stop while it is stopped ends the run with Break")
    func pauseAndStop() throws {
        let debugger = WasmDebugger()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { debugger.pause() }
        var stoppedAt: Int?
        let (outcome, output) = try Self.debug("n = 0\nWHILE 1\n    n = n + 1\nWEND", debugger: debugger) { pause in
            stoppedAt = pause.location.lineNumber
            #expect(Int(Self.value("N", in: pause.globals) ?? "0") ?? 0 > 0)
            return nil
        }
        #expect(stoppedAt.map { (2...4).contains($0) } == true, "\(String(describing: stoppedAt))")
        #expect(outcome == .stopped)
        #expect(output.hasPrefix("Break at "), "\(output)")
    }

    @Test("BASIC-53 · A call made after another returned in the same statement is not taken for it, though their frames overlap")
    func returnedFrameIsGone() throws {
        // Small$ returns; Big, with the bigger frame, starts lower on the
        // stack and over Small$'s. Small$ was still on the call stack, so
        // its string was read from Big's doubles (70.0) and the run crashed.
        let debugger = WasmDebugger()
        debugger.setBreakpoints([BASICBreakpointLocation(lineNumber: 11)])
        var pause: WasmDebugger.Pause?
        let (outcome, output) = try Self.debug("""
        FUNCTION Small$() AS STRING
            LOCAL s$ = "hi"
            RETURN s$
        END FUNCTION
        FUNCTION Big() AS DOUBLE
            LOCAL a = 70
            LOCAL b = 70
            LOCAL c = 70
            LOCAL d = 70
            LOCAL e = 70
            RETURN a + b + c + d + e
        END FUNCTION
        PRINT Small$(); Big()
        """, debugger: debugger) { pause = $0; return .run }
        #expect(outcome == .finished(0))
        #expect(output == "hi350\n", "\(output)")
        let stopped = try #require(pause)
        #expect(stopped.callStack.map(\.name) == ["BIG", "[main]"])
        #expect(Self.value("E", in: stopped.frameLocals[0]) == "70")
    }

    @Test("BASIC-53 · What is not a runtime object is shown as unreadable, never followed")
    func unreadablePointers() {
        // The crash's own value: the double 70.0 where a pointer should be.
        let double = UnsafeMutableRawPointer(bitPattern: UInt(0x4051_8000_0000_0000))
        #expect(RTDebug.describe(name: "S$", typeName: "STRING", pointer: double).value == "<unreadable>")
        var local = 0.0
        withUnsafeMutablePointer(to: &local) { stack in
            let value = RTDebug.describe(name: "A", typeName: "ARRAY", pointer: UnsafeMutableRawPointer(stack))
            #expect(value.value == "<unreadable>")
        }
    }

    @Test("Strings, arrays, records and dictionaries, as the interpreter's pane shows them")
    func values() throws {
        let debugger = WasmDebugger()
        debugger.setBreakpoints([BASICBreakpointLocation(lineNumber: 13)])
        var pause: WasmDebugger.Pause?
        let (outcome, _) = try Self.debug("""
        TYPE Point
            x AS DOUBLE
            y AS DOUBLE
        END TYPE
        DIM scores(3) AS DOUBLE
        DIM p AS Point
        DIM ages AS DICTIONARY
        DIM ready AS BOOLEAN
        scores(2) = 1.5
        p.x = 4
        ages("Ada") = 36
        ready = TRUE
        PRINT "done"
        """, debugger: debugger) { pause = $0; return .run }
        #expect(outcome == .finished(0))
        let globals = try #require(pause?.globals)
        let scores = try #require(globals.first { $0.name == "SCORES" })
        #expect(scores.typeName == "ARRAY OF DOUBLE")
        #expect(scores.value == "4 elements (0...3)")
        #expect(scores.children.map(\.value) == ["0", "0", "1.5", "0"])
        #expect(scores.children.map(\.path) == ["Global:SCORES(0)", "Global:SCORES(1)", "Global:SCORES(2)", "Global:SCORES(3)"])
        let point = try #require(globals.first { $0.name == "P" })
        #expect(point.value == "2 fields")
        #expect(point.children.map(\.name) == ["x", "y"])
        #expect(point.children.map(\.value) == ["4", "0"])
        let ages = try #require(globals.first { $0.name == "AGES" })
        #expect(ages.value == "1 entries")
        #expect(ages.children.map(\.name) == ["\"Ada\""])
        #expect(ages.children.map(\.value) == ["36"])
        #expect(Self.value("READY", in: globals) == "TRUE")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
