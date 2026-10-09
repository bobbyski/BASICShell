import BASICCore
import BASICRT
import Foundation

// BASICRTHost — ActiveUI, for a program compiled to WebAssembly (BASIC-45).
//
// The windows are the app's: BASICStudio's, which answer the interpreter's
// own requests. What a control takes and does is BASICCore's, as for TUIKit;
// this is the thin part: the values crossing and the errors coming back.
// What the user does reaches the program's handlers through RTHostHosted's
// event collection, between statements and while a window's `run` waits.

/// The windows a run has. Installed with the rest of a hosted run's
/// services (`RTHostHosted`).
enum RTHostAUI {
    /// The app's windows, for the run in progress. Nil: a control says what
    /// the interpreter says when its host has none.
    nonisolated(unsafe) static var host: BASICAUIHost?
}

// MARK: - The two value shapes

private func bridgeValue(_ value: RTValue) -> BASICCompiledAUI.Value {
    switch value {
    case .number(let number): return .number(number)
    case .boolean(let flag): return .boolean(flag)
    case .string(let text): return .string(text.description)
    case .system(let object):
        guard let handle = object.payload as? RTAUIHandle else { return .empty }
        return .handle(id: handle.id, kind: handle.typeName)
    default:
        if let text = value.string { return .string(text.description) }
        if let number = value.number { return .number(number) }
        return .empty
    }
}

private func runtimeValue(_ value: BASICCompiledAUI.Value) -> RTValue {
    switch value {
    case .number(let number): return .number(number)
    case .boolean(let flag): return .boolean(flag)
    case .string(let text): return .string(RTText(text))
    case .handle(let id, let kind): return .system(RTSystemObject(typeName: kind, payload: RTAUIHandle(id: id, typeName: kind)))
    case .empty: return .empty
    }
}

// MARK: - The ABI

@_cdecl("basic_rt_host_aui_new")
public func basic_rt_host_aui_new(_ typeName: UnsafePointer<CChar>, _ count: Int, _ arguments: UnsafePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer {
    let values = (0..<count).map { bridgeValue(rtValue(arguments[$0])) }
    do {
        return rtOwned(RTValue.number(Double(try BASICCompiledAUI.make(typeName: String(cString: typeName), arguments: values, host: RTHostAUI.host))))
    } catch let failure as BASICCompiledAUI.Failure {
        basic_rt_fail(failure.message)
    } catch {
        basic_rt_fail("\(error)")
    }
}

@_cdecl("basic_rt_host_aui_call")
public func basic_rt_host_aui_call(_ typeName: UnsafePointer<CChar>, _ id: Int, _ method: UnsafePointer<CChar>, _ count: Int, _ arguments: UnsafePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer {
    let values = (0..<count).map { bridgeValue(rtValue(arguments[$0])) }
    do {
        let answer = try BASICCompiledAUI.call(
            typeName: String(cString: typeName), id: id, method: String(cString: method),
            arguments: values, host: RTHostAUI.host,
            // A window's `run`: Stop ends the run from here, and the
            // program's handlers run as the user works the window.
            pump: {
                RTHosted.checkStop?()
                basic_rt_events_drain(16)
            }
        )
        return rtOwned(runtimeValue(answer))
    } catch let failure as BASICCompiledAUI.Failure {
        basic_rt_fail(failure.message)
    } catch {
        basic_rt_fail("\(error)")
    }
}
