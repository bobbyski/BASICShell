import Foundation

// BASICRT DATA/READ/RESTORE.
//
// The compiler emits the program's DATA items as constant tables and
// registers them at start; READ walks them with the interpreter's coercion
// rules and messages.

enum RTData {
    /// Item kinds: 0 = number, 1 = string.
    nonisolated(unsafe) static var kinds: UnsafePointer<UInt8>?
    nonisolated(unsafe) static var numbers: UnsafePointer<Double>?
    nonisolated(unsafe) static var strings: UnsafePointer<UnsafePointer<CChar>>?
    nonisolated(unsafe) static var count = 0
    nonisolated(unsafe) static var index = 0

    static func next(for name: UnsafePointer<CChar>) -> Int {
        guard index < count else { basic_rt_fail("Out of DATA") }
        defer { index += 1 }
        return index
    }
}

@_cdecl("basic_rt_data_register")
public func basic_rt_data_register(_ count: Int, _ kinds: UnsafePointer<UInt8>, _ numbers: UnsafePointer<Double>, _ strings: UnsafePointer<UnsafePointer<CChar>>) {
    RTData.count = count
    RTData.kinds = kinds
    RTData.numbers = numbers
    RTData.strings = strings
    RTData.index = 0
}

@_cdecl("basic_rt_restore")
public func basic_rt_restore() {
    RTData.index = 0
}

/// `READ` into a numeric variable named `name`.
@_cdecl("basic_rt_read_number")
public func basic_rt_read_number(_ name: UnsafePointer<CChar>) -> Double {
    let item = RTData.next(for: name)
    guard RTData.kinds![item] == 0 else {
        basic_rt_fail_type("Cannot assign non-numeric value to \(String(cString: name))")
    }
    return RTData.numbers![item]
}

/// `READ` into a string variable named `name`; owned (+1).
@_cdecl("basic_rt_read_string")
public func basic_rt_read_string(_ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
    let item = RTData.next(for: name)
    guard RTData.kinds![item] == 1 else {
        basic_rt_fail_type("Cannot assign non-string value to \(String(cString: name))")
    }
    return rtOwned(String(cString: RTData.strings![item]))
}
