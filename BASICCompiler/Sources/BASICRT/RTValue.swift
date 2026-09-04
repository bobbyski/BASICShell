import Foundation

// BASICRT values — the interpreter's `BASICValue`, kept by the runtime.
//
// Statically typed code keeps numbers as doubles and strings as RTString
// pointers, but everything that lives *inside* something — a record's
// fields, an array's elements, a dictionary's entries, a VARIANT's payload —
// is an `RTValue`, so the runtime can copy, compare, print, coerce, and
// JSON-encode any shape with one walk, exactly the way the interpreter does.
//
// Value semantics are the interpreter's: assigning a record, array, or
// dictionary copies it. The classes below are containers; `copied()` is the
// deep copy every store makes unless the value is a fresh temporary.

/// The runtime's value.
indirect enum RTValue {
    /// Never set (`EMPTY`); prints as "", reads as 0 or "".
    case empty
    /// `NULL`.
    case null
    case number(Double)
    case string(RTText)
    case boolean(Bool)
    /// A TYPE record or CLASS object.
    case composite(RTComposite)
    case array(RTArray)
    case dictionary(RTDictionary)
    case closure(RTClosure)
    /// A host-implemented object (`File`, …), shared by reference.
    case system(RTSystemObject)

    /// A deep copy, so the result shares nothing with `self`.
    func copied() -> RTValue {
        switch self {
        case .composite(let composite): return .composite(composite.copy())
        case .array(let array): return .array(array.copy())
        case .dictionary(let dictionary): return .dictionary(dictionary.copy())
        default: return self
        }
    }

    /// The interpreter's `description`: what PRINT shows.
    var description: String {
        switch self {
        case .empty: return ""
        case .null: return "NULL"
        case .number(let value): return rtNumberText(value)
        case .string(let value): return value.description
        case .boolean(let value): return value ? "TRUE" : "FALSE"
        case .composite(let composite): return "<\(RTTypes.type(composite.typeIndex).name)>"
        case .closure: return "<FUNCTION>"
        case .system(let object): return "<\(object.typeName)>"
        case .array(let array): return "<ARRAY \(array.element.name)>"
        case .dictionary(let dictionary): return "<DICTIONARY \(dictionary.values.count) entries>"
        }
    }

    /// The interpreter's `truthy`.
    var truthy: Bool {
        switch self {
        case .empty, .null: return false
        case .number(let value): return value != 0
        case .string(let value): return !value.description.isEmpty
        case .boolean(let value): return value
        case .composite, .array, .dictionary, .closure, .system: return true
        }
    }

    /// The interpreter's `number`: what implicitly reads as a number.
    var number: Double? {
        switch self {
        case .empty: return 0
        case .number(let value): return value
        case .boolean(let value): return value ? 1 : 0
        default: return nil
        }
    }

    /// The interpreter's `string`: what implicitly reads as a string.
    var string: RTText? {
        switch self {
        case .empty: return .empty
        case .string(let value): return value
        default: return nil
        }
    }

    /// The interpreter's `==`: same kind and equal, never coerced.
    static func equal(_ lhs: RTValue, _ rhs: RTValue) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty), (.null, .null): return true
        case (.number(let l), .number(let r)): return l == r
        case (.string(let l), .string(let r)): return l == r
        case (.boolean(let l), .boolean(let r)): return l == r
        case (.composite(let l), .composite(let r)): return l.typeIndex == r.typeIndex && l.fields.count == r.fields.count && zip(l.fields, r.fields).allSatisfy { equal($0, $1) }
        case (.array(let l), .array(let r)): return l.upperBounds == r.upperBounds && l.values.count == r.values.count && zip(l.values, r.values).allSatisfy { equal($0, $1) }
        case (.dictionary(let l), .dictionary(let r)):
            return l.values.count == r.values.count && l.values.allSatisfy { key, value in r.values[key].map { equal(value, $0) } ?? false }
        case (.closure(let l), .closure(let r)): return l === r
        case (.system(let l), .system(let r)): return l === r
        default: return false
        }
    }

    /// The type name the debugger and `REFLECT` show.
    var typeName: String {
        switch self {
        case .empty: return "EMPTY"
        case .null: return "NULL"
        case .number: return "DOUBLE"
        case .string: return "STRING"
        case .boolean: return "BOOLEAN"
        case .composite(let composite): return RTTypes.type(composite.typeIndex).name
        case .closure: return "FUNCTION"
        case .system(let object): return object.typeName
        case .array(let array): return "ARRAY OF \(array.element.name)"
        case .dictionary: return "DICTIONARY"
        }
    }
}

