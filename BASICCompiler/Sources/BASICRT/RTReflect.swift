import Foundation

// BASICRT reflection — FIELDCOUNT, FIELDNAME$, FIELDMETA, FIELDVALUE,
// FIELDVALUE$, SETFIELD: the interpreter's `reflected*` family over the
// registered type tables. `REFLECT(variable)` needs the variable's own
// metadata and is not compiled yet.

enum RTReflect {
    static func composite(_ value: RTValue) -> RTComposite {
        guard case .composite(let composite) = value else { basic_rt_fail("Reflection expects a record or object") }
        return composite
    }

    /// The field a selector names: an index or a case-insensitive name.
    static func field(of composite: RTComposite, selector: RTValue) -> (index: Int, info: RTFieldInfo) {
        let fields = RTTypes.type(composite.typeIndex).fields
        if let number = selector.number {
            guard number.rounded() == number else { basic_rt_fail("Field index must be an integer") }
            let index = Int(number)
            guard fields.indices.contains(index) else { basic_rt_fail("Field index out of range") }
            return (index, fields[index])
        }
        if let name = selector.string?.description {
            guard let index = fields.firstIndex(where: { $0.name == name.uppercased() }) else { basic_rt_fail("Unknown field \(name)") }
            return (index, fields[index])
        }
        basic_rt_fail("Field selector must be a number or string")
    }

    /// The interpreter's `reflectionDictionary`.
    static func dictionary(metadata: [String: RTValue], name: String, typeName: String, path: String) -> RTValue {
        let dictionary = RTDictionary()
        dictionary.values = metadata
        dictionary.values["name"] = .string(RTText(name))
        dictionary.values["type"] = .string(RTText(typeName))
        dictionary.values["path"] = .string(RTText(path))
        return .dictionary(dictionary)
    }

    /// `SETFIELD`'s leniency: text becomes a number or boolean for such fields.
    static func coerceReflected(_ value: RTValue, to info: RTFieldInfo) -> RTValue {
        do throws(RTFailure) {
            if case .string(let string) = value {
                let text = string.description.trimmingCharacters(in: .whitespacesAndNewlines)
                switch info.type {
                case .number, .integer:
                    if let number = Double(text) { return try RTCoerce.coerce(.number(number), to: info.type, name: info.displayName) }
                case .boolean:
                    switch text.uppercased() {
                    case "TRUE": return try RTCoerce.coerce(.boolean(true), to: info.type, name: info.displayName)
                    case "FALSE": return try RTCoerce.coerce(.boolean(false), to: info.type, name: info.displayName)
                    case "1": return try RTCoerce.coerce(.number(1), to: info.type, name: info.displayName)
                    case "0": return try RTCoerce.coerce(.number(0), to: info.type, name: info.displayName)
                    default: break
                    }
                default: break
                }
            }
            return try RTCoerce.coerce(value, to: info.type, name: info.displayName)
        } catch { error.raise() }
    }
}

@_cdecl("basic_rt_field_count")
public func basic_rt_field_count(_ value: UnsafeMutableRawPointer?) -> Double {
    Double(RTTypes.type(RTReflect.composite(rtValue(value)).typeIndex).fields.count)
}

@_cdecl("basic_rt_field_name")
public func basic_rt_field_name(_ value: UnsafeMutableRawPointer?, _ selector: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    rtOwned(RTReflect.field(of: RTReflect.composite(rtValue(value)), selector: rtValue(selector)).info.displayName)
}

@_cdecl("basic_rt_field_meta")
public func basic_rt_field_meta(_ value: UnsafeMutableRawPointer?, _ selector: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    let info = RTReflect.field(of: RTReflect.composite(rtValue(value)), selector: rtValue(selector)).info
    return rtOwned(RTReflect.dictionary(metadata: info.metadata, name: info.displayName, typeName: info.type.name, path: info.displayName))
}

@_cdecl("basic_rt_field_value")
public func basic_rt_field_value(_ value: UnsafeMutableRawPointer?, _ selector: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    let composite = RTReflect.composite(rtValue(value))
    let field = RTReflect.field(of: composite, selector: rtValue(selector))
    return rtOwned(composite.fields[field.index].copied())
}

/// `SETFIELD(value, selector, newValue)`: a copy with the field replaced.
@_cdecl("basic_rt_set_field")
public func basic_rt_set_field(_ value: UnsafeMutableRawPointer?, _ selector: UnsafeMutableRawPointer?, _ newValue: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    guard case .composite(let original) = rtValue(value) else { basic_rt_fail("SETFIELD expects a record or object") }
    let field = RTReflect.field(of: original, selector: rtValue(selector))
    let copy = original.copy()
    copy.fields[field.index] = RTReflect.coerceReflected(rtValue(newValue).copied(), to: field.info)
    return rtOwned(.composite(copy))
}
