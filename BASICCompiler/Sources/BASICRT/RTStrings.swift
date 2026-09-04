import Foundation

// BASICRT strings.
//
// A compiled program's string is a pointer to an `RTString`, retained and
// released through the runtime. `nil` is a legal string pointer and means
// "" — so a fresh variable costs nothing.
//
// Ownership at the boundary: arguments are borrowed, results are owned (+1).
// The compiler releases every temporary at the end of its statement.
//
// The text is the interpreter's `BASICString`: text-backed until a NUL or
// a raw byte (CHR$, a RAW file read) turns it data-backed, so `CHR$(0)`
// and `CHR$(255)` survive round trips through files and `MKI$`/`CVI`.

/// The interpreter's `BASICString`: text, or raw bytes.
package struct RTText: Equatable {
    package enum Storage: Equatable {
        case text(String)
        case data(Data)
    }

    package let storage: Storage

    /// Text; data-backed when it contains a NUL, as the interpreter does.
    package init(_ value: String) {
        storage = value.utf8.contains(0) ? .data(Data(value.utf8)) : .text(value)
    }

    init(data: Data) {
        storage = .data(data)
    }

    package static let empty = RTText("")

    /// What `PRINT` shows: NUL bytes are dropped from data-backed text.
    package var description: String {
        switch storage {
        case .text(let value): return value
        case .data(let data): return String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
        }
    }

    /// The text as characters (a lossy decode of raw bytes).
    package var rawString: String {
        switch storage {
        case .text(let value): return value
        case .data(let data): return String(decoding: data, as: UTF8.self)
        }
    }

    var characterCount: Int { rawString.count }

    var byteCount: Int {
        switch storage {
        case .text(let value): return value.utf8.count
        case .data(let data): return data.count
        }
    }

    var rawData: Data {
        switch storage {
        case .text(let value): return Data(value.utf8)
        case .data(let data): return data
        }
    }

    var isData: Bool {
        if case .data = storage { return true }
        return false
    }

    func concatenating(_ other: RTText) -> RTText {
        switch (storage, other.storage) {
        case (.text(let left), .text(let right)): return RTText(left + right)
        default: return RTText(data: rawData + other.rawData)
        }
    }

    /// `CHR$`: one byte, data-backed.
    static func character(code: Int) -> RTText {
        guard (0...255).contains(code) else { basic_rt_fail("CHR$ code must be between 0 and 255") }
        return RTText(data: Data([UInt8(code)]))
    }
}

/// The runtime's string object.
package final class RTString {
    package let value: RTText

    /// Wraps text.
    public init(_ text: String) {
        value = RTText(text)
    }

    init(_ value: RTText) {
        self.value = value
    }

    /// The characters.
    public var text: String { value.rawString }
}

/// The text behind a string pointer; nil reads as "".
@inline(__always)
package func rtString(_ pointer: UnsafeMutableRawPointer?) -> RTText {
    guard let pointer else { return .empty }
    return Unmanaged<RTString>.fromOpaque(pointer).takeUnretainedValue().value
}

/// The characters behind a string pointer; nil reads as "".
@inline(__always)
package func rtText(_ pointer: UnsafeMutableRawPointer?) -> String {
    rtString(pointer).rawString
}

/// A new owned (+1) string pointer.
@inline(__always)
package func rtOwned(_ text: String) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(RTString(text)).toOpaque()
}

@inline(__always)
func rtOwned(_ value: RTText) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(RTString(value)).toOpaque()
}

/// Creates a string from UTF-8 bytes in the program's constant data.
@_cdecl("basic_rt_string_literal")
public func basic_rt_string_literal(_ bytes: UnsafePointer<UInt8>, _ length: Int) -> UnsafeMutableRawPointer {
    rtOwned(String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self))
}

@_cdecl("basic_rt_string_retain")
public func basic_rt_string_retain(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    _ = Unmanaged<RTString>.fromOpaque(pointer).retain()
}

@_cdecl("basic_rt_string_release")
public func basic_rt_string_release(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<RTString>.fromOpaque(pointer).release()
}

@_cdecl("basic_rt_string_concat")
public func basic_rt_string_concat(_ a: UnsafeMutableRawPointer?, _ b: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    rtOwned(rtString(a).concatenating(rtString(b)))
}

/// The interpreter's `==` on strings: same storage kind, same contents —
/// so `CHR$(65) = "A"` is false there, and here.
@_cdecl("basic_rt_string_equal")
public func basic_rt_string_equal(_ a: UnsafeMutableRawPointer?, _ b: UnsafeMutableRawPointer?) -> Bool {
    rtString(a) == rtString(b)
}

/// `a < b`, with Swift's string ordering — the interpreter's.
@_cdecl("basic_rt_string_less")
public func basic_rt_string_less(_ a: UnsafeMutableRawPointer?, _ b: UnsafeMutableRawPointer?) -> Bool {
    rtText(a) < rtText(b)
}

/// The interpreter's truthiness for a string: non-empty as displayed.
@_cdecl("basic_rt_string_truthy")
public func basic_rt_string_truthy(_ pointer: UnsafeMutableRawPointer?) -> Bool {
    !rtString(pointer).description.isEmpty
}

@_cdecl("basic_rt_string_length")
public func basic_rt_string_length(_ pointer: UnsafeMutableRawPointer?) -> Double {
    Double(rtString(pointer).characterCount)
}