/// A VARIANT's storage: a box the compiled code holds by pointer. Boxes are
/// never shared between two slots — a store copies — so mutating one in
/// place (an element or entry assignment through a VARIANT) is safe.
public final class RTBox {
    var value: RTValue
    init(_ value: RTValue) { self.value = value }
}

/// The runtime's DICTIONARY: string keys to values, unordered like the
/// interpreter's; every enumeration sorts the keys.
public final class RTDictionary {
    var values: [String: RTValue] = [:]
    init() {}
    private init(copying other: RTDictionary) {
        values = other.values.mapValues { $0.copied() }
    }
    func copy() -> RTDictionary { RTDictionary(copying: self) }
}

/// A coercion failure: the interpreter distinguishes type errors (ERR 13)
/// from runtime errors (ERR 5).
enum RTFailure: Error {
    case type(String)
    case runtime(String)

    /// Raises the failure through the runtime's error path.
    func raise() -> Never {
        switch self {
        case .type(let message): basic_rt_fail_type(message)
        case .runtime(let message): basic_rt_fail(message)
        }
    }
}

/// A field's or element's declared type, as the runtime needs it.
indirect enum RTTypeRef {
    case number
    /// A number declared INTEGER: stores whole values only, named INTEGER.
    case integer
    case string
    case boolean
    case variant
    case dictionary
    case closure
    case composite(Int)
    /// An array of `element` with the declared bounds; nil is `*` (dynamic).
    case array(RTTypeRef, dims: [Int?])

    /// The name `<ARRAY x>` and `REFLECT` show.
    var name: String {
        switch self {
        case .number: return "DOUBLE"
        case .integer: return "INTEGER"
        case .string: return "STRING"
        case .boolean: return "BOOLEAN"
        case .variant: return "VARIANT"
        case .dictionary: return "DICTIONARY"
        case .closure: return "FUNCTION"
        case .composite(let index): return RTTypes.type(index).name
        case .array(let element, _): return "ARRAY OF \(element.name)"
        }
    }

    /// Decodes the compiler's descriptor: `{"k":"number"}`, `{"k":"composite","i":2}`,
    /// `{"k":"array","elem":{…},"dims":[10,null]}`.
    init(descriptor: [String: Any]) {
        switch descriptor["k"] as? String ?? "number" {
        case "integer": self = .integer
        case "string": self = .string
        case "boolean": self = .boolean
        case "variant": self = .variant
        case "dictionary": self = .dictionary
        case "closure": self = .closure
        case "composite": self = .composite(descriptor["i"] as? Int ?? -1)
        case "array":
            let element = RTTypeRef(descriptor: descriptor["elem"] as? [String: Any] ?? [:])
            let dims = (descriptor["dims"] as? [Any] ?? []).map { $0 as? Int }
            self = .array(element, dims: dims)
        default: self = .number
        }
    }
}

/// One field of a registered TYPE or CLASS.
struct RTFieldInfo {
    /// The normalized (uppercased) name.
    let name: String
    /// The name as written.
    let displayName: String
    let type: RTTypeRef
    /// The `json name`, when the field takes part in JSON.
    let jsonName: String?
    /// The declared default; nil means the type's default.
    let explicitDefault: RTValue?
    /// The field's `meta { … }` entries.
    let metadata: [String: RTValue]
}

/// One registered TYPE or CLASS.
final class RTCompositeType {
    let name: String
    let isClass: Bool
    /// The base class's type index, when there is one.
    let base: Int?
    /// All fields, inherited ones first — the slot order.
    let fields: [RTFieldInfo]

    init(name: String, isClass: Bool, base: Int?, fields: [RTFieldInfo]) {
        self.name = name
        self.isClass = isClass
        self.base = base
        self.fields = fields
    }

