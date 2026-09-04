import Foundation

// BASICRT arrays.
//
// An array variable holds a pointer to an `RTArray`, created by `DIM` (or
// implicitly, 0...10 per dimension, the first time an undimensioned name is
// indexed — the compiler emits that DIM at program start). Elements are
// RTValues of the declared element type; bounds are checked with the
// interpreter's messages. A dynamic array (`DIM a(*)`) starts empty and
// takes the shape of whatever is assigned to it.

/// The runtime's array object.
public final class RTArray {
    /// Upper bound per dimension; every dimension starts at 0. -1 is an
    /// open (`*`) dimension that has not been given a shape yet.
    var upperBounds: [Int]
    let isDynamic: Bool
    let element: RTTypeRef
    var values: [RTValue]

    /// A default-filled array of the declared shape.
    convenience init(element: RTTypeRef, dims: [Int?]) {
        let bounds = dims.map { $0 ?? -1 }
        let count = bounds.contains(-1) ? 0 : bounds.reduce(1) { $0 * ($1 + 1) }
        self.init(
            upperBounds: bounds, isDynamic: dims.contains { $0 == nil }, element: element,
            values: (0..<count).map { _ in RTTypes.defaultValue(element) }
        )
    }

    init(upperBounds: [Int], isDynamic: Bool, element: RTTypeRef, values: [RTValue]) {
        self.upperBounds = upperBounds
        self.isDynamic = isDynamic
        self.element = element
        self.values = values
    }

    /// A deep copy — value semantics.
    func copy() -> RTArray {
        RTArray(upperBounds: upperBounds, isDynamic: isDynamic, element: element, values: values.map { $0.copied() })
    }

    /// Takes another array's shape and contents, keeping this identity.
    func assign(from other: RTArray) {
        upperBounds = other.upperBounds
        values = other.values.map { $0.copied() }
    }

    /// The interpreter's `arrayOffset`.
    func offset(of indexes: [RTValue], name: String) -> Int {
        guard indexes.count == upperBounds.count else {
            basic_rt_fail("\(name) expects \(upperBounds.count) indexes")
        }
        var multiplier = 1
        var offset = 0
        for (indexValue, upperBound) in zip(indexes.reversed(), upperBounds.reversed()) {
            guard let number = indexValue.number, number.rounded() == number else {
                basic_rt_fail("\(name) array index must be numeric")
            }
            let index = Int(number)
            guard (0...upperBound).contains(index) else {
                basic_rt_fail("\(name) subscript out of range")
            }
            offset += index * multiplier
            multiplier *= upperBound + 1
        }
        return offset
    }
}

@inline(__always)
func rtArray(_ pointer: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>) -> RTArray {
    guard let pointer else {
        basic_rt_fail("\(String(cString: name)) is not dimensioned")
    }
    return Unmanaged<RTArray>.fromOpaque(pointer).takeUnretainedValue()
}

@inline(__always)
func rtArray(_ pointer: UnsafeMutableRawPointer) -> RTArray {
    Unmanaged<RTArray>.fromOpaque(pointer).takeUnretainedValue()
}

/// The element type a DIM names: 0 number, 1 string, 2 boolean, 3 composite
/// of `elementType`, 4 variant, 5 dictionary.
func rtElementType(kind: Int, elementType: Int) -> RTTypeRef {
    switch kind {
    case 1: return .string
    case 2: return .boolean
    case 3: return .composite(elementType)
    case 4: return .variant
    case 5: return .dictionary
    case 6: return .integer
    default: return .number
    }
}

/// `DIM`: a new array with `rank` upper bounds (a negative bound is an open
/// `*` dimension); returns it owned (+1).
@_cdecl("basic_rt_array_dim")
public func basic_rt_array_dim(_ rank: Int, _ bounds: UnsafePointer<Double>, _ kind: Int, _ elementType: Int) -> UnsafeMutableRawPointer {
    var dims: [Int?] = []
    for index in 0..<rank {
        let bound = bounds[index].rounded()
        if bound < 0 {
            guard bound == -1 else { basic_rt_fail("DIM bounds must be non-negative") }
            dims.append(nil)
        } else {
            dims.append(Int(bound))
        }
    }
    return Unmanaged.passRetained(RTArray(element: rtElementType(kind: kind, elementType: elementType), dims: dims)).toOpaque()
}

@_cdecl("basic_rt_array_release")
public func basic_rt_array_release(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<RTArray>.fromOpaque(pointer).release()
}

/// The element offset for `indexes`, bounds-checked.
@_cdecl("basic_rt_array_offset")
public func basic_rt_array_offset(_ pointer: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>, _ count: Int, _ indexes: UnsafePointer<Double>) -> Int {
    let array = rtArray(pointer, name)
    return array.offset(of: (0..<count).map { .number(indexes[$0]) }, name: String(cString: name))
}

/// `LEN(array)`: the element count.
@_cdecl("basic_rt_array_count")
public func basic_rt_array_count(_ pointer: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>) -> Double {
    Double(rtArray(pointer, name).values.count)
}

