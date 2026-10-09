#if canImport(JavaScriptCore)
import BASICRT
import BASICWasm
import BASICWasmHostC
import Foundation
import JavaScriptCore

// Runs a program basicc compiled to WebAssembly, in JavaScriptCore, with the
// native BASICRT answering its imports (BASIC-45; Documents/WASM_BACKEND.md).
//
//   module ── import rt.basic_rt_print_text(p) ──► __rt(index, p)   (JS, one per arity)
//                                                   │ C API callback
//                                                   ▼
//            basic_wasm_protected { RTEntryPoints … basic_rt_print_text(UnsafeMutableRawPointer(p)) }
//                                                   │ a runtime error, hosted
//                                                   ▼
//            basic_wasm_unwind(code) ─► the callback sets the JS exception:
//              landed → WebAssembly.Exception(landed): the module's try/catch takes it (ON ERROR)
//              fatal  → an Error the module never catches: the run ends, the message printed
//
// The runtime calls event handlers and async bodies through trampolines; a
// trampoline calls the module's __callback_* export with the table slot. An
// exception from inside a callback is kept, the runtime frames are unwound to
// the import that led there, and the exception goes on from that import.

/// What a WebAssembly program's console is connected to.
public protocol WasmHost: AnyObject {
    /// Text the program printed.
    func write(_ text: String)
    /// A line the person typed, after showing `prompt`; nil at the end of input.
    func readLine(prompt: String) -> String?
    /// The next key pressed, or "" when none is waiting.
    func inkey() -> String
}

/// How a run ended.
public enum WasmRunOutcome: Equatable, Sendable {
    /// `main` returned this exit code.
    case finished(Int32)
    /// A runtime error nothing handled. Its message has been printed.
    case failed
    /// Stop. "Break at …" has been printed.
    case stopped
    /// The program needs runtime functions this runner does not have.
    case notLoaded(String)
    /// The module itself failed: a translator or runner bug, never the program's.
    case trapped(String)
}

public final class WasmRunner: @unchecked Sendable {
    public let program: WasmProgram
    private let stopLock = NSLock()
    private var stopRequested = false

    // The run in progress, for the C callbacks that cannot capture.
    nonisolated(unsafe) static var current: WasmRunner?

    private var context: JSContext!
    private var entries: [RTEntryPoint?] = []
    private var pollIndex = -1
    private var landedFactory: JSValue!
    private var fatalValue: JSValue!
    private var stopValue: JSValue!
    private var callbackExports: [JSValue] = []
    /// An exception thrown inside a callback, on its way out through the
    /// import that led there.
    private var pending: JSValueRef?

    /// Unwind codes beyond RTHosted's own.
    static let rethrowCode: Int32 = 3
    static let stopCode: Int32 = 4

    public init(program: WasmProgram) {
        self.program = program
    }

    /// Asks the run to stop at its next poll. Safe from any thread.
    public func requestStop() {
        stopLock.lock()
        stopRequested = true
        stopLock.unlock()
    }

