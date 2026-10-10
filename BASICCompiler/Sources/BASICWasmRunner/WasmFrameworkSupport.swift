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
// are queued, and the run's thread makes them: while it waits for a call
// that keeps the main thread (a TUIKit `App.run` firing a scheduled
// handler), or else at its next event drain, the way an ActiveUI click
// reaches a handler. Only the run's thread ever executes the module.
//
// One call from the framework cannot wait: an override of a BASIC class that
// inherits a framework class (slice 11d), whose answer the framework needs
// now. The main thread asks the run's thread for it (`WasmForward`) and waits,
// making meanwhile the framework calls the BASIC override makes in turn; the
// run's thread answers at its next chance — any framework call, a loop's
// poll, an event drain, a SLEEP. If none comes soon (the program is waiting
// for INPUT), the framework's own method answers instead.

/// The main thread, for a framework call.
public enum WasmMainThread {
    final class Call: @unchecked Sendable {
        let body: () -> Double
        var result = 0.0
        var code: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        init(body: @escaping () -> Double) { self.body = body }
    }

    /// Runs `body` on the main thread and answers its result. A BASIC error
    /// it raises there is caught in a protected frame of the main thread's
    /// own, and raised again here — never unwound across threads.
    ///
    /// A block of the main run loop's, not of the main queue: a call that
    /// awaits (R3.3) turns the run loop until it is done, and inside a
    /// main-queue block that would never run the main actor's jobs — a
    /// TUIKit `App.run` would never start.
    public static func run(_ body: @escaping () -> Double) -> Double {
        if Thread.isMainThread { return body() }
        let call = Call(body: body)
        lock.lock()
        pending.append(call)
        lock.unlock()
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { drain() }
        CFRunLoopWakeUp(main)
        // BASIC the framework calls back meanwhile runs here, on the run's
        // thread, which is the module's: a call that keeps the main thread
        // may be waiting for it.
        while call.done.wait(timeout: .now() + .milliseconds(2)) == .timedOut {
            WasmForward.service()
            WasmCallbacks.runQueued()
        }
        if call.code != 0 { basic_wasm_unwind(call.code) }
        return call.result
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [Call] = []

    /// Makes, on the main thread, every call the run's thread is waiting on:
    /// from the run loop, or while the main thread itself waits for BASIC
    /// (``WasmForward``), which may be making calls of its own.
    static func drain() {
        while true {
            lock.lock()
            let call = pending.isEmpty ? nil : pending.removeFirst()
            lock.unlock()
            guard let call else { return }
            call.code = basic_wasm_protected(runOnMain, Unmanaged.passUnretained(call).toOpaque())
            call.done.signal()
        }
    }

    /// Waits, on the run's thread, until `done` is signalled — a host's
    /// stand-in for a framework call that keeps the program until the user
    /// is finished, such as the window `AUIApplication.run` opens in Studio.
    /// Meanwhile the BASIC calls the framework queues are made, and Stop
    /// ends the wait as it ends a SLEEP.
    public static func wait(for done: DispatchSemaphore) {
        while done.wait(timeout: .now() + .milliseconds(10)) == .timedOut {
            WasmForward.service()
            WasmCallbacks.runQueued()
            RTHosted.checkStop?()
        }
    }
}

/// A BASIC body the framework calls and waits for (slice 11d): an override
/// of a BASIC class that inherits a framework class. The body is the module's
/// function at a table index, of the callbacks' `(ptr) -> double` shape,
/// taking a frame of the host's that carries its arguments and its result.
public enum WasmForward {
    final class Request: @unchecked Sendable {
        let target: Double
        let frame: UnsafeMutableRawPointer
        /// 0 waiting, 1 taken by the run's thread, 2 done, 3 given up.
        var state = 0
        var code: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        init(target: Double, frame: UnsafeMutableRawPointer) {
            self.target = target
            self.frame = frame
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var waiting: [Request] = []

    /// How long the main thread waits for the run's thread before the
    /// framework's own method answers instead: a UI that stalls for this long
    /// at worst, never one that hangs.
    static let patience = DispatchTimeInterval.milliseconds(250)

    /// Calls the BASIC body at `target` with `frame`, on the run's thread,
    /// and waits for it. False when there is no run to call, or it did not
    /// answer in time: the caller does what it would without the override.
    public static func call(_ target: Double, frame: UnsafeMutableRawPointer) -> Bool {
        guard let basicThread = WasmCallbacks.basicThread else { return false }
        if Thread.current === basicThread {
            _ = WasmCallbacks.invoke(target, argument: frame)
            return true
        }
        let request = Request(target: target, frame: frame)
        lock.lock()
        waiting.append(request)
        lock.unlock()
        let deadline = DispatchTime.now() + patience
        while request.done.wait(timeout: .now() + .milliseconds(1)) == .timedOut {
            // The body may make framework calls, which come back here.
            if Thread.isMainThread { WasmMainThread.drain() }
            guard DispatchTime.now() >= deadline else { continue }
            lock.lock()
            let untouched = request.state == 0
            if untouched {
                request.state = 3
                waiting.removeAll { $0 === request }
            }
            lock.unlock()
            if untouched { return false }
        }
        return request.code == 0
    }

    /// Makes the waiting calls, on the run's thread. An error or Stop inside
    /// one is caught here first, so the waiting thread is told, and then
    /// raised again here.
    static func service() {
        while true {
            lock.lock()
            let request = waiting.isEmpty ? nil : waiting.removeFirst()
            request?.state = 1
            lock.unlock()
            guard let request else { return }
            let code = basic_wasm_protected(forwardOnRunThread, Unmanaged.passUnretained(request).toOpaque())
            request.code = code
            request.state = 2
            request.done.signal()
            if code != 0 { basic_wasm_unwind(code) }
        }
    }

    /// Whether any call is waiting: asked at every loop's poll.
    static var hasWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !waiting.isEmpty
    }