    func fieldIndex(named normalized: String) -> Int? {
        fields.firstIndex { $0.name == normalized }
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

    /// The default value of a declared type — the interpreter's `defaultValue`.
    static func defaultValue(_ type: RTTypeRef) -> RTValue {
        switch type {
        case .number, .integer: return .number(0)
        case .string: return .string(.empty)
        case .boolean: return .boolean(false)
        case .variant, .closure: return .empty
        case .dictionary: return .dictionary(RTDictionary())
        case .composite(let index): return .composite(RTComposite(typeIndex: index))
        case .array(let element, let dims): return .array(RTArray(element: element, dims: dims))
        }
    }

    /// A field's default: its declared one, else its type's.
    static func defaultValue(for field: RTFieldInfo) -> RTValue {
        if case .array = field.type { return defaultValue(field.type) }
        return field.explicitDefault?.copied() ?? defaultValue(field.type)
    }

    /// Registers a type from the compiler's JSON descriptor.
    static func register(index: Int, descriptor: String) {
        guard let data = descriptor.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            basic_rt_fail("Bad type descriptor for TYPE #\(index)")
        }
        func literal(_ object: [String: Any]) -> RTValue {
            if let number = object["n"] as? Double { return .number(number) }
            if let text = object["s"] as? String { return .string(RTText(text)) }
            if let flag = object["b"] as? Bool { return .boolean(flag) }
            if object["null"] != nil { return .null }
            return .empty
        }
        let fields = (object["fields"] as? [[String: Any]] ?? []).map { field -> RTFieldInfo in
            let explicitDefault = (field["default"] as? [String: Any]).map(literal)
            let metadata = (field["meta"] as? [String: [String: Any]] ?? [:]).mapValues(literal)
            return RTFieldInfo(
                name: field["name"] as? String ?? "",
                displayName: field["display"] as? String ?? (field["name"] as? String ?? ""),
                type: RTTypeRef(descriptor: field["type"] as? [String: Any] ?? [:]),
                jsonName: field["json"] as? String,
                explicitDefault: explicitDefault,
                metadata: metadata
            )
        }
        while registry.count <= index { registry.append(nil) }
        registry[index] = RTCompositeType(
            name: object["name"] as? String ?? "?",
            isClass: (object["kind"] as? String) == "class",
            base: object["base"] as? Int,
            fields: fields
        )
    }
}

// MARK: - Coercion (the interpreter's `coerce`)

enum RTCoerce {
    /// Coerces `value` for storage as `type` in the variable `name`.
    static func coerce(_ value: RTValue, to type: RTTypeRef, name: String) throws(RTFailure) -> RTValue {
        switch type {
        case .variant:
            return value
        case .string:
            guard let string = value.string else { throw .type("Cannot assign non-string value to \(name)") }
            return .string(string)
        case .number:
            guard let number = value.number else { throw .type("Cannot assign non-numeric value to \(name)") }
            return .number(number)
        case .integer:
            guard let number = value.number else { throw .type("Cannot assign non-numeric value to \(name)") }
            guard number.rounded() == number else { throw .type("Cannot assign non-integer value to \(name)") }
            return .number(number)
        case .boolean:
            if case .boolean = value { return value }
            guard let number = value.number, number == 0 || number == 1 else {
                throw .type("Boolean \(name) must be FALSE, TRUE, 0, or 1")
            }
            return .boolean(number == 1)
        case .closure:
            if case .empty = value { return .empty }
            guard case .closure = value else { throw .type("Type Mismatch") }
            return value
        case .dictionary:
            if case .dictionary = value { return value }
            if case .empty = value { return RTTypes.defaultValue(type) }
            throw .type("Cannot assign non-dictionary value to \(name)")
        case .composite(let index):
            let target = RTTypes.type(index)
            if case .composite(let composite) = value {
                if composite.typeIndex == index || RTTypes.type(composite.typeIndex).name.uppercased() == target.name.uppercased() { return value }
                if target.isClass, isClass(composite.typeIndex, subclassOf: index) { return value }
            }
            if case .dictionary(let dictionary) = value {
                return try decode(target: index, from: dictionary)
            }
            if case .null = value, target.isClass { return .null }
            if case .empty = value { return RTTypes.defaultValue(type) }
            throw .type(target.isClass ? "Cannot assign non-\(target.name) object to \(name)" : "Cannot assign non-\(target.name) value to \(name)")
        case .array(let element, let dims):
            let existing = RTArray(element: element, dims: dims)
            return .array(try coerceArray(value, toMatch: existing, name: name))
        }
    }

    /// Runtime subclass test; the compiler registers `base` on classes.
    static func isClass(_ index: Int, subclassOf base: Int) -> Bool {
        var current = RTTypes.type(index).base
        while let next = current {
            if next == base { return true }
            current = RTTypes.type(next).base
        }
        return false
    }

