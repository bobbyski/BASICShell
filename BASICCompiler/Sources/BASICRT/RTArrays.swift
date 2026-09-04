import Foundation

// BASICRT arrays.
//
// An array variable holds a pointer to an `RTArray`, created by `DIM` (or
// implicitly, 0...10 per dimension, the first time an undimensioned name is
// indexed — the compiler emits that DIM at program start). Elements are
// numbers or strings; bounds are checked with the interpreter's messages.

/// The runtime's array object.
public final class RTArray {
    /// Upper bound per dimension; every dimension starts at 0.
    let upperBounds: [Int]
    var numbers: [Double]
    var strings: [RTString?]
    let holdsStrings: Bool

    init(upperBounds: [Int], holdsStrings: Bool) {
        self.upperBounds = upperBounds
        self.holdsStrings = holdsStrings
        let count = upperBounds.reduce(1) { $0 * ($1 + 1) }
        numbers = holdsStrings ? [] : Array(repeating: 0, count: count)
        strings = holdsStrings ? Array(repeating: nil, count: count) : []
    }
}

@inline(__always)
func rtArray(_ pointer: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>) -> RTArray {
    guard let pointer else {
        basic_rt_fail("\(String(cString: name)) is not dimensioned")
    }
    return Unmanaged<RTArray>.fromOpaque(pointer).takeUnretainedValue()
}

/// `DIM`: a new array with `rank` upper bounds; returns it owned (+1).
@_cdecl("basic_rt_array_dim")
public func basic_rt_array_dim(_ rank: Int, _ bounds: UnsafePointer<Double>, _ holdsStrings: Bool) -> UnsafeMutableRawPointer {
    var upperBounds: [Int] = []
    for index in 0..<rank {
        let bound = bounds[index].rounded()
        guard bound >= 0 else { basic_rt_fail("DIM bounds must be non-negative") }
        upperBounds.append(Int(bound))
    }
    return Unmanaged.passRetained(RTArray(upperBounds: upperBounds, holdsStrings: holdsStrings)).toOpaque()
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
    guard count == array.upperBounds.count else {
        basic_rt_fail("\(String(cString: name)) expects \(array.upperBounds.count) indexes")
    }
    var multiplier = 1
    var offset = 0
    for position in stride(from: count - 1, through: 0, by: -1) {
        let value = indexes[position]
        guard value.rounded() == value else {
            basic_rt_fail("\(String(cString: name)) array index must be numeric")
        }
        let index = Int(value)
        let upperBound = array.upperBounds[position]
        guard (0...upperBound).contains(index) else {
            basic_rt_fail("\(String(cString: name)) subscript out of range")
        }
        offset += index * multiplier
        multiplier *= upperBound + 1
    }
    return offset
}

@_cdecl("basic_rt_array_load_number")
public func basic_rt_array_load_number(_ pointer: UnsafeMutableRawPointer, _ offset: Int) -> Double {
    Unmanaged<RTArray>.fromOpaque(pointer).takeUnretainedValue().numbers[offset]
}

@_cdecl("basic_rt_array_store_number")
public func basic_rt_array_store_number(_ pointer: UnsafeMutableRawPointer, _ offset: Int, _ value: Double) {
    Unmanaged<RTArray>.fromOpaque(pointer).takeUnretainedValue().numbers[offset] = value
}

/// Returns the element owned (+1); nil for an element never set.
@_cdecl("basic_rt_array_load_string")
public func basic_rt_array_load_string(_ pointer: UnsafeMutableRawPointer, _ offset: Int) -> UnsafeMutableRawPointer? {
    guard let string = Unmanaged<RTArray>.fromOpaque(pointer).takeUnretainedValue().strings[offset] else { return nil }
    return Unmanaged.passRetained(string).toOpaque()
}

/// Stores a borrowed string into the element, retaining it.
@_cdecl("basic_rt_array_store_string")
public func basic_rt_array_store_string(_ pointer: UnsafeMutableRawPointer, _ offset: Int, _ value: UnsafeMutableRawPointer?) {
    let array = Unmanaged<RTArray>.fromOpaque(pointer).takeUnretainedValue()
    array.strings[offset] = value.map { Unmanaged<RTString>.fromOpaque($0).takeUnretainedValue() }
}
