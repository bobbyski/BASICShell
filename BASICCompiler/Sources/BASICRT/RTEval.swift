import Foundation

// BASICRT EVAL — an expression in a string, in a compiled program
// (BBC_ADINS.md A10.7, Bobby's ruling B8).
//
// A compiled program has no names at run time, so before each EVAL basicc
// binds every variable in scope by name (`basic_rt_eval_bind`), as PLAY's
// `=name;` binds its own. The program's FUNCTIONs are registered once, at
// the start, through trampolines (`V.NAME`) that take their arguments boxed
// and box what they return. The string itself is parsed and evaluated by
// BASICCore, the interpreter's own code, in the host half
// (`basic_rt_host_eval`): the stubs have no BASICCore, and say so.

/// The shapes a value takes crossing to the evaluator and back.
package indirect enum RTPlainValue {
    case empty
    case null
    case number(Double)
    case string(String)
    case boolean(Bool)
    case array(upperBounds: [Int], values: [RTPlainValue])
    case record(type: String, fields: [(name: String, value: RTPlainValue)])
    case dictionary([String: RTPlainValue])
}

/// What a FUNCTION's trampoline is: arguments in, value out, both boxed.
typealias RTEvalTrampoline = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

package enum RTEval {
    /// The variables bound for the EVAL about to run, by normalized name.
    nonisolated(unsafe) static var bindings: [String: RTValue] = [:]
    /// The program's FUNCTIONs, by normalized name.
    nonisolated(unsafe) static var functions: [String: RTEvalTrampoline] = [:]
    /// `OPTION EVAL FULL`.
    nonisolated(unsafe) package static var fullAccess = false

    /// A bound variable's value, or nil when nothing by that name is bound.
    package static func value(named name: String) -> RTPlainValue? {
        bindings[name].map(plain)
    }

    /// Calls the program's FUNCTION `name`; nil when it has none so named.
    package static func call(_ name: String, _ arguments: [RTPlainValue]) -> RTPlainValue? {
        guard let trampoline = functions[name] else { return nil }
        let list = RTArray(upperBounds: [max(0, arguments.count - 1)], isDynamic: false, element: .variant,
                           values: arguments.map(runtimeValue))
        let pointer = Unmanaged.passRetained(list).toOpaque()
        defer { Unmanaged<RTArray>.fromOpaque(pointer).release() }
        let result = trampoline(pointer)
        defer { basic_rt_value_release(result) }
        return plain(rtValue(result))
    }

    /// `value` as a box the program owns.
    package static func owned(_ value: RTPlainValue) -> UnsafeMutableRawPointer {
        rtOwned(runtimeValue(value))
    }

    static func plain(_ value: RTValue) -> RTPlainValue {
        switch value {
        case .empty: return .empty
        case .null: return .null
        case .number(let number): return .number(number)
        case .string(let text): return .string(text.description)
        case .boolean(let flag): return .boolean(flag)
        case .array(let array): return .array(upperBounds: array.upperBounds, values: array.values.map(plain))
        case .dictionary(let dictionary): return .dictionary(dictionary.values.mapValues(plain))
        case .composite(let composite):
            guard composite.typeIndex >= 0, composite.typeIndex < RTTypes.registry.count,
                  let type = RTTypes.registry[composite.typeIndex] else { return .empty }
            return .record(type: type.name, fields: zip(type.fields, composite.fields).map { ($0.displayName, plain($1)) })
        case .date(let text), .time(let text), .datetime(let text): return .string(text)
        default: return .string(value.string?.description ?? "")
        }
    }

    static func runtimeValue(_ value: RTPlainValue) -> RTValue {
        switch value {
        case .empty: return .empty
        case .null: return .null
        case .number(let number): return .number(number)
        case .string(let text): return .string(RTText(text))
        case .boolean(let flag): return .boolean(flag)
        case .array(let upperBounds, let values):
            return .array(RTArray(upperBounds: upperBounds, isDynamic: false, element: .variant, values: values.map(runtimeValue)))
        case .dictionary(let entries):
            let dictionary = RTDictionary()
            dictionary.values = entries.mapValues(runtimeValue)
            return .dictionary(dictionary)
        case .record(let type, let fields):
            guard let index = RTTypes.registry.firstIndex(where: { $0?.name.uppercased() == type.uppercased() }) else { return .empty }
            let composite = RTComposite(typeIndex: index)
            for (name, field) in fields {
                if let slot = RTTypes.type(index).fieldIndex(named: name.uppercased()) {
                    composite.fields[slot] = runtimeValue(field)
                }
            }
            return .composite(composite)
        }
    }
}

/// Starts an EVAL's bindings afresh.
@_cdecl("basic_rt_eval_begin")
public func basic_rt_eval_begin() {
    RTEval.bindings.removeAll(keepingCapacity: true)
}

/// Binds a variable for the next EVAL: its name and its value, boxed
/// (borrowed).
@_cdecl("basic_rt_eval_bind")
public func basic_rt_eval_bind(_ name: UnsafeMutableRawPointer?, _ value: UnsafeMutableRawPointer?) {
    RTEval.bindings[rtText(name).uppercased()] = rtValue(value).copied()
}

/// Registers a FUNCTION an EVAL may call, by its trampoline.
@_cdecl("basic_rt_eval_function")
public func basic_rt_eval_function(_ name: UnsafePointer<CChar>, _ trampoline: UnsafeMutableRawPointer) {
    RTEval.functions[String(cString: name).uppercased()] = unsafeBitCast(trampoline, to: RTEvalTrampoline.self)
}

/// `OPTION EVAL FULL` (1) or `OPTION EVAL PURE` (0).
@_cdecl("basic_rt_eval_option")
public func basic_rt_eval_option(_ full: Double) {
    RTEval.fullAccess = full != 0
}

@_silgen_name("basic_rt_host_eval") func rtHostEval(_ text: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer

/// `EVAL(s$)`, over what was just bound: an owned box.
@_cdecl("basic_rt_eval")
public func basic_rt_eval(_ text: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    rtHostEval(text)
}
