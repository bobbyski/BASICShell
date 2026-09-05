import BASICCore
import BASICRT
import Foundation

// BASICRTHost — RichSwift, for a compiled program.
//
// The same arrangement as the TUI bridge beside it, and for the same reason:
// the binding is BASICCore's, and this is only the values crossing between
// the two runtimes.

private func bridgeValue(_ value: RTValue) -> BASICCompiledRich.Value {
    switch value {
    case .number(let number): return .number(number)
    case .boolean(let flag): return .boolean(flag)
    case .string(let text): return .string(text.description)
    case .system(let object):
        guard let handle = object.payload as? RTRichHandle else { return .empty }
        return .handle(id: handle.id, kind: handle.typeName)
    default:
        // A number in a table row is the ordinary case, so anything else
        // crosses as what it prints as — the interpreter's own rule.
        if let text = value.string { return .string(text.description) }
        if let number = value.number { return .number(number) }
        return .empty
    }
}

private func runtimeValue(_ value: BASICCompiledRich.Value) -> RTValue {
    switch value {
    case .number(let number): return .number(number)
    case .boolean(let flag): return .boolean(flag)
    case .string(let text): return .string(RTText(text))
    case .handle(let id, let kind): return .system(RTSystemObject(typeName: kind, payload: RTRichHandle(id: id, typeName: kind)))
    case .empty: return .empty
    }
}

@_cdecl("basic_rt_host_rich_new")
public func basic_rt_host_rich_new(_ typeName: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
    let name = String(cString: typeName)
    do {
        return rtOwned(RTValue.number(Double(try BASICCompiledRich.make(typeName: name))))
    } catch let failure as BASICCompiledRich.Failure {
        basic_rt_fail(failure.message)
    } catch {
        basic_rt_fail("\(error)")
    }
}

@_cdecl("basic_rt_host_rich_call")
public func basic_rt_host_rich_call(_ typeName: UnsafePointer<CChar>, _ id: Int, _ method: UnsafePointer<CChar>, _ count: Int, _ arguments: UnsafePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer {
    let type = String(cString: typeName)
    let name = String(cString: method)
    let values = (0..<count).map { bridgeValue(rtValue(arguments[$0])) }
    do {
        return rtOwned(runtimeValue(try BASICCompiledRich.call(typeName: type, id: id, method: name, arguments: values)))
    } catch let failure as BASICCompiledRich.Failure {
        basic_rt_fail(failure.message)
    } catch {
        basic_rt_fail("\(error)")
    }
}