    static func clear() {
        lock.lock()
        let left = waiting
        waiting = []
        lock.unlock()
        for request in left { request.state = 3; request.code = -1; request.done.signal() }
    }
}

private let forwardOnRunThread: basic_wasm_body = { context in
    let request = Unmanaged<WasmForward.Request>.fromOpaque(context!).takeUnretainedValue()
    _ = WasmCallbacks.invoke(request.target, argument: request.frame)
}

private let runOnMain: basic_wasm_body = { context in
    let call = Unmanaged<WasmMainThread.Call>.fromOpaque(context!).takeUnretainedValue()
    call.result = call.body()
}

/// Who BASIC is when no module runs: the interpreter, in Studio's ▶ Run of a
/// program that imports a framework (slice 11e). It calls the same entries a
/// module does, so the framework's calls back — a handler, a closure, an
/// override — come here as numbers it handed out, and run on its thread.
public protocol WasmCallbackHost: AnyObject {
    /// The thread the BASIC program runs on.
    var basicThread: Thread { get }
    /// Runs the BASIC callable `target` stands for — a closure, a handler or
    /// an override it gave out — with `argument`: an override's frame, else
    /// nothing. Called on `basicThread` only.
    func callBASIC(_ target: Double, argument: UnsafeMutableRawPointer?) -> Double
}

extension WasmCallbacks {
    /// The interpreter's run, while one calls the entries (slice 11e).
    nonisolated(unsafe) public static var host: WasmCallbackHost?

    /// The thread BASIC runs on: a module's, or the interpreter's.
    static var basicThread: Thread? {
        if let runner = WasmRunner.current { return runner.runThread }
        return host?.basicThread
    }

    /// Calls BASIC: the module's function at `target`, or what the
    /// interpreter gave out as `target`.
    static func invoke(_ target: Double, argument: UnsafeMutableRawPointer?) -> Double {
        if let runner = WasmRunner.current {
            return runner.call(tableIndex: target, shape: .ptrDouble, argument: argument)
        }
        return host?.callBASIC(target, argument: argument) ?? 0
    }
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

    /// Makes every queued call now, on the run's thread, in order: while it
    /// waits for a framework call that keeps the main thread.
    static func runQueued() {
        queueLock.lock()
        let calls = queued
        queued = []
        queueLock.unlock()
        for call in calls {
            _ = invoke(call.tableIndex, argument: call.environment)
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
    _ = WasmCallbacks.invoke(call.tableIndex, argument: call.environment)
}
#endif
