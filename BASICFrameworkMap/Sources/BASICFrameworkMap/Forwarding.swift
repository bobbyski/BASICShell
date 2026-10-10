import BASICRT
import BASICRTSwift
import BASICWasmRunner
import Foundation

// A BASIC class that inherits a framework class (BASIC-45, slice 11d): what
// the generated forwarding classes (`BASICForward_<Class>`, see
// SwiftForwarding in BASICDialectSwift) need, by hand. Each object made for
// such a class carries a `BASICForwardState`: the BASIC class it is, the
// runtime record holding that class's own fields, and which of its methods
// BASIC overrides. An override the BASIC class has is called through
// `BASICForwardCall`, on the run's thread, with its arguments in a frame the
// compiled thunk reads through entries.

/// The BASIC half of a forwarding object.
public final class BASICForwardState: @unchecked Sendable {
    private let lock = NSLock()
    private var targets: [Int: Double] = [:]
    /// The BASIC class the object is: what TYPENAME and the object model's
    /// dispatch go by, not its framework base.
    var typeIndex = -1
    /// The runtime record of the BASIC class's own fields, owned.
    var record: UnsafeMutableRawPointer?

    public init() {}

    deinit {
        if let record { basic_rt_composite_release(record) }
    }

    /// The BASIC override for a slot: its thunk's table index in the module.
    public func target(_ slot: Int) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return targets[slot]
    }

    func setTarget(_ slot: Int, _ function: Double) {
        lock.lock()
        targets[slot] = function
        lock.unlock()
    }
}

/// An object of a forwarding class.
public protocol BASICForwarding: AnyObject {
    nonisolated var basicForward: BASICForwardState { get }
}

/// A call from a forwarding class's override into its BASIC body.
public enum BASICForwardCall {
    /// An argument as the BASIC body takes it.
    public enum Value {
        case number(Double)
        case boolean(Bool)
        case string(String)
    }

    /// What the thunk reads: the object, the arguments, and the result it
    /// writes. Numbers and truth values as doubles; strings and the object
    /// as their addresses.
    final class Frame {
        var values: [Double]
        var result: Double = 0
        init(values: [Double]) { self.values = values }
    }

    /// Calls the body; nil when it could not be called (no run, or the run
    /// did not answer in time), and the framework's own method answers.
    static func perform(_ target: Double, _ me: AnyObject, _ arguments: [Value]) -> Frame? {
        var values = [Double(UInt(bitPattern: Unmanaged.passUnretained(me).toOpaque()))]
        for argument in arguments {
            switch argument {
            case .number(let number): values.append(number)
            case .boolean(let flag): values.append(flag ? 1 : 0)
            // Owned, as R1.5's bridges hand a string to a BASIC body.
            case .string(let text): values.append(Double(UInt(bitPattern: basicRTSwiftStringOut(text))))
            }
        }
        let frame = Frame(values: values)
        let pointer = Unmanaged.passRetained(frame).toOpaque()
        defer { Unmanaged<Frame>.fromOpaque(pointer).release() }
        return WasmForward.call(target, frame: pointer) ? frame : nil
    }

    public static func void(_ target: Double, _ me: AnyObject, _ arguments: [Value]) -> Bool {
        perform(target, me, arguments) != nil
    }

    public static func number(_ target: Double, _ me: AnyObject, _ arguments: [Value]) -> Double? {
        perform(target, me, arguments)?.result
    }

    public static func boolean(_ target: Double, _ me: AnyObject, _ arguments: [Value]) -> Bool? {
        perform(target, me, arguments).map { $0.result != 0 }
    }

    /// A string the body hands back is owned, and released once read.
    public static func string(_ target: Double, _ me: AnyObject, _ arguments: [Value]) -> String? {
        guard let frame = perform(target, me, arguments) else { return nil }
        let pointer = UnsafeMutableRawPointer(bitPattern: UInt(frame.result))
        defer { basicRTSwiftStringRelease(pointer) }
        return basicRTSwiftStringIn(pointer)
    }

    /// The entries a compiled program uses for its forwarding objects and
    /// their thunks. None needs the main thread: they touch only what the
    /// object carries for BASIC, and the frame.
    static let entries: [String: WasmEntryPoint] = {
        func object(_ bits: Double) -> BASICForwarding? {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: UInt(bits)) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? BASICForwarding
        }
        func frame(_ bits: Double) -> Frame? {
            UnsafeMutableRawPointer(bitPattern: UInt(bits)).map { Unmanaged<Frame>.fromOpaque($0).takeUnretainedValue() }
        }
        func argument(_ a: UnsafePointer<Double>) -> Double {
            guard let frame = frame(a[0]), frame.values.indices.contains(Int(a[1])) else { return 0 }
            return frame.values[Int(a[1])]
        }
        var entries: [String: WasmEntryPoint] = [
            // NEW: what the object is, and its own fields' record (owned).
            "basic_forward_setup": WasmEntryPoint(arity: 3) { a in
                guard let state = object(a[0])?.basicForward else { return 0 }
                state.typeIndex = Int(a[1])
                state.record = UnsafeMutableRawPointer(bitPattern: UInt(a[2]))
                return 0
            },
            "basic_forward_override": WasmEntryPoint(arity: 3) { a in
                object(a[0])?.basicForward.setTarget(Int(a[1]), a[2])
                return 0
            },
            // Borrowed: the object keeps it.
            "basic_forward_record": WasmEntryPoint(arity: 1) { a in
                (object(a[0])?.basicForward.record).map { Double(UInt(bitPattern: $0)) } ?? 0
            },
            "basic_forward_type_index": WasmEntryPoint(arity: 1) { a in
                Double(object(a[0])?.basicForward.typeIndex ?? -1)
            },
            "basic_forward_arg_number": WasmEntryPoint(arity: 2) { a in argument(a) },
            "basic_forward_arg_boolean": WasmEntryPoint(arity: 2) { a in argument(a) != 0 ? 1 : 0 },
            "basic_forward_arg_pointer": WasmEntryPoint(arity: 2) { a in argument(a) },
        ]
        // The result as a number, a truth value or a string's address: all
        // one double by the time an entry has them.
        let result = WasmEntryPoint(arity: 2) { a in
            frame(a[0])?.result = a[1]
            return 0
        }
        for kind in ["number", "boolean", "pointer"] { entries["basic_forward_result_\(kind)"] = result }
        return entries
    }()
}
