import Foundation

// BASICRT closures — a function pointer plus its captured environment.
//
// The interpreter snapshots the captured variables when the closure is
// made and gives the body those values as locals on every call; the
// compiled body copies its environment's fields into locals at entry the
// same way. Closures are immutable once made, so they share by reference.

/// The runtime's closure value.
public final class RTClosure {
    let function: UnsafeRawPointer
    let environment: RTComposite?

    init(function: UnsafeRawPointer, environment: RTComposite?) {
        self.function = function
        self.environment = environment
    }
}

@inline(__always)
func rtClosure(_ pointer: UnsafeMutableRawPointer?) -> RTClosure {
    guard let pointer else { basic_rt_fail("Closure was never set") }
    return Unmanaged<RTClosure>.fromOpaque(pointer).takeUnretainedValue()
}

/// Makes a closure over a body and an environment (borrowed); owned (+1).
@_cdecl("basic_rt_closure_new")
public func basic_rt_closure_new(_ function: UnsafeRawPointer, _ environment: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    let env = environment.map { Unmanaged<RTComposite>.fromOpaque($0).takeUnretainedValue() }
    return Unmanaged.passRetained(RTClosure(function: function, environment: env)).toOpaque()
}

@_cdecl("basic_rt_closure_retain")
public func basic_rt_closure_retain(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    _ = Unmanaged<RTClosure>.fromOpaque(pointer).retain()
}

@_cdecl("basic_rt_closure_release")
public func basic_rt_closure_release(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<RTClosure>.fromOpaque(pointer).release()
}

/// The body to call.
@_cdecl("basic_rt_closure_function")
public func basic_rt_closure_function(_ pointer: UnsafeMutableRawPointer?) -> UnsafeRawPointer {
    rtClosure(pointer).function
}

/// The environment to pass it, borrowed.
@_cdecl("basic_rt_closure_environment")
public func basic_rt_closure_environment(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    rtClosure(pointer).environment.map { Unmanaged.passUnretained($0).toOpaque() }
}

/// Calls a BASIC closure that takes nothing and returns nothing (R4.5).
///
/// The entry point a Swift framework's event handler ends up calling. A BASIC
/// closure is a function pointer plus an environment, and its compiled form
/// takes the environment first — so invoking one is a call through that
/// pointer with the environment in hand, which is what this does.
///
/// It is `@_cdecl` on purpose: a Swift framework wants a C function pointer
/// it can wrap in a closure, and this is a stable one that works for every
/// BASIC closure rather than a trampoline emitted per call site.
@_cdecl("basic_rt_closure_invoke_void")
public func basic_rt_closure_invoke_void(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    let closure = rtClosure(pointer)
    // The closure yields a number — BASIC closures are expressions — and the
    // Swift side wanted `() -> Void`, so the value is run for its effect and
    // dropped. Typed here rather than called through a void pointer so the
    // convention is stated, not assumed.
    typealias Body = @convention(c) (UnsafeMutableRawPointer?) -> Double
    let body = unsafeBitCast(closure.function, to: Body.self)
    _ = body(closure.environment.map { Unmanaged.passUnretained($0).toOpaque() })
}
