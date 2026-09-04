import Foundation

// BASICRT composites — TYPE records and CLASS objects.
//
// In the interpreter both are dictionaries held *by value*: assigning one
// copies it, and a method call copies the receiver in and writes it back.
// The runtime keeps that shape: an RTComposite is a slot list of RTValues,
// copied deeply on every store that is not a transfer of a fresh value.
//
// Types are registered at program start from the compiler's descriptors, so
// the runtime can build defaults, copy, print `<Name>`, decode JSON, and
// find fields by name without the compiler emitting per-type code.

/// The runtime's record/object.
package final class RTComposite {
    let typeIndex: Int
    /// One value per field, in the registered slot order.
    var fields: [RTValue]

    /// A default instance: every field its declared default (or its
    /// type's), nested records and arrays built eagerly.
    init(typeIndex: Int) {
        let type = RTTypes.type(typeIndex)
        self.typeIndex = typeIndex
        fields = type.fields.map { RTTypes.defaultValue(for: $0) }
    }

    private init(copying other: RTComposite) {
        typeIndex = other.typeIndex
        fields = other.fields.map { $0.copied() }
    }

    /// A deep copy — value semantics.
    func copy() -> RTComposite {
        RTComposite(copying: self)
    }

    /// Take another instance's contents, keeping this identity.
    func assign(from other: RTComposite) {
        fields = other.fields.map { $0.copied() }
    }
}

@inline(__always)
func rtComposite(_ pointer: UnsafeMutableRawPointer?) -> RTComposite {
    guard let pointer else { basic_rt_fail("Record or object was never set") }
    return Unmanaged<RTComposite>.fromOpaque(pointer).takeUnretainedValue()
}

@inline(__always)
func rtOwned(_ composite: RTComposite) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(composite).toOpaque()
}

/// Registers type `index` from its JSON descriptor.
@_cdecl("basic_rt_type_register")
public func basic_rt_type_register(_ index: Int, _ descriptor: UnsafePointer<CChar>) {
    RTTypes.register(index: index, descriptor: String(cString: descriptor))
}

@_cdecl("basic_rt_composite_new")
public func basic_rt_composite_new(_ typeIndex: Int) -> UnsafeMutableRawPointer {
    rtOwned(RTComposite(typeIndex: typeIndex))
}

@_cdecl("basic_rt_composite_copy")
public func basic_rt_composite_copy(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    rtOwned(rtComposite(pointer).copy())
}

/// Assign in place: `destination` takes `source`'s contents (deep copy) but
/// keeps its identity. Used to write a method's `ME` back when the slot is
/// borrowed from the caller — replacing the pointer would free the caller's
/// object.
@_cdecl("basic_rt_composite_assign")
public func basic_rt_composite_assign(_ destination: UnsafeMutableRawPointer?, _ source: UnsafeMutableRawPointer?) {
    let target = rtComposite(destination)
    let value = rtComposite(source)
    guard target !== value else { return }
    target.assign(from: value)
}

@_cdecl("basic_rt_composite_release")
public func basic_rt_composite_release(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<RTComposite>.fromOpaque(pointer).release()
}

/// The runtime type of an object, for method dispatch.
@_cdecl("basic_rt_composite_type")
public func basic_rt_composite_type(_ pointer: UnsafeMutableRawPointer?) -> Int {
    rtComposite(pointer).typeIndex
}

@_cdecl("basic_rt_composite_get_number")
public func basic_rt_composite_get_number(_ pointer: UnsafeMutableRawPointer?, _ field: Int) -> Double {
    rtComposite(pointer).fields[field].number ?? 0
}

@_cdecl("basic_rt_composite_set_number")
public func basic_rt_composite_set_number(_ pointer: UnsafeMutableRawPointer?, _ field: Int, _ value: Double) {
    rtComposite(pointer).fields[field] = .number(value)
}

@_cdecl("basic_rt_composite_get_boolean")
public func basic_rt_composite_get_boolean(_ pointer: UnsafeMutableRawPointer?, _ field: Int) -> Bool {
    rtComposite(pointer).fields[field].truthy
}

@_cdecl("basic_rt_composite_set_boolean")
public func basic_rt_composite_set_boolean(_ pointer: UnsafeMutableRawPointer?, _ field: Int, _ value: Bool) {
    rtComposite(pointer).fields[field] = .boolean(value)
}

/// Owned (+1); nil when the field is empty.
@_cdecl("basic_rt_composite_get_string")
public func basic_rt_composite_get_string(_ pointer: UnsafeMutableRawPointer?, _ field: Int) -> UnsafeMutableRawPointer? {
    guard let string = rtComposite(pointer).fields[field].string, string.byteCount > 0 else { return nil }
    return rtOwned(string)
}

