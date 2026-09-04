import BASICCore
import BASICRT
import Foundation

// BASICRTHost — TUIKit, for a compiled program.
//
// The binding itself is BASICCore's: which word a table answers, what a
// short row does, where a menu bar goes, were all settled there control by
// control. A second copy of that here would drift from it the first time
// either changed, and a difference between the two runtimes is the one
// thing this compiler exists not to have. So this is the thin part only:
// the program's handlers by name, the values crossing between the two
// runtimes, and the errors coming back.

/// The BASIC handler a control calls: the compiler emits one trampoline per
/// function and registers it by name.
typealias RTHandlerTrampoline = @convention(c) (UnsafeMutableRawPointer?) -> Void

/// The program's named handlers.
enum RTTUIHandlers {
    nonisolated(unsafe) static var trampolines: [String: RTHandlerTrampoline] = [:]

    static func call(_ name: String) {
        guard let trampoline = trampolines[name.uppercased()] else { return }
        trampoline(nil)
    }
}

@_cdecl("basic_rt_host_handler_register")
public func basic_rt_host_handler_register(_ name: UnsafePointer<CChar>, _ handler: UnsafeMutableRawPointer) {
    RTTUIHandlers.trampolines[String(cString: name).uppercased()] = unsafeBitCast(handler, to: RTHandlerTrampoline.self)
}

// MARK: - The two value shapes

private func bridgeValue(_ value: RTValue) -> BASICCompiledTUI.Value {
    switch value {
    case .number(let number): return .number(number)
    case .boolean(let flag): return .boolean(flag)
    case .string(let text): return .string(text.description)
    case .system(let object):
        guard let handle = object.payload as? RTTUIHandle else { return .empty }
        return .handle(id: handle.id, kind: handle.typeName)
    default:
        // Everything else a control could be handed reads as its text, which
        // is what the interpreter's own `tuiPlain` does with it.
        if let text = value.string { return .string(text.description) }
        if let number = value.number { return .number(number) }
        return .empty
    }
}

private func runtimeValue(_ value: BASICCompiledTUI.Value) -> RTValue {
    switch value {
    case .number(let number): return .number(number)
    case .boolean(let flag): return .boolean(flag)
    case .string(let text): return .string(RTText(text))
    case .handle(let id, let kind): return .system(RTSystemObject(typeName: kind, payload: RTTUIHandle(id: id, typeName: kind)))
    case .empty: return .empty
    }
}

/// Calls the program's handler, by name, from inside a frame.
private func invokeNamedHandler(_ name: String, _ arguments: [BASICCompiledTUI.Value]) {
    RTTUIHandlers.call(name)
}

// MARK: - The ABI

@_cdecl("basic_rt_host_tui_new")
public func basic_rt_host_tui_new(_ typeName: UnsafePointer<CChar>, _ count: Int, _ arguments: UnsafePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer {
    let name = String(cString: typeName)
    let values = (0..<count).map { bridgeValue(rtValue(arguments[$0])) }
    do {
        return rtOwned(RTValue.number(Double(try BASICCompiledTUI.make(typeName: name, arguments: values))))
    } catch let failure as BASICCompiledTUI.Failure {
        basic_rt_fail(failure.message)
    } catch {
        basic_rt_fail("\(error)")
    }
}

@_cdecl("basic_rt_host_tui_call")
public func basic_rt_host_tui_call(_ typeName: UnsafePointer<CChar>, _ id: Int, _ method: UnsafePointer<CChar>, _ count: Int, _ arguments: UnsafePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer {
    let type = String(cString: typeName)
    let name = String(cString: method)
    let values = (0..<count).map { bridgeValue(rtValue(arguments[$0])) }
    do {
        let answer = try BASICCompiledTUI.call(
            typeName: type, id: id, method: name,
            arguments: values, invokeHandler: invokeNamedHandler
        )
        return rtOwned(runtimeValue(answer))
    } catch let failure as BASICCompiledTUI.Failure {
        basic_rt_fail(failure.message)
    } catch {
        basic_rt_fail("\(error)")
    }
}
