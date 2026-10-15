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
    /// What `basic_rt_closure_describe` says: its name (a block closure's
    /// variable, an `AddressOf`'s function, else `[anonymous closure]`), its
    /// parameter count, its shape (`(integer)->string`), and the trampoline
    /// that calls it with its arguments boxed.
    var name = "[anonymous closure]"
    var arity = 0
    var shape = ""
    var boxed: RTEvalTrampoline?

    init(function: UnsafeRawPointer, environment: RTComposite?) {
        self.function = function
        self.environment = environment
    }

    /// A call with boxed arguments, answering a boxed value: how a closure
    /// held in a VARIANT is called (Documents/CLOSURES.md 2.5).
    func callBoxed(_ arguments: [RTValue]) -> RTValue {
        guard let boxed else { basic_rt_fail("\(name) cannot be called here") }
        guard arguments.count == arity else {
            basic_rt_fail("Function \(name) expects \(arity) arguments, got \(arguments.count)")
        }
        let list = RTArray(element: .variant, dims: [arguments.count])
        list.values = [.closure(self)] + arguments
        let array = Unmanaged.passRetained(list).toOpaque()
        defer { Unmanaged<RTArray>.fromOpaque(array).release() }
        guard let result = boxed(array) else { return .empty }
        defer { basic_rt_value_release(result) }
        return rtValue(result)
    }
}

/// Says what a closure just made is (owned by the caller, unchanged).
@_cdecl("basic_rt_closure_describe")
public func basic_rt_closure_describe(_ pointer: UnsafeMutableRawPointer?, _ trampoline: UnsafeMutableRawPointer, _ name: UnsafePointer<CChar>, _ arity: Int, _ shape: UnsafePointer<CChar>) {
    let closure = rtClosure(pointer)
    closure.boxed = unsafeBitCast(trampoline, to: RTEvalTrampoline.self)
    closure.name = String(cString: name)
    closure.arity = arity
    closure.shape = String(cString: shape)
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

/// Borrowed: the closure a record's field holds, or null when none is set.
@_cdecl("basic_rt_composite_get_closure")
public func basic_rt_composite_get_closure(_ pointer: UnsafeMutableRawPointer?, _ field: Int) -> UnsafeMutableRawPointer? {
    guard case .closure(let closure) = rtComposite(pointer).fields[field] else { return nil }
    return Unmanaged.passUnretained(closure).toOpaque()
}

/// Stores a closure in a record's field, which holds it; null clears it.
@_cdecl("basic_rt_composite_set_closure")
public func basic_rt_composite_set_closure(_ pointer: UnsafeMutableRawPointer?, _ field: Int, _ value: UnsafeMutableRawPointer?) {
    rtComposite(pointer).fields[field] = value.map { .closure(rtClosure($0)) } ?? .empty
}

/// What PRINT shows for a closure, `<FUNCTION name>`, as the interpreter
/// prints one; nothing for one never set. Owned.
@_cdecl("basic_rt_closure_text")
public func basic_rt_closure_text(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    rtOwned(pointer.map { RTValue.closure(rtClosure($0)).description } ?? "")
}