    /// `decodeRecord` / `decodeObject`: fields with json names, from a dictionary.
    static func decode(target index: Int, from dictionary: RTDictionary) throws(RTFailure) -> RTValue {
        let type = RTTypes.type(index)
        let composite = RTComposite(typeIndex: index)
        for (slot, field) in type.fields.enumerated() {
            guard let json = field.jsonName, let source = dictionary.values[json] else { continue }
            do throws(RTFailure) {
                composite.fields[slot] = try coerce(source, to: field.type, name: field.displayName)
            } catch {
                throw .runtime("Type Mismatch")
            }
        }
        return .composite(composite)
    }

    /// The interpreter's `coerceArray`: a new array shaped like `existing`
    /// (a dynamic one adopts the source's shape) holding coerced elements.
    static func coerceArray(_ value: RTValue, toMatch existing: RTArray, name: String) throws(RTFailure) -> RTArray {
        guard case .array(let source) = value else { throw .runtime("Type Mismatch") }
        do throws(RTFailure) {
            let rank = existing.upperBounds.count
            let shape = try arrayShape(from: source, rank: rank)
            var dimensions: [Int] = []
            if existing.isDynamic {
                for (current, decoded) in zip(existing.upperBounds, shape) {
                    if current >= 0, current != decoded { throw .runtime("Type Mismatch") }
                    dimensions.append(current >= 0 ? current : decoded)
                }
            } else {
                guard shape == existing.upperBounds else { throw .runtime("Type Mismatch") }
                dimensions = existing.upperBounds
            }
            let flattened = try flattenedValues(from: source, rank: rank)
            var values: [RTValue] = []
            values.reserveCapacity(flattened.count)
            for element in flattened {
                values.append(try coerce(element, to: existing.element, name: name))
            }
            return RTArray(upperBounds: dimensions, isDynamic: existing.isDynamic, element: existing.element, values: values)
        } catch {
            throw .runtime("Type Mismatch")
        }
    }

    private static func arrayShape(from array: RTArray, rank: Int) throws(RTFailure) -> [Int] {
        guard rank > 0 else { throw .runtime("Type Mismatch") }
        if array.upperBounds.count == rank, rank > 1 {
            // Already a rank-N array (a DIM'd one), not nested lists.
            return array.upperBounds
        }
        if rank == 1 { return [array.values.count - 1] }
        guard let first = array.values.first else { return Array(repeating: -1, count: rank) }
        guard case .array(let firstArray) = first else { throw .runtime("Type Mismatch") }
        let childShape = try arrayShape(from: firstArray, rank: rank - 1)
        for value in array.values.dropFirst() {
            guard case .array(let childArray) = value, try arrayShape(from: childArray, rank: rank - 1) == childShape else {
                throw .runtime("Type Mismatch")
            }
        }
        return [array.values.count - 1] + childShape
    }

    private static func flattenedValues(from array: RTArray, rank: Int) throws(RTFailure) -> [RTValue] {
        guard rank > 0 else { throw .runtime("Type Mismatch") }
        if rank == 1 || array.upperBounds.count == rank { return array.values }
        var values: [RTValue] = []
        for value in array.values {
            guard case .array(let childArray) = value else { throw .runtime("Type Mismatch") }
            values.append(contentsOf: try flattenedValues(from: childArray, rank: rank - 1))
        }
        return values
    }
}

// MARK: - JSON (the interpreter's `jsonString` / `valueFromJSONString`)

