#if canImport(JavaScriptCore)
import BASICRT
import BASICWasmHostC
import Foundation

// What a framework map's entries need from the runner (BASIC-45): the main
// thread, and BASIC closures the framework keeps.
//
// A map's shims are R4's, which assert the main actor — true for a natively
// compiled program, which runs there. A program Studio runs as WebAssembly
// runs on a thread of its own, as the interpreter's do, so each call is
// carried to the main thread and waited for. The framework calls BASIC back
// on the main thread too, and the module is busy on its own; so those calls
// are queued, and the run's thread makes them at its next event drain, the
// way an ActiveUI click reaches a handler. Only the run's thread ever
// executes the module, and the main thread never waits for it.

/// The main thread, for a framework call.
public enum WasmMainThread {
    final class Call: @unchecked Sendable {
        let body: () -> Double
        var result = 0.0
        init(body: @escaping () -> Double) { self.body = body }
    }

    /// Runs `body` on the main thread and answers its result. A BASIC error
    /// it raises there is caught in a protected frame of the main thread's
    /// own, and raised again here — never unwound across threads.
    public static func run(_ body: @escaping () -> Double) -> Double {
        if Thread.isMainThread { return body() }
        let call = Call(body: body)
        let code = DispatchQueue.main.sync {
            basic_wasm_protected(runOnMain, Unmanaged.passUnretained(call).toOpaque())
        }
        if code != 0 { basic_wasm_unwind(code) }
        return call.result
    }
}

private let runOnMain: basic_wasm_body = { context in
    let call = Unmanaged<WasmMainThread.Call>.fromOpaque(context!).takeUnretainedValue()
    call.result = call.body()
}

/// A BASIC closure the framework holds: the module's function, by table
/// index, and the closure's environment.
final class WasmClosureCall: @unchecked Sendable {
    let tableIndex: Double
    let environment: UnsafeMutableRawPointer?
    init(tableIndex: Double, environment: UnsafeMutableRawPointer?) {
        self.tableIndex = tableIndex
        self.environment = environment
    }
}

extension WasmCallbacks {
    /// A `() -> Void` handler's pair (R4.5) for a BASIC closure: a native
    /// function the framework may call on any thread, and its context. The
    /// call is queued for the run's thread. The closure is kept for as long as
    /// the framework may call it, as R4.5's are.
    public static func voidClosure(_ closure: Double) -> (function: @convention(c) (UnsafeMutableRawPointer?) -> Void, context: UnsafeMutableRawPointer?) {
        let call = closureCall(closure)
        return (queueVoidCall, Unmanaged.passRetained(call).toOpaque())
    }

    /// A handler property's pair (P1.2): the module's compiled body and the
    /// closure's environment arrive; a native function of the shape the shim
    /// calls, and a context, go to the framework. A handler that takes
    /// arguments is refused here, on the run's thread, until a callback can
    /// carry them.
    public static func handler(function: Double, environment: Double, parameters: Int, name: String)
        -> (function: UnsafeRawPointer?, context: UnsafeMutableRawPointer?) {
        guard function != 0 else { return (nil, nil) }
        guard parameters == 0 else {
            basic_rt_fail("\(name) takes a handler with arguments, which a program Studio runs as WebAssembly cannot set yet")
        }
        let call = WasmClosureCall(tableIndex: function, environment: UnsafeMutableRawPointer(bitPattern: UInt(environment)))
        return (unsafeBitCast(queueHandlerCall, to: UnsafeRawPointer.self), Unmanaged.passRetained(call).toOpaque())
    }

    private static func closureCall(_ closure: Double) -> WasmClosureCall {
        let pointer = UnsafeMutableRawPointer(bitPattern: UInt(closure))
        basic_rt_closure_retain(pointer)
        let function = basic_rt_closure_function(pointer)
        return WasmClosureCall(tableIndex: Double(UInt(bitPattern: function)), environment: basic_rt_closure_environment(pointer))
    }

    private static let queueLock = NSLock()
    nonisolated(unsafe) private static var queued: [WasmClosureCall] = []

    /// Queues a call for the run's thread. Safe from any thread.
    static func enqueue(_ call: WasmClosureCall) {
        queueLock.lock()
        queued.append(call)
        queueLock.unlock()
    }

    /// Hands every queued call to the runtime's event queue, each with a
    /// handler that makes it, so they run at the drain, in order with the
    /// program's other events.
    static func collectQueued() {
        queueLock.lock()
        let calls = queued
        queued = []
        queueLock.unlock()
        for call in calls {
            RTEvents.post(type: "CALLBACK", subtype: "", fields: [
                "call": .number(Double(UInt(bitPattern: Unmanaged.passRetained(call).toOpaque()))),
            ], handler: RTEventHandler(trampoline: makeQueuedCall, typeIndex: -1))
        }
    }

    static func clearQueued() {
        queueLock.lock()
        queued = []
        queueLock.unlock()
    }
}

private let queueVoidCall: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    WasmCallbacks.enqueue(Unmanaged<WasmClosureCall>.fromOpaque(context!).takeUnretainedValue())
}

private let queueHandlerCall: @convention(c) (UnsafeMutableRawPointer?) -> Double = { context in
    WasmCallbacks.enqueue(Unmanaged<WasmClosureCall>.fromOpaque(context!).takeUnretainedValue())
    return 0
}

/// The event handler a queued call runs as: the payload is a dictionary
/// carrying the call; the module's function is called with its environment.
private let makeQueuedCall: @convention(c) (UnsafeMutableRawPointer?) -> Void = { payload in
    guard case .dictionary(let fields) = rtValue(payload), case .number(let bits)? = fields.values["call"],
          let pointer = UnsafeMutableRawPointer(bitPattern: UInt(bits)) else { return }
    let call = Unmanaged<WasmClosureCall>.fromOpaque(pointer).takeRetainedValue()
    _ = WasmRunner.current?.call(tableIndex: call.tableIndex, shape: .ptrDouble, argument: call.environment)
}
#endif