    private var isStopRequested: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopRequested
    }

    /// Runtime functions the program imports that this runner cannot answer.
    public static func missingImports(of program: WasmProgram) -> [String] {
        program.imports.map(\.name).filter { name in
            name != WasmTranslator.pollImport && RTEntryPoints.table[name] == nil && intrinsics[name] == nil
        }
    }

    static let intrinsics: [String: RTEntryPoint] = [
        "llvm.sin.f64": RTEntryPoint(arity: 1) { sin($0[0]) },
        "llvm.cos.f64": RTEntryPoint(arity: 1) { cos($0[0]) },
        "llvm.exp.f64": RTEntryPoint(arity: 1) { exp($0[0]) },
        "llvm.log.f64": RTEntryPoint(arity: 1) { log($0[0]) },
        "llvm.pow.f64": RTEntryPoint(arity: 2) { pow($0[0], $0[1]) },
        // The C library's own, which the lowering calls by name.
        "tan": RTEntryPoint(arity: 1) { tan($0[0]) },
        "atan": RTEntryPoint(arity: 1) { atan($0[0]) },
        "atan2": RTEntryPoint(arity: 2) { atan2($0[0], $0[1]) },
        "asin": RTEntryPoint(arity: 1) { asin($0[0]) },
        "acos": RTEntryPoint(arity: 1) { acos($0[0]) },
        "sinh": RTEntryPoint(arity: 1) { sinh($0[0]) },
        "cosh": RTEntryPoint(arity: 1) { cosh($0[0]) },
        "tanh": RTEntryPoint(arity: 1) { tanh($0[0]) },
        "log10": RTEntryPoint(arity: 1) { log10($0[0]) },
        "pow": RTEntryPoint(arity: 2) { pow($0[0], $0[1]) },
    ]

    /// Runs the program to its end. Call it on a thread with a large stack:
    /// the runtime and JavaScriptCore both recurse.
    public func run(host: WasmHost) -> WasmRunOutcome {
        let missing = Self.missingImports(of: program)
        guard missing.isEmpty else {
            return .notLoaded("this program uses \(missing.joined(separator: ", ")), which programs compiled to WebAssembly cannot use yet")
        }
        entries = program.imports.map { RTEntryPoints.table[$0.name] ?? Self.intrinsics[$0.name] }
        pollIndex = program.imports.firstIndex { $0.name == WasmTranslator.pollImport } ?? -1

        Self.current = self
        RTHosted.output = { [unowned host] text in host.write(text) }
        RTHosted.readLine = { [unowned host] prompt in host.readLine(prompt: prompt) }
        RTHosted.inkey = { [unowned host] in host.inkey() }
        RTHosted.unwind = { kind in basic_wasm_unwind(kind.rawValue) }
        WasmCallbacks.reset()
        basic_wasm_set_dispatchers(dispatchPtrVoid, dispatchPtrPtr, dispatchVoidPtr, dispatchPtrDouble)
        defer {
            RTHosted.output = nil
            RTHosted.readLine = nil
            RTHosted.inkey = nil
            RTHosted.unwind = nil
            WasmCallbacks.reset()
            Self.current = nil
            context = nil
        }

        guard let context = JSContext(virtualMachine: JSVirtualMachine()) else {
            return .trapped("JavaScriptCore could not make a context")
        }
        self.context = context
        var thrown: JSValue?
        context.exceptionHandler = { _, value in thrown = value }

        // The memory, and its native address. JavaScriptCore will not hand
        // out a WebAssembly.Memory's buffer, but it will a typed array's over
        // it; the memory never grows, so the address stays good. Checked: a
        // byte written from JavaScript is the byte at that address.
        let memory = context.evaluateScript(
            "new WebAssembly.Memory({initial: \(program.memoryPages), maximum: \(program.memoryPages)})")!
        context.setObject(memory, forKeyedSubscript: "__memory" as NSString)
        let view = context.evaluateScript("__view = new Uint8Array(__memory.buffer); __view[7] = 0x5A; __view")!
        var exception: JSValueRef?
        guard let viewObject = JSValueToObject(context.jsGlobalContextRef, view.jsValueRef, &exception),
              let base = JSObjectGetTypedArrayBytesPtr(context.jsGlobalContextRef, viewObject, &exception),
              base.load(fromByteOffset: 7, as: UInt8.self) == 0x5A else {
            return .trapped("the module's memory has no address")
        }
        base.storeBytes(of: 0, toByteOffset: 7, as: UInt8.self)

        // The one native function every import goes through.
        let rt = JSObjectMakeFunctionWithCallback(context.jsGlobalContextRef, nil, importCallback)
        context.setObject(JSValue(jsValueRef: rt, in: context), forKeyedSubscript: "__rt" as NSString)
        context.evaluateScript(Self.glue)
        fatalValue = context.objectForKeyedSubscript("__fatal")
        stopValue = context.objectForKeyedSubscript("__stop")
        landedFactory = context.objectForKeyedSubscript("__landed")

        let names = program.imports.map(\.name)
        let arities = program.imports.map(\.parameters.count)
        let imports = context.objectForKeyedSubscript("__makeImports")
            .call(withArguments: [names, arities, memory, Double(UInt(bitPattern: base))])

        // The module.
        let bytes = Self.typedArray(program.bytes, in: context)
        let webAssembly = context.objectForKeyedSubscript("WebAssembly")!
        thrown = nil
        guard let module = webAssembly.objectForKeyedSubscript("Module").construct(withArguments: [bytes]), thrown == nil,
              let instance = webAssembly.objectForKeyedSubscript("Instance").construct(withArguments: [module, imports as Any]),
              thrown == nil else {
            return .trapped("JavaScriptCore would not load the module: \(thrown?.toString() ?? "no reason given")")
        }
        context.setObject(instance, forKeyedSubscript: "__instance" as NSString)
        let exports = instance.forProperty("exports")!
        callbackExports = WasmTranslator.callbackExports.map { exports.forProperty($0) }

        // Run.
        let result = exports.forProperty(WasmTranslator.runExport).call(withArguments: [])
        if let thrown {
            if thrown.isEqual(to: fatalValue) {
                return .failed
            }
            if thrown.isEqual(to: stopValue) {
                RTHosted.finish()
                host.write(RTHosted.breakMessage() + "\n")
                return .stopped
            }
            return .trapped(thrown.toString() ?? "an exception")
        }
        return .finished(result?.toInt32() ?? 0)
    }

    // MARK: Imports

    final class Frame {
        let entry: RTEntryPoint
        var arguments: [Double]
        var result: Double = 0
        init(entry: RTEntryPoint, arguments: [Double]) {
            self.entry = entry
            self.arguments = arguments
        }
    }

    func callImport(_ ctx: JSContextRef, _ count: Int, _ arguments: UnsafePointer<JSValueRef?>,
                    _ exception: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        let index = Int(JSValueToNumber(ctx, arguments[0], nil))
        if index == pollIndex {
            if isStopRequested { exception?.pointee = stopValue.jsValueRef }
            return JSValueMakeUndefined(ctx)
        }
        guard index >= 0, index < entries.count, let entry = entries[index] else {
            exception?.pointee = JSValueMakeString(ctx, JSStringCreateWithUTF8CString("no entry point \(index)"))
            return JSValueMakeUndefined(ctx)
        }
        var values = [Double](repeating: 0, count: max(1, entry.arity))
        for position in 0..<min(entry.arity, count - 1) {
            values[position] = JSValueToNumber(ctx, arguments[position + 1], nil)
        }
        let frame = Frame(entry: entry, arguments: values)
        let code = basic_wasm_protected(callFrame, Unmanaged.passUnretained(frame).toOpaque())
        withExtendedLifetime(frame) {}
        switch code {
        case 0:
            return JSValueMakeNumber(ctx, frame.result)
        case RTHosted.Unwind.landed.rawValue:
            exception?.pointee = landedFactory.call(withArguments: [])?.jsValueRef
        case Self.rethrowCode:
            exception?.pointee = pending
            if let pending { JSValueUnprotect(ctx, pending) }
            pending = nil
        default:
            exception?.pointee = fatalValue.jsValueRef
        }
        return JSValueMakeUndefined(ctx)
    }

    // MARK: Callbacks

    /// Calls the module's dispatcher for `shape` with the table slot and
    /// argument. An exception unwinds the runtime frames between here and
    /// the import that led here, and goes on from there.
    func callback(_ shape: WasmCallbacks.Shape, slot: Int, argument: UnsafeMutableRawPointer?) -> Double {
        let tableIndex = WasmCallbacks.tableIndex(shape, slot: slot)
        var arguments: [Any] = [tableIndex]
        if shape != .voidPtr { arguments.append(Double(UInt(bitPattern: argument))) }
        let dispatcher = callbackExports[shape.rawValue]
        let ctx = context.jsGlobalContextRef!
        var exception: JSValueRef?
        let argumentRefs = arguments.map { JSValue(object: $0, in: context).jsValueRef }
        let result = argumentRefs.withUnsafeBufferPointer { buffer in
            JSObjectCallAsFunction(ctx, JSValueToObject(ctx, dispatcher.jsValueRef, nil), nil, buffer.count, buffer.baseAddress, &exception)
        }
        if let exception {
            JSValueProtect(ctx, exception)
            pending = exception
            basic_wasm_unwind(Self.rethrowCode)
        }
        return result.map { JSValueToNumber(ctx, $0, nil) } ?? 0
    }

    // MARK: JavaScript

    /// The glue: imports by arity (no array per call), and the three
    /// exceptions a run can end with.
    static let glue = """
    var __instance;
    var __fatal = new Error("basic.fatal");
    var __stop = new Error("basic.stop");
    function __landed() { return new WebAssembly.Exception(__instance.exports.landed, []); }
    function __makeImports(names, arities, memory, base) {
        const rt = {};
        for (let i = 0; i < names.length; i++) {
            const n = arities[i];
            let f;
            switch (n) {
            case 0: f = () => __rt(i); break;
            case 1: f = (a) => __rt(i, a); break;
            case 2: f = (a, b) => __rt(i, a, b); break;
            case 3: f = (a, b, c) => __rt(i, a, b, c); break;
            case 4: f = (a, b, c, d) => __rt(i, a, b, c, d); break;
            case 5: f = (a, b, c, d, e) => __rt(i, a, b, c, d, e); break;
            case 6: f = (a, b, c, d, e, g) => __rt(i, a, b, c, d, e, g); break;
            default: f = (...args) => __rt(i, ...args); break;
            }
            rt[names[i]] = f;
        }
        return { rt, env: { memory, base: new WebAssembly.Global({ value: "f64", mutable: false }, base) } };
    }
    """

    static func typedArray(_ bytes: [UInt8], in context: JSContext) -> JSValue {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(1, bytes.count), alignment: 16)
        bytes.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        var exception: JSValueRef?
        let array = JSObjectMakeTypedArrayWithBytesNoCopy(context.jsGlobalContextRef, kJSTypedArrayTypeUint8Array,
                                                          buffer, bytes.count, { bytes, _ in bytes?.deallocate() }, nil, &exception)
        return JSValue(jsValueRef: array, in: context)
    }
}