@_cdecl("basic_rt_composite_set_string")
public func basic_rt_composite_set_string(_ pointer: UnsafeMutableRawPointer?, _ field: Int, _ value: UnsafeMutableRawPointer?) {
    rtComposite(pointer).fields[field] = .string(rtString(value))
}

/// Borrowed: the nested record itself, so `a.b.c = 1` mutates in place.
/// A NULL or EMPTY object field is materialized as a default instance.
@_cdecl("basic_rt_composite_get_composite")
public func basic_rt_composite_get_composite(_ pointer: UnsafeMutableRawPointer?, _ field: Int) -> UnsafeMutableRawPointer? {
    let composite = rtComposite(pointer)
    if case .composite(let nested) = composite.fields[field] {
        return Unmanaged.passUnretained(nested).toOpaque()
    }
    guard case .composite(let index) = RTTypes.type(composite.typeIndex).fields[field].type else { return nil }
    let nested = RTComposite(typeIndex: index)
    composite.fields[field] = .composite(nested)
    return Unmanaged.passUnretained(nested).toOpaque()
}

/// Stores a deep copy of `value` into the field.
@_cdecl("basic_rt_composite_set_composite")
public func basic_rt_composite_set_composite(_ pointer: UnsafeMutableRawPointer?, _ field: Int, _ value: UnsafeMutableRawPointer?) {
    rtComposite(pointer).fields[field] = value.map { .composite(rtComposite($0).copy()) } ?? .empty
}

/// Borrowed: the array held by an array field, so elements mutate in place.
@_cdecl("basic_rt_composite_get_array")
public func basic_rt_composite_get_array(_ pointer: UnsafeMutableRawPointer?, _ field: Int) -> UnsafeMutableRawPointer {
    let composite = rtComposite(pointer)
    if case .array(let array) = composite.fields[field] {
        return Unmanaged.passUnretained(array).toOpaque()
    }
    let fieldType = RTTypes.type(composite.typeIndex).fields[field].type
    guard case .array(let element, let dims) = fieldType else { basic_rt_fail("Field is not an array") }
    let array = RTArray(element: element, dims: dims)
    composite.fields[field] = .array(array)
    return Unmanaged.passUnretained(array).toOpaque()
}

/// `rec.Items = value`: the value (a boxed array) coerced to the field's
/// declared shape, as assigning to an array variable does.
@_cdecl("basic_rt_composite_set_array")
public func basic_rt_composite_set_array(_ pointer: UnsafeMutableRawPointer?, _ field: Int, _ value: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>) {
    let composite = rtComposite(pointer)
    let info = RTTypes.type(composite.typeIndex).fields[field]
    do throws(RTFailure) {
        composite.fields[field] = try RTCoerce.coerce(rtValue(value), to: info.type, name: String(cString: name))
    } catch { error.raise() }
}

/// A VARIANT or DICTIONARY field, boxed and owned (a copy).
@_cdecl("basic_rt_composite_get_value")
public func basic_rt_composite_get_value(_ pointer: UnsafeMutableRawPointer?, _ field: Int) -> UnsafeMutableRawPointer {
    rtOwned(rtComposite(pointer).fields[field].copied())
}

/// Stores a boxed value into a VARIANT field (a copy), or into a DICTIONARY
/// field with the interpreter's coercion.
@_cdecl("basic_rt_composite_set_value")
public func basic_rt_composite_set_value(_ pointer: UnsafeMutableRawPointer?, _ field: Int, _ value: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>) {
    let composite = rtComposite(pointer)
    let info = RTTypes.type(composite.typeIndex).fields[field]
    do throws(RTFailure) {
        composite.fields[field] = try RTCoerce.coerce(rtValue(value).copied(), to: info.type, name: String(cString: name))
    } catch { error.raise() }
}

/// Borrowed dictionary held by a DICTIONARY field.
@_cdecl("basic_rt_composite_get_dictionary")
public func basic_rt_composite_get_dictionary(_ pointer: UnsafeMutableRawPointer?, _ field: Int) -> UnsafeMutableRawPointer {
    let composite = rtComposite(pointer)
    if case .dictionary(let dictionary) = composite.fields[field] {
        return Unmanaged.passUnretained(dictionary).toOpaque()
    }
    let dictionary = RTDictionary()
    composite.fields[field] = .dictionary(dictionary)
    return Unmanaged.passUnretained(dictionary).toOpaque()
}

/// `PRINT` of a record or object: `<Name>`.
@_cdecl("basic_rt_print_composite")
public func basic_rt_print_composite(_ pointer: UnsafeMutableRawPointer?) {
    RTConsole.write("<\(RTTypes.type(rtComposite(pointer).typeIndex).name)>")
}

/// `<Name>` as an owned string, for interpolation and PRINT USING.
@_cdecl("basic_rt_composite_text")
public func basic_rt_composite_text(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    rtOwned("<\(RTTypes.type(rtComposite(pointer).typeIndex).name)>")
}
