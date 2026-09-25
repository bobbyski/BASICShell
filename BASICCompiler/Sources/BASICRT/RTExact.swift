import Foundation

// BASICRT's DATE, TIME, DATETIME and DECIMAL (DB19, D0.7).
//
// A deliberate second implementation, like `RTCoerce` beside the interpreter's
// `coerce` and `RTStrings` beside its string functions: this module depends on
// nothing, so the rules are written again here and held to the interpreter by
// the conformance programs rather than by sharing code.
//
// The three calendar kinds are kept as their **canonical padded text** --
// `2026-09-25`, `14:30:00.000000000`, `2026-09-25T14:30:00.000000000` -- for one
// reason: comparison is then lexicographic and exact, which is what the
// interpreter gets by comparing components. Printing trims the fraction, so
// `#14:30:00.5#` and `#14:30:00.500#` compare equal and print the same.

/// Which of the four a value is.
package enum RTExactKind: Int {
    case date = 0
    case time = 1
    case datetime = 2
    case decimal = 3

    package var name: String {
        switch self {
        case .date: return "DATE"
        case .time: return "TIME"
        case .datetime: return "DATETIME"
        case .decimal: return "DECIMAL"
        }
    }
}

enum RTExact {

    // MARK: - Reading

    /// Canonical text for one of the calendar kinds, or nil.
    static func canonical(_ text: String, as kind: RTExactKind) -> String? {
        let body = text.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .date:
            return canonicalDate(body)
        case .time:
            return canonicalTime(body)
        case .datetime:
            let separator: Character = body.contains("T") ? "T" : " "
            let halves = body.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: true)
            guard halves.count == 2,
                  let date = canonicalDate(String(halves[0])),
                  let time = canonicalTime(String(halves[1])) else { return nil }
            return date + "T" + time
        case .decimal:
            return nil
        }
    }

    private static func canonicalDate(_ body: String) -> String? {
        let parts = body.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func canonicalTime(_ body: String) -> String? {
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var second = 0
        var nanosecond = 0
        if parts.count == 3 {
            let secondParts = parts[2].split(separator: ".", omittingEmptySubsequences: false)
            guard secondParts.count <= 2, let value = Int(secondParts[0]),
                  (0...59).contains(value) else { return nil }
            second = value
            if secondParts.count == 2 {
                let digits = secondParts[1].prefix(9)
                guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let fraction = Int(digits) else { return nil }
                var scaled = fraction
                for _ in 0..<(9 - digits.count) { scaled *= 10 }
                nanosecond = scaled
            }
        }
        return String(format: "%02d:%02d:%02d.%09d", hour, minute, second, nanosecond)
    }

    /// A decimal from its text, never through a `Double`.
    static func decimal(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var body = Substring(trimmed)
        if body.first == "+" || body.first == "-" { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, !body.isEmpty,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              parts.contains(where: { !$0.isEmpty }) else { return nil }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The literal a `#…#` holds, deciding its kind from its shape.
    static func literal(_ text: String) -> RTValue? {
        let body = text.trimmingCharacters(in: .whitespaces)
        if body.contains(" ") || body.contains("T") {
            if let canonical = canonical(body, as: .datetime) { return .datetime(canonical) }
        }
        if let canonical = canonical(body, as: .date) { return .date(canonical) }
        if let canonical = canonical(body, as: .time) { return .time(canonical) }
        return nil
    }

    // MARK: - Printing

    /// What PRINT shows: the canonical form with an all-zero fraction dropped
    /// and a partial one trimmed, so it reads the way it was written.
    static func text(_ value: RTValue) -> String? {
        switch value {
        case .date(let canonical): return canonical
        case .time(let canonical): return trimmed(canonical)
        case .datetime(let canonical):
            let halves = canonical.split(separator: "T", maxSplits: 1)
            guard halves.count == 2 else { return canonical }
            return halves[0] + "T" + trimmed(String(halves[1]))
        case .decimal(let decimal):
            var decimal = decimal
            return NSDecimalString(&decimal, Locale(identifier: "en_US_POSIX"))
        default: return nil
        }
    }

    private static func trimmed(_ time: String) -> String {
        guard let dot = time.firstIndex(of: ".") else { return time }
        var fraction = String(time[time.index(after: dot)...])
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return fraction.isEmpty ? String(time[..<dot]) : String(time[..<dot]) + "." + fraction
    }

    // MARK: - Coercion

    /// Coerces a value to one of the four, the interpreter's rules.
    static func coerce(_ value: RTValue, to kind: RTExactKind, name: String) -> RTValue {
        if let answer = converted(value, to: kind) { return answer }
        basic_rt_fail("Cannot assign non-\(kind.name.lowercased()) value to \(name)")
    }

    static func converted(_ value: RTValue, to kind: RTExactKind) -> RTValue? {
        switch kind {
        case .decimal:
            switch value {
            case .decimal: return value
            case .boolean(let flag): return .decimal(flag ? 1 : 0)
            case .string(let text): return decimal(text.description).map { .decimal($0) }
            case .number(let number):
                // A whole number is exact either way; a fractional DOUBLE has
                // already lost what DECIMAL is for, so it is refused.
                guard number.rounded() == number, abs(number) < 1e15 else { return nil }
                return .decimal(Decimal(Int64(number)))
            default: return nil
            }
        case .date:
            switch value {
            case .date: return value
            case .datetime(let canonical): return .date(String(canonical.prefix(10)))
            case .string(let text): return canonical(text.description, as: .date).map { .date($0) }
            default: return nil
            }
        case .time:
            switch value {
            case .time: return value
            case .datetime(let canonical): return .time(String(canonical.dropFirst(11)))
            case .string(let text): return canonical(text.description, as: .time).map { .time($0) }
            default: return nil
            }
        case .datetime:
            switch value {
            case .datetime: return value
            case .date(let canonical): return .datetime(canonical + "T00:00:00.000000000")
            case .string(let text): return canonical(text.description, as: .datetime).map { .datetime($0) }
            default: return nil
            }
        }
    }

    // MARK: - Arithmetic and comparison

    /// Whether either side is one of the four.
    static func involves(_ left: RTValue, _ right: RTValue) -> Bool {
        kind(of: left) != nil || kind(of: right) != nil
    }

    static func kind(of value: RTValue) -> RTExactKind? {
        switch value {
        case .date: return .date
        case .time: return .time
        case .datetime: return .datetime
        case .decimal: return .decimal
        default: return nil
        }
    }

    /// `op` is the interpreter's operation name, uppercased.
    static func binary(_ op: String, _ left: RTValue, _ right: RTValue) -> RTValue {
        if kind(of: left) == .decimal || kind(of: right) == .decimal {
            guard case .decimal(let a)? = converted(left, to: .decimal),
                  case .decimal(let b)? = converted(right, to: .decimal) else {
                basic_rt_fail("A DECIMAL can only be combined with a DECIMAL or a whole number")
            }
            switch op {
            case "+": return .decimal(a + b)
            case "-": return .decimal(a - b)
            case "*": return .decimal(a * b)
            case "/":
                guard b != 0 else { basic_rt_fail("Division by zero") }
                return .decimal(a / b)
            case "=": return .boolean(a == b)
            case "<>": return .boolean(a != b)
            case "<": return .boolean(a < b)
            case "<=": return .boolean(a <= b)
            case ">": return .boolean(a > b)
            case ">=": return .boolean(a >= b)
            default: basic_rt_fail("A DECIMAL is not a condition")
            }
        }
        // The calendar kinds: same kind compares, different kinds do not, and
        // arithmetic needs a unit nobody has named yet.
        guard let leftKind = kind(of: left), let rightKind = kind(of: right), leftKind == rightKind,
              let a = canonicalText(left), let b = canonicalText(right) else {
            basic_rt_fail("A DATE, TIME or DATETIME can only be compared with one of the same kind")
        }
        switch op {
        case "=": return .boolean(a == b)
        case "<>": return .boolean(a != b)
        case "<": return .boolean(a < b)
        case "<=": return .boolean(a <= b)
        case ">": return .boolean(a > b)
        case ">=": return .boolean(a >= b)
        case "+", "-", "*", "/":
            basic_rt_fail("Arithmetic on a DATE, TIME or DATETIME needs a unit; compare them, or convert with CDATE")
        default:
            basic_rt_fail("A DATE, TIME or DATETIME is not a condition")
        }
    }

    /// The padded form, which is what makes a text comparison exact.
    private static func canonicalText(_ value: RTValue) -> String? {
        switch value {
        case .date(let canonical), .time(let canonical), .datetime(let canonical): return canonical
        default: return nil
        }
    }
}

// MARK: - The ABI

/// `#2026-09-25#` and `123.45D`: the literal, boxed.
@_cdecl("basic_rt_exact_literal")
public func basic_rt_exact_literal(_ kindRaw: Int, _ text: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
    let body = String(cString: text)
    guard let kind = RTExactKind(rawValue: kindRaw) else { basic_rt_fail("Unknown exact kind") }
    if kind == .decimal {
        guard let value = RTExact.decimal(body) else { basic_rt_fail("\(body) is not a DECIMAL") }
        return rtOwned(.decimal(value))
    }
    guard let value = RTExact.literal(body) else {
        basic_rt_fail("#\(body)# is not a DATE, TIME or DATETIME")
    }
    return rtOwned(value)
}

/// `DIM D AS DATE` taking a value: coerced, or the interpreter's message.
@_cdecl("basic_rt_exact_coerce")
public func basic_rt_exact_coerce(_ value: UnsafeMutableRawPointer?, _ kindRaw: Int, _ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
    guard let kind = RTExactKind(rawValue: kindRaw) else { basic_rt_fail("Unknown exact kind") }
    return rtOwned(RTExact.coerce(rtValue(value), to: kind, name: String(cString: name)))
}

/// `CDATE`, `CTIME`, `CDATETIME`, `CDEC`.
@_cdecl("basic_rt_exact_convert")
public func basic_rt_exact_convert(_ value: UnsafeMutableRawPointer?, _ kindRaw: Int) -> UnsafeMutableRawPointer {
    guard let kind = RTExactKind(rawValue: kindRaw) else { basic_rt_fail("Unknown exact kind") }
    guard let answer = RTExact.converted(rtValue(value), to: kind) else {
        switch kind {
        case .decimal:
            basic_rt_fail("CDEC wants a whole number or text; a fractional DOUBLE has already lost the exactness DECIMAL is for")
        case .date:
            basic_rt_fail("CDATE wants a date, or text like \"2026-09-25\"")
        case .time:
            basic_rt_fail("CTIME wants a time, or text like \"14:30:00\"")
        case .datetime:
            basic_rt_fail("CDATETIME wants a datetime, or text like \"2026-09-25 14:30:00\"")
        }
    }
    return rtOwned(answer)
}

/// `a + b`, `a < b` and the rest where either side is one of the four.
///
/// The operation crosses as its symbol rather than as a number: there is one
/// place that decides what `<` means for a `DATE`, and this is the call to it.
@_cdecl("basic_rt_exact_binary")
public func basic_rt_exact_binary(_ op: UnsafePointer<CChar>, _ left: UnsafeMutableRawPointer?, _ right: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    rtOwned(RTExact.binary(String(cString: op), rtValue(left), rtValue(right)))
}