// MARK: - C entry points (no captures)

private let callFrame: basic_wasm_body = { context in
    let frame = Unmanaged<WasmRunner.Frame>.fromOpaque(context!).takeUnretainedValue()
    frame.result = frame.arguments.withUnsafeBufferPointer { frame.entry.call($0.baseAddress!) }
}

private let importCallback: JSObjectCallAsFunctionCallback = { ctx, _, _, count, arguments, exception in
    guard let ctx, let arguments, let runner = WasmRunner.current else { return nil }
    return runner.callImport(ctx, count, arguments, exception)
}

private let dispatchPtrVoid: basic_wasm_dispatch_ptr_void = { slot, argument in
    _ = WasmRunner.current?.callback(.ptrVoid, slot: Int(slot), argument: argument)
}

private let dispatchPtrPtr: basic_wasm_dispatch_ptr_ptr = { slot, argument in
    let value = WasmRunner.current?.callback(.ptrPtr, slot: Int(slot), argument: argument) ?? 0
    return UnsafeMutableRawPointer(bitPattern: UInt(value))
}

private let dispatchVoidPtr: basic_wasm_dispatch_void_ptr = { slot in
    let value = WasmRunner.current?.callback(.voidPtr, slot: Int(slot), argument: nil) ?? 0
    return UnsafeMutableRawPointer(bitPattern: UInt(value))
}