enum RTJSON {
    static func encode(_ value: RTValue, pretty: Bool) throws(RTFailure) -> String {
        let object = try jsonObject(for: value)
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]
        if pretty { options.insert(.prettyPrinted) }
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: options)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw .runtime("JSON encode failed: \(error.localizedDescription)")
        }
    }

    static func decode(_ source: String, permissive: Bool) throws(RTFailure) -> RTValue {
        var options: JSONSerialization.ReadingOptions = []
        if permissive { options.insert(.fragmentsAllowed) }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(source.utf8), options: options)
        } catch {
            throw .runtime("JSON parse failed: \(error.localizedDescription)")
        }
        return try value(fromJSONObject: object)
    }

    private static func jsonObject(for value: RTValue) throws(RTFailure) -> Any {
        switch value {
        case .empty, .null: return NSNull()
        case .number(let number): return number
        case .string(let string): return string.rawString
        case .boolean(let boolean): return boolean
        case .closure, .system: throw .runtime("System objects, tasks, and closures cannot be encoded as JSON")
        case .array(let array): return try jsonArray(for: array)
        case .dictionary(let dictionary):
            var object: [String: Any] = [:]
            for key in dictionary.values.keys.sorted() {
                object[key] = try jsonObject(for: dictionary.values[key] ?? .empty)
            }
            return object
        case .composite(let composite):
            let type = RTTypes.type(composite.typeIndex)
            var object: [String: Any] = [:]
            for (slot, field) in type.fields.enumerated() {
                guard let json = field.jsonName else { continue }
                object[json] = try jsonObject(for: composite.fields[slot])
            }
            return object
        }
    }

    private static func jsonArray(for array: RTArray) throws(RTFailure) -> Any {
        guard array.upperBounds.count > 1 else {
            var values: [Any] = []
            for element in array.values { values.append(try jsonObject(for: element)) }
            return values
        }
        return try slice(of: array, dimension: 0, offset: 0).value
    }

    private static func slice(of array: RTArray, dimension: Int, offset: Int) throws(RTFailure) -> (value: Any, nextOffset: Int) {
        let count = max(0, array.upperBounds[dimension] + 1)
        var values: [Any] = []
        var cursor = offset
        if dimension == array.upperBounds.count - 1 {
            for _ in 0..<count {
                values.append(try jsonObject(for: array.values[cursor]))
                cursor += 1
            }
            return (values, cursor)
        }
        for _ in 0..<count {
            let child = try slice(of: array, dimension: dimension + 1, offset: cursor)
            values.append(child.value)
            cursor = child.nextOffset
        }
        return (values, cursor)
    }

    private static func value(fromJSONObject object: Any) throws(RTFailure) -> RTValue {
        if object is NSNull { return .null }
        if let string = object as? String { return .string(RTText(string)) }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            return .number(number.doubleValue)
        }
        if let array = object as? [Any] {
            var values: [RTValue] = []
            for element in array { values.append(try value(fromJSONObject: element)) }
            return .array(RTArray(upperBounds: [array.count - 1], isDynamic: true, element: .variant, values: values))
        }
        if let dictionary = object as? [String: Any] {
            let result = RTDictionary()
            for key in dictionary.keys.sorted() {
                result.values[key] = try value(fromJSONObject: dictionary[key] as Any)
            }
            return .dictionary(result)
        }
        throw .runtime("Unsupported JSON value")
    }
}

// MARK: - Boxes at the ABI

@inline(__always)
func rtBox(_ pointer: UnsafeMutableRawPointer?) -> RTBox {
    guard let pointer else { basic_rt_fail("Value was never set") }
    return Unmanaged<RTBox>.fromOpaque(pointer).takeUnretainedValue()
}

/// The value in a box, or `.empty` for a null pointer (a fresh VARIANT).
@inline(__always)
func rtValue(_ pointer: UnsafeMutableRawPointer?) -> RTValue {
    guard let pointer else { return .empty }
    return Unmanaged<RTBox>.fromOpaque(pointer).takeUnretainedValue().value
}

@inline(__always)
func rtOwned(_ value: RTValue) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(RTBox(value)).toOpaque()
}

/// The display name passed for messages; nil means an expression context.
@inline(__always)
func rtName(_ name: UnsafePointer<CChar>?) -> String? {
    name.map { String(cString: $0) }
}

@_cdecl("basic_rt_value_release")
public func basic_rt_value_release(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<RTBox>.fromOpaque(pointer).release()
}

/// A deep copy, owned — what a store of a borrowed VARIANT makes.
@_cdecl("basic_rt_value_copy")
public func basic_rt_value_copy(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    rtOwned(rtValue(pointer).copied())
}

/// A store into a VARIANT variable: the interpreter's `assign` first checks
/// whether the variable currently *holds an array* — if so, whatever is
/// assigned is coerced to that array's shape (`coerceArray`), even though
/// the variable is a VARIANT. Returns the box to store, owned.
@_cdecl("basic_rt_value_store")
public func basic_rt_value_store(_ current: UnsafeMutableRawPointer?, _ value: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
    if let current, case .array(let existing) = rtBox(current).value {
        do throws(RTFailure) {
            return rtOwned(.array(try RTCoerce.coerceArray(rtValue(value), toMatch: existing, name: String(cString: name))))
        } catch { error.raise() }
    }
    return rtOwned(rtValue(value).copied())
}

