import Foundation

// BASICRT composites — TYPE records and CLASS objects.
//
// In the interpreter both are dictionaries held *by value*: assigning one
// copies it, and a method call copies the receiver in and writes it back.
// The runtime keeps that shape: an RTComposite is a typed slot list, copied
// deeply on every store that is not a transfer of a fresh value.
//
// Types are registered at program start from the compiler's tables, so the
// runtime can build defaults, copy, and print `<Name>` without the compiler
// emitting per-type code.

/// One registered TYPE or CLASS.
final class RTCompositeType {
    let name: String
    /// Field kinds: 0 number, 1 string, 2 boolean, 3 composite.
    let kinds: [UInt8]
    /// For composite fields, the field's type index; else -1.
    let subtypes: [Int]
    let defaultNumbers: [Double]
    let defaultStrings: [String?]

    init(name: String, kinds: [UInt8], subtypes: [Int], defaultNumbers: [Double], defaultStrings: [String?]) {
        self.name = name
        self.kinds = kinds
        self.subtypes = subtypes
        self.defaultNumbers = defaultNumbers
        self.defaultStrings = defaultStrings
    }
}

enum RTTypes {
    nonisolated(unsafe) static var registry: [RTCompositeType?] = []

    static func type(_ index: Int) -> RTCompositeType {
        guard index >= 0, index < registry.count, let type = registry[index] else {
            basic_rt_fail("Unknown TYPE or CLASS #\(index)")
        }
        return type
    }
}

/// The runtime's record/object.
public final class RTComposite {
    let typeIndex: Int
    var numbers: [Double]
    var strings: [RTString?]
    var composites: [RTComposite?]

    /// A default instance: numbers 0 (or the field default), strings ""
    /// (or the default), nested composites built eagerly.
    init(typeIndex: Int) {
        let type = RTTypes.type(typeIndex)
        self.typeIndex = typeIndex
        numbers = type.defaultNumbers
        strings = type.defaultStrings.map { $0.map(RTString.init) }
        composites = type.kinds.enumerated().map { index, kind in
            kind == 3 ? RTComposite(typeIndex: type.subtypes[index]) : nil
        }
    }

    private init(copying other: RTComposite) {
        typeIndex = other.typeIndex
        numbers = other.numbers
        strings = other.strings
        composites = other.composites.map { $0.map { RTComposite(copying: $0) } }
    }

    /// A deep copy — value semantics.
    func copy() -> RTComposite {
        RTComposite(copying: self)
    }

    /// Take another instance's contents, keeping this identity.
    func assign(from other: RTComposite) {
        numbers = other.numbers
        strings = other.strings
        composites = other.composites.map { $0.map { RTComposite(copying: $0) } }
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

/// Registers type `index`. Tables are the compiler's constants and stay alive.
@_cdecl("basic_rt_type_register")
public func basic_rt_type_register(
    _ index: Int, _ name: UnsafePointer<CChar>, _ fieldCount: Int,
    _ kinds: UnsafePointer<UInt8>, _ subtypes: UnsafePointer<Int>,
    _ defaultNumbers: UnsafePointer<Double>, _ defaultStrings: UnsafePointer<UnsafePointer<CChar>?>
) {
    while RTTypes.registry.count <= index { RTTypes.registry.append(nil) }
    RTTypes.registry[index] = RTCompositeType(
        name: String(cString: name),
        kinds: (0..<fieldCount).map { kinds[$0] },
        subtypes: (0..<fieldCount).map { subtypes[$0] },
        defaultNumbers: (0..<fieldCount).map { defaultNumbers[$0] },
        defaultStrings: (0..<fieldCount).map { defaultStrings[$0].map { String(cString: $0) } }
    )
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
    rtComposite(pointer).numbers[field]
}

@_cdecl("basic_rt_composite_set_number")
public func basic_rt_composite_set_number(_ pointer: UnsafeMutableRawPointer?, _ field: Int, _ value: Double) {
    rtComposite(pointer).numbers[field] = value
}

/// Owned (+1); nil when the field is empty.
@_cdecl("basic_rt_composite_get_string")
public func basic_rt_composite_get_string(_ pointer: UnsafeMutableRawPointer?, _ field: Int) -> UnsafeMutableRawPointer? {
    guard let string = rtComposite(pointer).strings[field] else { return nil }
    return Unmanaged.passRetained(string).toOpaque()
}

@_cdecl("basic_rt_composite_set_string")
public func basic_rt_composite_set_string(_ pointer: UnsafeMutableRawPointer?, _ field: Int, _ value: UnsafeMutableRawPointer?) {
    rtComposite(pointer).strings[field] = value.map { Unmanaged<RTString>.fromOpaque($0).takeUnretainedValue() }
}

/// Borrowed: the nested record itself, so `a.b.c = 1` mutates in place.
@_cdecl("basic_rt_composite_get_composite")
public func basic_rt_composite_get_composite(_ pointer: UnsafeMutableRawPointer?, _ field: Int) -> UnsafeMutableRawPointer? {
    guard let nested = rtComposite(pointer).composites[field] else { return nil }
    return Unmanaged.passUnretained(nested).toOpaque()
}

/// Stores a deep copy of `value` into the field.
@_cdecl("basic_rt_composite_set_composite")
public func basic_rt_composite_set_composite(_ pointer: UnsafeMutableRawPointer?, _ field: Int, _ value: UnsafeMutableRawPointer?) {
    rtComposite(pointer).composites[field] = value.map { rtComposite($0).copy() }
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
