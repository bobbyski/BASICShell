import BASICCore
import BASICRT
import Foundation

// BASICRTHost — EVAL for a compiled program (BBC_ADINS.md A10.7).
//
// The string is parsed and evaluated by BASICCore, the interpreter's own
// code, over the variables the program bound for this EVAL and the FUNCTIONs
// it registered (BASICRT's `RTEval`). This is only the crossing: values one
// way and the other, and an error back as the program's own.

private func evalValue(_ value: RTPlainValue) -> BASICCompiledEval.Value {
    switch value {
    case .empty: return .empty
    case .null: return .null
    case .number(let number): return .number(number)
    case .string(let text): return .string(text)
    case .boolean(let flag): return .boolean(flag)
    case .array(let upperBounds, let values): return .array(upperBounds: upperBounds, values: values.map(evalValue))
    case .record(let type, let fields):
        return .record(type: type, fields: fields.map { BASICCompiledEval.Field(name: $0.name, value: evalValue($0.value)) })
    case .dictionary(let entries): return .dictionary(entries.mapValues(evalValue))
    }
}

private func plainValue(_ value: BASICCompiledEval.Value) -> RTPlainValue {
    switch value {
    case .empty: return .empty
    case .null: return .null
    case .number(let number): return .number(number)
    case .string(let text): return .string(text)
    case .boolean(let flag): return .boolean(flag)
    case .array(let upperBounds, let values): return .array(upperBounds: upperBounds, values: values.map(plainValue))
    case .record(let type, let fields): return .record(type: type, fields: fields.map { ($0.name, plainValue($0.value)) })
    case .dictionary(let entries): return .dictionary(entries.mapValues(plainValue))
    }
}

@_cdecl("basic_rt_host_eval")
public func basic_rt_host_eval(_ text: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    do {
        let result = try BASICCompiledEval.evaluate(
            rtText(text),
            fullAccess: RTEval.fullAccess,
            variable: { name in RTEval.value(named: name).map(evalValue) },
            function: { name, arguments in RTEval.call(name, arguments.map(plainValue)).map(evalValue) }
        )
        return RTEval.owned(plainValue(result))
    } catch let failure as BASICCompiledEval.Failure {
        if failure.isTypeError { failure.message.withCString { basic_rt_fail_type($0) } }
        basic_rt_fail(failure.message)
    } catch {
        basic_rt_fail("\(error)")
    }
}