@_cdecl("basic_rt_value_empty")
public func basic_rt_value_empty() -> UnsafeMutableRawPointer { rtOwned(RTValue.empty) }

@_cdecl("basic_rt_value_null")
public func basic_rt_value_null() -> UnsafeMutableRawPointer { rtOwned(RTValue.null) }

@_cdecl("basic_rt_value_from_number")
public func basic_rt_value_from_number(_ value: Double) -> UnsafeMutableRawPointer { rtOwned(.number(value)) }

@_cdecl("basic_rt_value_from_string")
public func basic_rt_value_from_string(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer { rtOwned(.string(rtString(pointer))) }

@_cdecl("basic_rt_value_from_boolean")
public func basic_rt_value_from_boolean(_ value: Bool) -> UnsafeMutableRawPointer { rtOwned(.boolean(value)) }

/// Boxes a copy of a record or object.
@_cdecl("basic_rt_value_from_composite")
public func basic_rt_value_from_composite(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    guard let pointer else { return rtOwned(RTValue.empty) }
    return rtOwned(.composite(rtComposite(pointer).copy()))
}

/// Boxes a copy of an array.
@_cdecl("basic_rt_value_from_array")
public func basic_rt_value_from_array(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    guard let pointer else { return rtOwned(RTValue.empty) }
    return rtOwned(.array(Unmanaged<RTArray>.fromOpaque(pointer).takeUnretainedValue().copy()))
}

/// Boxes a copy of a dictionary.
@_cdecl("basic_rt_value_from_dictionary")
public func basic_rt_value_from_dictionary(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    guard let pointer else { return rtOwned(.dictionary(RTDictionary())) }
    return rtOwned(.dictionary(rtDictionary(pointer).copy()))
}

@_cdecl("basic_rt_value_from_closure")
public func basic_rt_value_from_closure(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    guard let pointer else { return rtOwned(RTValue.empty) }
    return rtOwned(.closure(Unmanaged<RTClosure>.fromOpaque(pointer).takeUnretainedValue()))
}

/// The number a VARIANT reads as. With a variable name the message is the
/// assignment's ("Cannot assign non-numeric value to X", a type error);
/// without, the expression's ("Expected a number").
@_cdecl("basic_rt_value_number")
public func basic_rt_value_number(_ pointer: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> Double {
    if let number = rtValue(pointer).number { return number }
    if let name = rtName(name) { basic_rt_fail_type("Cannot assign non-numeric value to \(name)") }
    basic_rt_fail("Expected a number")
}

/// Owned string.
@_cdecl("basic_rt_value_string")
public func basic_rt_value_string(_ pointer: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer {
    if let string = rtValue(pointer).string { return rtOwned(string) }
    if let name = rtName(name) { basic_rt_fail_type("Cannot assign non-string value to \(name)") }
    basic_rt_fail("Expected a string")
}

@_cdecl("basic_rt_value_boolean")
public func basic_rt_value_boolean(_ pointer: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> Bool {
    let value = rtValue(pointer)
    if case .boolean(let flag) = value { return flag }
    if let number = value.number, number == 0 || number == 1 { return number == 1 }
    basic_rt_fail_type("Boolean \(rtName(name) ?? "value") must be FALSE, TRUE, 0, or 1")
}

/// The record or object a VARIANT holds, coerced to type `typeIndex`
/// (a dictionary decodes; EMPTY is the default instance). Owned copy.
@_cdecl("basic_rt_value_composite")
public func basic_rt_value_composite(_ pointer: UnsafeMutableRawPointer?, _ typeIndex: Int, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    do throws(RTFailure) {
        let coerced = try RTCoerce.coerce(rtValue(pointer), to: .composite(typeIndex), name: rtName(name) ?? "value")
        guard case .composite(let composite) = coerced else { return nil }
        return rtOwned(composite.copy())
    } catch {
        error.raise()
    }
}

/// The dictionary a VARIANT holds; owned copy.
@_cdecl("basic_rt_value_dictionary")
public func basic_rt_value_dictionary(_ pointer: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer {
    do throws(RTFailure) {
        let coerced = try RTCoerce.coerce(rtValue(pointer), to: .dictionary, name: rtName(name) ?? "value")
        guard case .dictionary(let dictionary) = coerced else { basic_rt_fail("Expected a dictionary") }
        return rtOwnedDictionary(dictionary.copy())
    } catch {
        error.raise()
    }
}

@_cdecl("basic_rt_value_closure")
public func basic_rt_value_closure(_ pointer: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    switch rtValue(pointer) {
    case .closure(let closure): return Unmanaged.passRetained(closure).toOpaque()
    case .empty: return nil
    default: basic_rt_fail_type("Type Mismatch")
    }
}

@_cdecl("basic_rt_value_truthy")
public func basic_rt_value_truthy(_ pointer: UnsafeMutableRawPointer?) -> Bool {
    rtValue(pointer).truthy
}

@_cdecl("basic_rt_value_equal")
public func basic_rt_value_equal(_ a: UnsafeMutableRawPointer?, _ b: UnsafeMutableRawPointer?) -> Bool {
    RTValue.equal(rtValue(a), rtValue(b))
}

/// `+` with a VARIANT operand: two strings concatenate, else both must be
/// numbers — the interpreter's `evaluateAddChain`.
@_cdecl("basic_rt_value_add")
public func basic_rt_value_add(_ a: UnsafeMutableRawPointer?, _ b: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    let left = rtValue(a), right = rtValue(b)
    if let l = left.string, let r = right.string { return rtOwned(.string(l.concatenating(r))) }
    guard let l = left.number, let r = right.number else { basic_rt_fail("Expected a number") }
    return rtOwned(.number(l + r))
}

/// `LEN` of a VARIANT: characters of a string, elements of an array.
@_cdecl("basic_rt_value_len")
public func basic_rt_value_len(_ pointer: UnsafeMutableRawPointer?) -> Double {
    let value = rtValue(pointer)
    if case .array(let array) = value { return Double(array.values.count) }
    guard let string = value.string else { basic_rt_fail("LEN requires a string or array") }
    return Double(string.characterCount)
}

/// `v(i, …)` on a VARIANT holding an array or dictionary; owned result.
@_cdecl("basic_rt_value_index")
public func basic_rt_value_index(_ pointer: UnsafeMutableRawPointer?, _ count: Int, _ indexes: UnsafePointer<UnsafeMutableRawPointer?>, _ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
    let keys = (0..<count).map { rtValue(indexes[$0]) }
    let displayName = String(cString: name)
    switch rtValue(pointer) {
    case .array(let array):
        return rtOwned(array.values[array.offset(of: keys, name: displayName)].copied())
    case .dictionary(let dictionary):
        return rtOwned((dictionary.values[rtDictionaryKey(keys, name: displayName)] ?? .empty).copied())
    default:
        basic_rt_fail("\(displayName) is not an array")
    }
}

/// `v(i, …) = x` through a VARIANT, in place.
@_cdecl("basic_rt_value_set_index")
public func basic_rt_value_set_index(_ pointer: UnsafeMutableRawPointer?, _ count: Int, _ indexes: UnsafePointer<UnsafeMutableRawPointer?>, _ value: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>) {
    let keys = (0..<count).map { rtValue(indexes[$0]) }
    let displayName = String(cString: name)
    let stored = rtValue(value).copied()
    switch rtValue(pointer) {
    case .array(let array):
        do throws(RTFailure) {
            array.values[array.offset(of: keys, name: displayName)] = try RTCoerce.coerce(stored, to: array.element, name: displayName)
        } catch { error.raise() }
    case .dictionary(let dictionary):
        dictionary.values[rtDictionaryKey(keys, name: displayName)] = stored
    default:
        basic_rt_fail("\(displayName) is not an array")
    }
}

/// `v.Field` on a VARIANT holding a record or object; owned copy.
@_cdecl("basic_rt_value_field")
public func basic_rt_value_field(_ pointer: UnsafeMutableRawPointer?, _ field: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
    let fieldName = String(cString: field)
    guard case .composite(let composite) = rtValue(pointer) else {
        basic_rt_fail("\(String(cString: name)) has no field \(fieldName)")
    }
    let type = RTTypes.type(composite.typeIndex)
    guard let index = type.fieldIndex(named: fieldName.uppercased()) else {
        basic_rt_fail("\(type.name) has no field \(fieldName)")
    }
    return rtOwned(composite.fields[index].copied())
}

/// The runtime type index of the object a VARIANT holds, or -1.
@_cdecl("basic_rt_value_type_index")
public func basic_rt_value_type_index(_ pointer: UnsafeMutableRawPointer?) -> Int {
    if case .composite(let composite) = rtValue(pointer) { return composite.typeIndex }
    return -1
}

/// The record inside a VARIANT, borrowed — for a method call's receiver.
@_cdecl("basic_rt_value_composite_borrow")
public func basic_rt_value_composite_borrow(_ pointer: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
    guard case .composite(let composite) = rtValue(pointer) else {
        basic_rt_fail("\(String(cString: name)) is not an object")
    }
    return Unmanaged.passUnretained(composite).toOpaque()
}

@_cdecl("basic_rt_print_value")
public func basic_rt_print_value(_ pointer: UnsafeMutableRawPointer?) {
    RTConsole.write(rtValue(pointer).description)
}

/// PRINT's rendering as an owned string.
@_cdecl("basic_rt_value_text")
public func basic_rt_value_text(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    rtOwned(rtValue(pointer).description)
}

@_cdecl("basic_rt_json_encode")
public func basic_rt_json_encode(_ pointer: UnsafeMutableRawPointer?, _ pretty: Bool) -> UnsafeMutableRawPointer {
    do throws(RTFailure) {
        return rtOwned(try RTJSON.encode(rtValue(pointer), pretty: pretty))
    } catch { error.raise() }
}

@_cdecl("basic_rt_json_decode")
public func basic_rt_json_decode(_ source: UnsafeMutableRawPointer?, _ permissive: Bool) -> UnsafeMutableRawPointer {
    do throws(RTFailure) {
        return rtOwned(try RTJSON.decode(rtText(source), permissive: permissive))
    } catch { error.raise() }
}

// MARK: - Dictionaries at the ABI

@inline(__always)
func rtDictionary(_ pointer: UnsafeMutableRawPointer?) -> RTDictionary {
    guard let pointer else { basic_rt_fail("Dictionary was never set") }
    return Unmanaged<RTDictionary>.fromOpaque(pointer).takeUnretainedValue()
}

@inline(__always)
func rtOwnedDictionary(_ dictionary: RTDictionary) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(dictionary).toOpaque()
}

/// The interpreter's `dictionaryKey`: a string verbatim, a number as PRINT shows it.
func rtDictionaryKey(_ indexes: [RTValue], name: String) -> String {
    guard indexes.count == 1 else { basic_rt_fail("\(name) expects 1 key") }
    if let string = indexes[0].string { return string.description }
    if let number = indexes[0].number { return RTValue.number(number).description }
    basic_rt_fail("\(name) dictionary key must be a string or number")
}

@_cdecl("basic_rt_dictionary_new")
public func basic_rt_dictionary_new() -> UnsafeMutableRawPointer { rtOwnedDictionary(RTDictionary()) }

@_cdecl("basic_rt_dictionary_copy")
public func basic_rt_dictionary_copy(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    guard let pointer else { return rtOwnedDictionary(RTDictionary()) }
    return rtOwnedDictionary(rtDictionary(pointer).copy())
}

@_cdecl("basic_rt_dictionary_release")
public func basic_rt_dictionary_release(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<RTDictionary>.fromOpaque(pointer).release()
}

/// `d(key)`: the entry, or EMPTY; owned box.
@_cdecl("basic_rt_dictionary_get")
public func basic_rt_dictionary_get(_ pointer: UnsafeMutableRawPointer?, _ key: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
    let dictionary = rtDictionary(pointer)
    return rtOwned((dictionary.values[rtDictionaryKey([rtValue(key)], name: String(cString: name))] ?? .empty).copied())
}

/// `d(key) = value`: stored uncoerced, as a copy.
@_cdecl("basic_rt_dictionary_set")
public func basic_rt_dictionary_set(_ pointer: UnsafeMutableRawPointer?, _ key: UnsafeMutableRawPointer?, _ value: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>) {
    rtDictionary(pointer).values[rtDictionaryKey([rtValue(key)], name: String(cString: name))] = rtValue(value).copied()
}

@_cdecl("basic_rt_print_dictionary")
public func basic_rt_print_dictionary(_ pointer: UnsafeMutableRawPointer?) {
    RTConsole.write(RTValue.dictionary(rtDictionary(pointer)).description)
}

@_cdecl("basic_rt_dictionary_text")
public func basic_rt_dictionary_text(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    rtOwned(RTValue.dictionary(rtDictionary(pointer)).description)
}
