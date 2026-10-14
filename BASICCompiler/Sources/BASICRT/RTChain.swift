import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// BASICRT CHAIN — CHAIN, RUN f$ and LOAD f$, R in a compiled program
// (BBC_ADINS.md A7.5, Bobby's ruling B6).
//
// A compiled program has no program text to swap, so it hands over to the
// chained program's own binary, which basicc builds beside it. What
// survives follows BASICChain's table in the interpreter: the variables
// COMMON names, or all of them with ALL, or none for RUN; a start line or
// label; everything else starts fresh, because it is a fresh process.
//
//   CHAIN "next", 200        capture the globals by name ─► encode ─► exec ./next
//   ./next starts            decode ─► restore the globals it has ─► go to 200
//
// The values travel in a file named by BASIC_CHAIN_FILE, with their types,
// so an array or a record arrives as one. A run hosted in an app has no
// process to replace: its host does the handover (`RTHosted.chain`).
//
// Open files cannot cross a process, so they are closed, where the
// interpreter keeps them open for CHAIN.

package enum RTChain {
    nonisolated(unsafe) static var names: [String] = []
    nonisolated(unsafe) static var capture: RTGlobalsCapture?
    nonisolated(unsafe) static var restore: RTGlobalsRestore?
    /// The line and label the program before said to start at.
    nonisolated(unsafe) static var startLine: Double = -1
    nonisolated(unsafe) static var startLabel = ""
    /// A hosted run's handover, set by its host before the next program
    /// starts: what BASIC_CHAIN_FILE holds natively.
    nonisolated(unsafe) package static var pending: Data?

    /// The environment variable naming the file the values travel in.
    static let fileVariable = "BASIC_CHAIN_FILE"

    /// The binary for `file`, beside this one: its path with `.bas` dropped.
    package static func binaryName(for file: String) -> String {
        file.lowercased().hasSuffix(".bas") ? String(file.dropLast(4)) : file
    }

    /// This program's own directory.
    static var executableDirectory: String {
        let path = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "."
        return (path as NSString).deletingLastPathComponent
    }

    // MARK: The values, with their types

    static func encode(_ value: RTValue) -> Any {
        switch value {
        case .empty: return ["e": 0]
        case .null: return ["z": 0]
        case .number(let number): return ["n": number]
        case .boolean(let flag): return ["b": flag]
        case .string(let text):
            switch text.storage {
            case .text(let string): return ["s": string]
            case .data(let data): return ["x": data.base64EncodedString()]
            }
        case .date(let text): return ["date": text]
        case .time(let text): return ["time": text]
        case .datetime(let text): return ["datetime": text]
        case .array(let array):
            return ["a": array.values.map(encode), "u": array.upperBounds, "dyn": array.isDynamic, "t": encode(array.element)]
        case .dictionary(let dictionary): return ["d": dictionary.values.mapValues(encode)]
        case .composite(let composite):
            let type = RTTypes.type(composite.typeIndex)
            var fields: [String: Any] = [:]
            for (field, value) in zip(type.fields, composite.fields) { fields[field.name] = encode(value) }
            return ["r": type.name, "f": fields]
        default:
            // A closure, a task or a host object belongs to the process.
            return ["e": 0]
        }
    }

    static func encode(_ type: RTTypeRef) -> String {
        switch type {
        case .number: return "number"
        case .integer: return "integer"
        case .string: return "string"
        case .boolean: return "boolean"
        case .variant: return "variant"
        case .dictionary: return "dictionary"
        case .closure: return "closure"
        case .composite(let index): return "c:" + RTTypes.type(index).name
        case .array(let element, _): return "a:" + encode(element)
        default: return "variant"
        }
    }

    static func decodeType(_ text: String) -> RTTypeRef {
        switch text {
        case "number": return .number
        case "integer": return .integer
        case "string": return .string
        case "boolean": return .boolean
        case "dictionary": return .dictionary
        case "closure": return .closure
        default:
            if text.hasPrefix("c:"), let index = typeIndex(named: String(text.dropFirst(2))) { return .composite(index) }
            if text.hasPrefix("a:") { return .array(decodeType(String(text.dropFirst(2))), dims: [nil]) }
            return .variant
        }
    }

    static func typeIndex(named name: String) -> Int? {
        RTTypes.registry.firstIndex { $0?.name.uppercased() == name.uppercased() }
    }

    static func decode(_ json: Any) -> RTValue {
        guard let object = json as? [String: Any] else { return .empty }
        if let number = object["n"] as? Double { return .number(number) }
        if let number = object["n"] as? Int { return .number(Double(number)) }
        if let flag = object["b"] as? Bool { return .boolean(flag) }
        if let text = object["s"] as? String { return .string(RTText(text)) }
        if let base64 = object["x"] as? String, let data = Data(base64Encoded: base64) { return .string(RTText(data: data)) }
        if let text = object["date"] as? String { return .date(text) }
        if let text = object["time"] as? String { return .time(text) }
        if let text = object["datetime"] as? String { return .datetime(text) }
        if object["z"] != nil { return .null }
        if let values = object["a"] as? [Any], let bounds = object["u"] as? [Int] {
            return .array(RTArray(upperBounds: bounds, isDynamic: object["dyn"] as? Bool ?? false,
                                  element: decodeType(object["t"] as? String ?? "variant"), values: values.map(decode)))
        }
        if let entries = object["d"] as? [String: Any] {
            let dictionary = RTDictionary()
            dictionary.values = entries.mapValues(decode)
            return .dictionary(dictionary)
        }
        if let name = object["r"] as? String, let fields = object["f"] as? [String: Any], let index = typeIndex(named: name) {
            let composite = RTComposite(typeIndex: index)
            for (field, value) in fields {
                if let slot = RTTypes.type(index).fieldIndex(named: field) { composite.fields[slot] = decode(value) }
            }
            return .composite(composite)
        }
        return .empty
    }

    // MARK: Handing over

    /// The payload for the next program: the variables `carry` says, and
    /// where to start.
    static func payload(carry: Int, common: Set<String>, startLine: Double, startLabel: String) -> Data {
        var carried: [String: Any] = [:]
        if carry > 0, let capture, let snapshot = capture() {
            let values = rtArray(snapshot).values
            for (name, value) in zip(names, values) where carry == 2 || common.contains(name) {
                carried[name] = encode(value)
            }
            basic_rt_array_release(snapshot)
        }
        let object: [String: Any] = ["carried": carried, "line": startLine, "label": startLabel]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// Takes what the program before handed over: its variables into this
    /// program's globals of the same names, and its start.
    static func receive(_ data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        startLine = object["line"] as? Double ?? Double(object["line"] as? Int ?? -1)
        startLabel = object["label"] as? String ?? ""
        guard let carried = object["carried"] as? [String: Any], !carried.isEmpty,
              let capture, let restore, let snapshot = capture() else { return }
        let array = rtArray(snapshot)
        for (index, name) in names.enumerated() {
            if let value = carried[name] { array.values[index] = decode(value) }
        }
        restore(snapshot)
        basic_rt_array_release(snapshot)
    }
}

/// The program's globals, by name, and how to capture and restore them.
@_cdecl("basic_rt_chain_install")
public func basic_rt_chain_install(_ names: UnsafePointer<UnsafePointer<CChar>>?, _ count: Int, _ capture: UnsafeMutableRawPointer, _ restore: UnsafeMutableRawPointer) {
    RTChain.names = (0..<count).compactMap { index in names.map { String(cString: $0[index]) } }
    RTChain.capture = unsafeBitCast(capture, to: RTGlobalsCapture.self)
    RTChain.restore = unsafeBitCast(restore, to: RTGlobalsRestore.self)
}

/// `CHAIN file$ [, start] [, ALL]`, `RUN file$ [, R]`, `LOAD file$, R`:
/// runs the chained program's binary in this one's place. `carry` is 0 for
/// no variables, 1 for those COMMON names (`common`, comma-separated), 2
/// for all of them.
@_cdecl("basic_rt_chain")
public func basic_rt_chain(_ file: UnsafeMutableRawPointer?, _ startLine: Double, _ startLabel: UnsafeMutableRawPointer?,
                           _ carry: Double, _ common: UnsafeMutableRawPointer?, _ keepsFiles: Double) {
    let requested = rtText(file)
    let names = Set(rtText(common).split(separator: ",").map(String.init))
    let payload = RTChain.payload(carry: Int(carry), common: names, startLine: startLine.rounded(), startLabel: rtText(startLabel))
    // Files cannot cross a process: closed either way, written out first.
    basic_rt_file_close(0)
    if let chain = RTHosted.chain {
        fflush(stdout)
        basic_rt_fail(chain(requested, payload) ?? "CHAIN could not run \(requested)")
    }
    let binary = (RTChain.executableDirectory as NSString).appendingPathComponent(RTChain.binaryName(for: requested))
    guard FileManager.default.isExecutableFile(atPath: binary) else { basic_rt_fail("File not found: \(requested)") }
    let path = (FileManager.default.temporaryDirectory.path as NSString)
        .appendingPathComponent("basic-chain-\(getpid())-\(UUID().uuidString).json")
    guard FileManager.default.createFile(atPath: path, contents: payload) else {
        basic_rt_fail("CHAIN could not hand its variables to \(requested)")
    }
    setenv(RTChain.fileVariable, path, 1)
    fflush(stdout)
    fflush(stderr)
    let arguments = [binary] + CommandLine.arguments.dropFirst()
    var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    execv(binary, &argv)
    let reason = String(cString: strerror(errno))
    unlink(path)
    basic_rt_fail("CHAIN could not run \(requested): \(reason)")
}

/// At the top of a program that takes part in CHAIN: what the program
/// before handed over, if one did.
@_cdecl("basic_rt_chain_receive")
public func basic_rt_chain_receive() {
    if let pending = RTChain.pending {
        RTChain.pending = nil
        RTChain.receive(pending)
        return
    }
    guard let path = ProcessInfo.processInfo.environment[RTChain.fileVariable] else { return }
    // Taken once: a program this one runs starts clean.
    unsetenv(RTChain.fileVariable)
    let data = FileManager.default.contents(atPath: path)
    unlink(path)
    if let data { RTChain.receive(data) }
}

/// The line the program before said to start at, or -1.
@_cdecl("basic_rt_chain_start_line")
public func basic_rt_chain_start_line() -> Double {
    RTChain.startLine
}

/// The label the program before said to start at, uppercased, or "".
@_cdecl("basic_rt_chain_start_label")
public func basic_rt_chain_start_label() -> UnsafeMutableRawPointer {
    rtOwned(RTChain.startLabel)
}

/// Reached when no line or label matched: the start asked for is not in
/// this program, as the interpreter's `prepare(startLine:)` says.
@_cdecl("basic_rt_chain_start_unmatched")
public func basic_rt_chain_start_unmatched() {
    if RTChain.startLine >= 0 {
        let line = Int(RTChain.startLine)
        RTChain.startLine = -1
        "Missing line \(line)".withCString { basic_rt_fail_missing($0) }
    }
    if !RTChain.startLabel.isEmpty {
        let label = RTChain.startLabel
        RTChain.startLabel = ""
        "Missing label \(label)".withCString { basic_rt_fail_missing($0) }
    }
}
