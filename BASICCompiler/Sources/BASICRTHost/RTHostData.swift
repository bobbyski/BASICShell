import BASICCore
import BASICRT
import Foundation

// BASICRTHost — the database, for a compiled program.
//
// The same arrangement as the Rich and TUI bridges beside it, and for the same
// reason: the providers, the ORM and the mapper are BASICCore's, and this is
// only the values crossing between the two runtimes.
//
// The one thing this bridge carries that those do not is an *object*. The ORM
// takes a CLASS instance and gives one back, so a composite has to survive the
// trip: out by field name, and back into a fresh instance of the same class.
// Slots stay BASICRT's business; names are what both sides agree on.

private func bridgeValue(_ value: RTValue) -> BASICCompiledData.Value {
    switch value {
    case .number(let number): return .number(number)
    case .boolean(let flag): return .boolean(flag)
    case .string(let text): return .string(text.description)
    case .empty, .null: return .empty
    case .composite(let composite):
        return .object(
            typeName: composite.typeDisplayName,
            fields: composite.namedFields.mapValues(bridgeValue)
        )
    case .system(let object):
        guard let handle = object.payload as? RTDataHandle else { return .empty }
        return .handle(id: handle.id, kind: handle.typeName)
    default:
        // A value the database cannot store crosses as what it prints as, and
        // BASICCore refuses it by name — the interpreter's own rule, and the
        // message a program should see.
        if let text = value.string { return .string(text.description) }
        if let number = value.number { return .number(number) }
        return .empty
    }
}

private func runtimeValue(_ value: BASICCompiledData.Value) -> RTValue {
    switch value {
    case .number(let number): return .number(number)
    case .string(let text): return .string(RTText(text))
    case .boolean(let flag): return .boolean(flag)
    case .handle(let id, let kind):
        return .system(RTSystemObject(typeName: kind, payload: RTDataHandle(id: id, typeName: kind)))
    case .object(let typeName, let fields):
        guard let composite = RTComposite.named(typeName, fields: fields.mapValues(runtimeValue)) else {
            basic_rt_fail("This program does not declare a CLASS named \(typeName)")
        }
        return .composite(composite)
    case .empty: return .empty
    }
}

@_cdecl("basic_rt_host_db_schema")
public func basic_rt_host_db_schema(_ json: UnsafePointer<CChar>) {
    do {
        try BASICCompiledData.registerSchema(String(cString: json))
    } catch let failure as BASICCompiledData.Failure {
        basic_rt_fail(failure.message)
    } catch {
        basic_rt_fail("\(error)")
    }
}

@_cdecl("basic_rt_host_db_new")
public func basic_rt_host_db_new(_ typeName: UnsafePointer<CChar>, _ count: Int, _ arguments: UnsafePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer {
    let name = String(cString: typeName)
    let values = (0..<count).map { bridgeValue(rtValue(arguments[$0])) }
    do {
        return rtOwned(runtimeValue(try BASICCompiledData.make(typeName: name, arguments: values)))
    } catch let failure as BASICCompiledData.Failure {
        basic_rt_fail(failure.message)
    } catch {
        basic_rt_fail("\(error)")
    }
}

@_cdecl("basic_rt_host_db_call")
public func basic_rt_host_db_call(_ typeName: UnsafePointer<CChar>, _ id: Int, _ method: UnsafePointer<CChar>, _ count: Int, _ arguments: UnsafePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer {
    let type = String(cString: typeName)
    let name = String(cString: method)
    let values = (0..<count).map { bridgeValue(rtValue(arguments[$0])) }
    do {
        return rtOwned(runtimeValue(try BASICCompiledData.call(typeName: type, id: id, method: name, arguments: values)))
    } catch let failure as BASICCompiledData.Failure {
        basic_rt_fail(failure.message)
    } catch {
        basic_rt_fail("\(error)")
    }
}