/// `a = value` for an array variable: the interpreter's `coerceArray`, in
/// place — a static array must match in shape, a dynamic one adopts it.
@_cdecl("basic_rt_array_assign")
public func basic_rt_array_assign(_ pointer: UnsafeMutableRawPointer?, _ value: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>) {
    let array = rtArray(pointer, name)
    do throws(RTFailure) {
        array.assign(from: try RTCoerce.coerceArray(rtValue(value), toMatch: array, name: String(cString: name)))
    } catch { error.raise() }
}

@_cdecl("basic_rt_array_load_number")
public func basic_rt_array_load_number(_ pointer: UnsafeMutableRawPointer, _ offset: Int) -> Double {
    rtArray(pointer).values[offset].number ?? 0
}

@_cdecl("basic_rt_array_store_number")
public func basic_rt_array_store_number(_ pointer: UnsafeMutableRawPointer, _ offset: Int, _ value: Double) {
    rtArray(pointer).values[offset] = .number(value)
}

@_cdecl("basic_rt_array_load_boolean")
public func basic_rt_array_load_boolean(_ pointer: UnsafeMutableRawPointer, _ offset: Int) -> Bool {
    rtArray(pointer).values[offset].truthy
}

@_cdecl("basic_rt_array_store_boolean")
public func basic_rt_array_store_boolean(_ pointer: UnsafeMutableRawPointer, _ offset: Int, _ value: Bool) {
    rtArray(pointer).values[offset] = .boolean(value)
}

/// Returns the element owned (+1); nil for an empty string.
@_cdecl("basic_rt_array_load_string")
public func basic_rt_array_load_string(_ pointer: UnsafeMutableRawPointer, _ offset: Int) -> UnsafeMutableRawPointer? {
    guard let string = rtArray(pointer).values[offset].string, !string.isEmpty else { return nil }
    return rtOwned(string)
}

/// Stores a borrowed string into the element.
@_cdecl("basic_rt_array_store_string")
public func basic_rt_array_store_string(_ pointer: UnsafeMutableRawPointer, _ offset: Int, _ value: UnsafeMutableRawPointer?) {
    rtArray(pointer).values[offset] = .string(rtText(value))
}

/// Borrowed: the element record itself (created on first touch), so
/// `A(1).x = 5` mutates in place.
@_cdecl("basic_rt_array_load_composite")
public func basic_rt_array_load_composite(_ pointer: UnsafeMutableRawPointer, _ offset: Int) -> UnsafeMutableRawPointer {
    let array = rtArray(pointer)
    if case .composite(let composite) = array.values[offset] {
        return Unmanaged.passUnretained(composite).toOpaque()
    }
    guard case .composite(let index) = array.element else { basic_rt_fail("Element is not a record") }
    let composite = RTComposite(typeIndex: index)
    array.values[offset] = .composite(composite)
    return Unmanaged.passUnretained(composite).toOpaque()
}

/// Stores a deep copy of the record into the element.
@_cdecl("basic_rt_array_store_composite")
public func basic_rt_array_store_composite(_ pointer: UnsafeMutableRawPointer, _ offset: Int, _ value: UnsafeMutableRawPointer?) {
    rtArray(pointer).values[offset] = value.map { .composite(rtComposite($0).copy()) } ?? .empty
}

/// A VARIANT element, boxed and owned (a copy).
@_cdecl("basic_rt_array_load_value")
public func basic_rt_array_load_value(_ pointer: UnsafeMutableRawPointer, _ offset: Int) -> UnsafeMutableRawPointer {
    rtOwned(rtArray(pointer).values[offset].copied())
}

/// Stores a boxed value into an element, coerced to the element type.
@_cdecl("basic_rt_array_store_value")
public func basic_rt_array_store_value(_ pointer: UnsafeMutableRawPointer, _ offset: Int, _ value: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>) {
    let array = rtArray(pointer)
    do throws(RTFailure) {
        array.values[offset] = try RTCoerce.coerce(rtValue(value).copied(), to: array.element, name: String(cString: name))
    } catch { error.raise() }
}

/// Borrowed dictionary element (created on first touch).
@_cdecl("basic_rt_array_load_dictionary")
public func basic_rt_array_load_dictionary(_ pointer: UnsafeMutableRawPointer, _ offset: Int) -> UnsafeMutableRawPointer {
    let array = rtArray(pointer)
    if case .dictionary(let dictionary) = array.values[offset] {
        return Unmanaged.passUnretained(dictionary).toOpaque()
    }
    let dictionary = RTDictionary()
    array.values[offset] = .dictionary(dictionary)
    return Unmanaged.passUnretained(dictionary).toOpaque()
}

/// `PRINT` of a whole array: `<ARRAY type>`.
@_cdecl("basic_rt_print_array")
public func basic_rt_print_array(_ pointer: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>) {
    RTConsole.write(RTValue.array(rtArray(pointer, name)).description)
}

@_cdecl("basic_rt_array_text")
public func basic_rt_array_text(_ pointer: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
    rtOwned(RTValue.array(rtArray(pointer, name)).description)
}