private let dispatchPtrDouble: basic_wasm_dispatch_ptr_double = { slot, argument in
    WasmRunner.current?.callback(.ptrDouble, slot: Int(slot), argument: argument) ?? 0
}

/// Native trampolines handed to the runtime for the module's functions.
enum WasmCallbacks {
    enum Shape: Int {
        case ptrVoid = 0, ptrPtr = 1, voidPtr = 2, ptrDouble = 3
    }

    nonisolated(unsafe) private static var slots: [[Double]] = [[], [], [], []]

    static func reset() {
        slots = [[], [], [], []]
    }

    /// The trampoline for the module's table slot `tableIndex`, made once per
    /// slot and shape.
    static func trampoline(_ shape: Shape, forTableIndex tableIndex: Double) -> UnsafeMutableRawPointer {
        let slot: Int
        if let existing = slots[shape.rawValue].firstIndex(of: tableIndex) {
            slot = existing
        } else {
            slot = slots[shape.rawValue].count
            guard slot < Int(BASIC_WASM_TRAMPOLINES) else {
                basic_rt_fail("Too many event handlers for a program compiled to WebAssembly")
            }
            slots[shape.rawValue].append(tableIndex)
        }
        return basic_wasm_trampoline(basic_wasm_shape(rawValue: UInt32(shape.rawValue)), Int32(slot))!
    }

    static func tableIndex(_ shape: Shape, slot: Int) -> Double {
        slots[shape.rawValue][slot]
    }
}
#endif