@_cdecl("basic_rt_string_asc")
public func basic_rt_string_asc(_ pointer: UnsafeMutableRawPointer?) -> Double {
    guard let byte = rtString(pointer).rawData.first else {
        basic_rt_fail("ASC requires a non-empty string")
    }
    return Double(byte)
}

/// `VAL`: the leading number of the text, or 0.
@_cdecl("basic_rt_string_val")
public func basic_rt_string_val(_ pointer: UnsafeMutableRawPointer?) -> Double {
    let trimmed = rtText(pointer).trimmingCharacters(in: .whitespaces)
    var index = trimmed.startIndex
    if index < trimmed.endIndex, trimmed[index] == "+" || trimmed[index] == "-" {
        index = trimmed.index(after: index)
    }
    var hasDigits = false
    while index < trimmed.endIndex, trimmed[index].isNumber {
        hasDigits = true
        index = trimmed.index(after: index)
    }
    if index < trimmed.endIndex, trimmed[index] == "." {
        index = trimmed.index(after: index)
        while index < trimmed.endIndex, trimmed[index].isNumber {
            hasDigits = true
            index = trimmed.index(after: index)
        }
    }
    guard hasDigits else { return 0 }
    return Double(trimmed[..<index]) ?? 0
}

/// `INSTR(start, haystack, needle)`, 1-based, 0 when absent.
@_cdecl("basic_rt_string_instr")
public func basic_rt_string_instr(_ startValue: Double, _ haystackPointer: UnsafeMutableRawPointer?, _ needlePointer: UnsafeMutableRawPointer?) -> Double {
    let start = max(1, Int(startValue.rounded()))
    let haystack = rtText(haystackPointer)
    let needle = rtText(needlePointer)
    guard !needle.isEmpty else { return Double(start) }
    guard start <= haystack.count else { return 0 }
    let startIndex = haystack.index(haystack.startIndex, offsetBy: start - 1)
    guard let range = haystack[startIndex...].range(of: needle) else { return 0 }
    return Double(haystack.distance(from: haystack.startIndex, to: range.lowerBound) + 1)
}

/// The text `PRINT` shows for a number: whole numbers without a decimal
/// point, everything else as Swift renders a Double.
func rtNumberText(_ value: Double) -> String {
    if value.rounded() == value, abs(value) < 9.2e18 {
        return String(Int(value))
    }
    return String(value)
}

/// The text `PRINT` shows for a number, as an owned string — what `${n}`
/// interpolates.
@_cdecl("basic_rt_number_text")
public func basic_rt_number_text(_ value: Double) -> UnsafeMutableRawPointer {
    rtOwned(rtNumberText(value))
}

/// `STR$`: the number's text with a leading space when it is not negative.
@_cdecl("basic_rt_number_str")
public func basic_rt_number_str(_ value: Double) -> UnsafeMutableRawPointer {
    let rendered = rtNumberText(value)
    return rtOwned(value >= 0 ? " " + rendered : rendered)
}

/// `CHR$`: one byte, 0…255.
@_cdecl("basic_rt_chr")
public func basic_rt_chr(_ value: Double) -> UnsafeMutableRawPointer {
    rtOwned(RTText.character(code: Int(value.rounded())))
}

@_cdecl("basic_rt_string_left")
public func basic_rt_string_left(_ pointer: UnsafeMutableRawPointer?, _ count: Double) -> UnsafeMutableRawPointer {
    rtOwned(String(rtText(pointer).prefix(max(0, Int(count.rounded())))))
}

@_cdecl("basic_rt_string_right")
public func basic_rt_string_right(_ pointer: UnsafeMutableRawPointer?, _ count: Double) -> UnsafeMutableRawPointer {
    rtOwned(String(rtText(pointer).suffix(max(0, Int(count.rounded())))))
}

/// `MID$(s, start[, length])`; a negative length means "to the end".
@_cdecl("basic_rt_string_mid")
public func basic_rt_string_mid(_ pointer: UnsafeMutableRawPointer?, _ startValue: Double, _ lengthValue: Double) -> UnsafeMutableRawPointer {
    let text = rtText(pointer)
    let start = max(1, Int(startValue.rounded()))
    guard start <= text.count else { return rtOwned("") }
    let suffix = text[text.index(text.startIndex, offsetBy: start - 1)...]
    if lengthValue < 0 {
        return rtOwned(String(suffix))
    }
    return rtOwned(String(suffix.prefix(max(0, Int(lengthValue.rounded())))))
}

@_cdecl("basic_rt_space")
public func basic_rt_space(_ count: Double) -> UnsafeMutableRawPointer {
    rtOwned(String(repeating: " ", count: max(0, Int(count.rounded()))))
}

/// `STRING$(count, text)`: the first character of `text`, repeated.
@_cdecl("basic_rt_string_repeat")
public func basic_rt_string_repeat(_ count: Double, _ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    guard let first = rtText(pointer).first else {
        basic_rt_fail("STRING$ requires a non-empty string")
    }
    return rtOwned(String(repeating: String(first), count: max(0, Int(count.rounded()))))
}

/// `WRITE #`'s quoting: `"text"` with inner quotes doubled; owned.
@_cdecl("basic_rt_write_quote")
public func basic_rt_write_quote(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    rtOwned("\"" + rtText(pointer).replacingOccurrences(of: "\"", with: "\"\"") + "\"")
}
