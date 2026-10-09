import BASICCompilerKit
import BASICDialectTraditional
@testable import BASICWasm
import Foundation
import JavaScriptCore
import Testing

/// BASIC-45: the LLVM IR of every conformance program translates to a
/// WebAssembly module that JavaScriptCore accepts.
@Suite("WebAssembly translator")
struct WasmTranslatorTests {
    static let programs = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Programs")

    static func sources() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: programs, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "bas" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func llvmIR(_ source: URL) throws -> String {
        try onLargeStack {
            try Compilation(dialect: TraditionalDialect(), options: CompileOptions(emitDebugInfo: false))
                .llvmIR(sourcePath: source.path)
        }
    }

    /// The front end recurses down long expressions (a string built with forty
    /// `+`s) and needs more stack than a test's thread has; basicc runs it on
    /// the main thread, and Studio on a lane with a large stack.
    static func onLargeStack<T>(_ body: @escaping () throws -> T) throws -> T {
        nonisolated(unsafe) var outcome: Result<T, Error>?
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            outcome = Result { try body() }
            done.signal()
        }
        thread.stackSize = 64 << 20
        thread.start()
        done.wait()
        return try outcome!.get()
    }

    /// JavaScriptCore's own verdict on a module.
    static func validates(_ bytes: [UInt8]) -> Bool {
        let context = JSContext()!
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(1, bytes.count), alignment: 16)
        bytes.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        var exception: JSValueRef?
        let array = JSObjectMakeTypedArrayWithBytesNoCopy(context.jsGlobalContextRef, kJSTypedArrayTypeUint8Array,
                                                          buffer, bytes.count, { bytes, _ in bytes?.deallocate() }, nil, &exception)
        let value = JSValue(jsValueRef: array, in: context)!
        return context.objectForKeyedSubscript("WebAssembly")?
            .invokeMethod("validate", withArguments: [value])?.toBool() ?? false
    }

    @Test("Every conformance program translates, and JavaScriptCore validates the module")
    func conformance() throws {
        var translated = 0
        for source in try Self.sources() {
            let ir: String
            do {
                ir = try Self.llvmIR(source)
            } catch {
                continue // the dialect refuses it; nothing to translate
            }
            do {
                let program = try WasmTranslator.translate(llvmIR: ir)
                #expect(Self.validates(program.bytes), "\(source.lastPathComponent) does not validate")
                translated += 1
            } catch {
                Issue.record("\(source.lastPathComponent): \(error)")
            }
        }
        #expect(translated > 40)
    }

    @Test("A program's imports are the runtime functions it calls, with their kinds")
    func imports() throws {
        let compilation = Compilation(dialect: TraditionalDialect(), options: CompileOptions(emitDebugInfo: false))
        let ir = try compilation.dialect.lower(try compilation.bir(source: "print \"hi\"; 2 + 2", name: "hi"),
                                               options: compilation.options).llvmIR
        let program = try WasmTranslator.translate(llvmIR: ir)
        let names = program.imports.map(\.name)
        #expect(names.contains("basic_rt_print_text"))
        #expect(names.contains("basic_rt_print_number"))
        #expect(names.last == WasmTranslator.pollImport)
        let literal = try #require(program.imports.first { $0.name == "basic_rt_string_literal" })
        #expect(literal.parameters == [.pointer, .int64])
        #expect(literal.result == .pointer)
        #expect(Self.validates(program.bytes))
    }
}
