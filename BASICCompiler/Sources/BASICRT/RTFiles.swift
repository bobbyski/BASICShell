import Foundation

// BASICRT legacy files — OPEN … FOR INPUT|OUTPUT|APPEND|BINARY|RANDOM AS #n
// [LEN = k], PRINT #, WRITE #, INPUT #, LINE INPUT #, INPUT$(n, #f), FIELD,
// LSET/RSET, PUT, GET, SEEK, RESET, CLOSE, EOF, LOF, LOC, SEEK().
//
// The interpreter keeps each open file's whole content in memory and
// rewrites the file on every write; this does the same, so the observable
// behavior (including what a crash leaves on disk) matches. Text files
// count positions in characters, raw (BINARY/RANDOM) files in bytes.
//
// FIELD variables: the interpreter reads and writes the program's
// variables by name at PUT and GET. A compiled program's variables are
// slots, so the runtime keeps a mirror of every FIELD variable's current
// value — the compiler updates it on each store to such a variable and
// reads it back after GET.

package enum RTFileAccess: String { case read = "READ", write = "WRITE", both = "BOTH" }
package enum RTFileContentType: String { case text = "TEXT", raw = "RAW", json = "JSON" }
enum RTLegacyMode { case input, output, append, binary, random }

final class RTOpenFile {
    let path: String
    let access: RTFileAccess
    let contentType: RTFileContentType
    let legacyMode: RTLegacyMode
    var content: RTText
    var position: Int
    let recordLength: Int?
    /// FIELD layout: widths with the normalized variable names.
    var fields: [(width: Int, name: String)] = []

    init(path: String, access: RTFileAccess, contentType: RTFileContentType, legacyMode: RTLegacyMode, content: RTText, position: Int, recordLength: Int?) {
        self.path = path
        self.access = access
        self.contentType = contentType
        self.legacyMode = legacyMode
        self.content = content
        self.position = position
        self.recordLength = recordLength
    }

    /// The size positions are measured against.
    var extent: Int { contentType == .raw ? content.byteCount : content.characterCount }
}

enum RTFiles {
    nonisolated(unsafe) static var open: [Int: RTOpenFile] = [:]
    /// Current values of FIELD variables, by normalized name.
    nonisolated(unsafe) static var fieldValues: [String: RTText] = [:]

    static func handle(_ number: Double) -> Int {
        let handle = Int(number.rounded())
        guard handle > 0 else { basic_rt_fail("Bad file number") }
        return handle
    }

    static func file(_ number: Double) -> RTOpenFile {
        guard let file = open[handle(number)] else { basic_rt_fail("Bad file number") }
        return file
    }

    static func readable(_ number: Double) -> RTOpenFile {
        let file = file(number)
        guard file.access == .read || file.access == .both else { basic_rt_fail("Bad file mode") }
        return file
    }

    static func writable(_ number: Double) -> RTOpenFile {
        let file = file(number)
        guard file.access == .write || file.access == .both else { basic_rt_fail("Bad file mode") }
        return file
    }

    /// A text-mode file for PRINT #/WRITE #/INPUT #.
    static func textWritable(_ number: Double) -> RTOpenFile {
        let file = writable(number)
        guard file.contentType == .text else { basic_rt_fail("Bad file mode") }
        return file
    }

    /// The interpreter refuses device names before touching the disk.
    static func validated(_ path: String) -> String {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let colon = normalized.firstIndex(of: ":") {
            let device = String(normalized[..<colon])
            func numbered(_ prefix: String) -> Bool {
                guard device.hasPrefix(prefix) else { return false }
                let suffix = device.dropFirst(prefix.count)
                return suffix.isEmpty || suffix.allSatisfy(\.isNumber)
            }
            if device == "KYBD" || device == "SCRN" || numbered("COM") || numbered("LPT") {
                basic_rt_fail("Unsupported file device")
            }
        }
        return path
    }

    static func expanded(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func saveText(_ text: String, to path: String) {
        do {
            try text.write(toFile: expanded(path), atomically: true, encoding: .utf8)
        } catch {
            basic_rt_fail("Could not write \(path)")
        }
    }

    static func saveData(_ data: Data, to path: String) {
        do {
            try data.write(to: URL(fileURLWithPath: expanded(path)), options: .atomic)
        } catch {
            basic_rt_fail("Could not write \(path)")
        }
    }

    static func loadText(_ path: String) -> String {
        guard let text = try? String(contentsOfFile: expanded(path), encoding: .utf8) else { basic_rt_fail("File Not Found") }
        return text
    }

    static func loadData(_ path: String) -> Data {
        guard let data = FileManager.default.contents(atPath: expanded(path)) else { basic_rt_fail("File Not Found") }
        return data
    }

    static func save(_ file: RTOpenFile) {
        if file.contentType == .raw {
            saveData(file.content.rawData, to: file.path)
        } else {
            saveText(file.content.rawString, to: file.path)
        }
    }

    /// The next line, or nil at end of file (text files).
    static func readLine(_ file: RTOpenFile) -> String? {
        let raw = file.content.rawString
        guard file.position < raw.count else { return nil }
        let start = raw.index(raw.startIndex, offsetBy: file.position)
        if let newline = raw[start...].firstIndex(of: "\n") {
            let lineEnd = newline > start && raw[raw.index(before: newline)] == "\r" ? raw.index(before: newline) : newline
            let line = String(raw[start..<lineEnd])
            file.position = raw.distance(from: raw.startIndex, to: raw.index(after: newline))
            return line
        }
        let line = String(raw[start...])
        file.position = raw.count
        return line
    }

    /// Comma-separated fields with `"…"` quoting and `""` escapes.
    static func fields(in line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if inQuotes, index + 1 < characters.count, characters[index + 1] == "\"" {
                    current.append("\"")
                    index += 1
                } else {
                    inQuotes.toggle()
                }
            } else if character == "," && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    /// Fields pending from a line that had more than the INPUT # asked for.
    nonisolated(unsafe) static var pending: [Int: [String]] = [:]

    static func nextField(_ number: Double) -> String {
        let file = readable(number)
        let handle = handle(number)
        while pending[handle, default: []].isEmpty {
            guard let line = readLine(file) else { basic_rt_fail("Input past end") }
            pending[handle, default: []].append(contentsOf: fields(in: line))
        }
        return pending[handle]!.removeFirst()
    }

    /// The FIELD width of a variable in any open file's layout.
    static func fieldWidth(named name: String) -> Int? {
        for file in open.values {
            if let field = file.fields.first(where: { $0.name == name }) { return field.width }
        }
        return nil
    }
}

/// `OPEN path FOR mode AS #n [LEN = k]`; mode 0 input, 1 output, 2 append,
/// 3 binary, 4 random. `recordLength` < 0 means none given.
@_cdecl("basic_rt_file_open")
public func basic_rt_file_open(_ pathPointer: UnsafeMutableRawPointer?, _ mode: Int, _ number: Double, _ recordLength: Double) {
    let handle = RTFiles.handle(number)
    guard RTFiles.open[handle] == nil else { basic_rt_fail("File Already Open") }
    let path = RTFiles.validated(rtText(pathPointer))
    let isRandom = mode == 4
    var resolvedRecordLength: Int? = nil
    if recordLength >= 0 {
        guard isRandom else { basic_rt_fail("LEN is only valid for RANDOM files") }
        resolvedRecordLength = Int(recordLength.rounded())
    } else if isRandom {
        resolvedRecordLength = 128
    }
    if isRandom, (resolvedRecordLength ?? 0) <= 0 { basic_rt_fail("Bad record length") }
    let exists = FileManager.default.fileExists(atPath: RTFiles.expanded(path))
    let file: RTOpenFile
    switch mode {
    case 0:
        guard exists else { basic_rt_fail("File Not Found") }
        file = RTOpenFile(path: path, access: .read, contentType: .text, legacyMode: .input, content: RTText(RTFiles.loadText(path)), position: 0, recordLength: nil)
    case 1:
        file = RTOpenFile(path: path, access: .write, contentType: .text, legacyMode: .output, content: .empty, position: 0, recordLength: nil)
        RTFiles.saveText("", to: path)
    case 2:
        let text = exists ? RTFiles.loadText(path) : ""
        file = RTOpenFile(path: path, access: .write, contentType: .text, legacyMode: .append, content: RTText(text), position: text.count, recordLength: nil)
    default:
        let data = exists ? RTFiles.loadData(path) : Data()
        file = RTOpenFile(path: path, access: .both, contentType: .raw, legacyMode: isRandom ? .random : .binary, content: RTText(data: data), position: 0, recordLength: resolvedRecordLength)
        if !exists { RTFiles.saveData(Data(), to: path) }
    }
    RTFiles.open[handle] = file
    RTFiles.pending[handle] = []
}

/// `CLOSE #n`, or `CLOSE` (number 0) for every file.
@_cdecl("basic_rt_file_close")
public func basic_rt_file_close(_ number: Double) {
    if number == 0 {
        RTFiles.open.removeAll()
        RTFiles.pending.removeAll()
        return
    }
    let handle = RTFiles.handle(number)
    guard RTFiles.open[handle] != nil else { basic_rt_fail("Bad file number") }
    RTFiles.open[handle] = nil
    RTFiles.pending[handle] = nil
}

/// `RESET #n`: back to the start.
@_cdecl("basic_rt_file_reset")
public func basic_rt_file_reset(_ number: Double) {
    RTFiles.file(number).position = 0
    RTFiles.pending[RTFiles.handle(number)] = []
}

/// Appends text produced by a PRINT # (already rendered) and saves.
@_cdecl("basic_rt_file_print")
public func basic_rt_file_print(_ number: Double, _ text: UnsafeMutableRawPointer?) {
    let file = RTFiles.textWritable(number)
    file.content = file.content.concatenating(rtString(text))
    file.position = file.content.characterCount
    RTFiles.save(file)
}

/// `WRITE #`: the fields are joined by the compiler; this appends the line.
@_cdecl("basic_rt_file_write_line")
public func basic_rt_file_write_line(_ number: Double, _ text: UnsafeMutableRawPointer?) {
    let file = RTFiles.textWritable(number)
    file.content = file.content.concatenating(rtString(text)).concatenating(RTText("\n"))
    file.position = file.content.characterCount
    RTFiles.save(file)
}

/// Starts an `INPUT #` statement: fields left over from the previous
/// statement's last line are dropped, as the interpreter drops them.
@_cdecl("basic_rt_file_input_begin")
public func basic_rt_file_input_begin(_ number: Double) {
    RTFiles.pending[RTFiles.handle(number)] = []
}

/// `INPUT #` into a numeric variable.
@_cdecl("basic_rt_file_input_number")
public func basic_rt_file_input_number(_ number: Double, _ name: UnsafePointer<CChar>) -> Double {
    let field = RTFiles.nextField(number)
    guard let value = Double(field.trimmingCharacters(in: .whitespaces)) else {
        basic_rt_fail("Expected numeric input for \(String(cString: name))")
    }
    return value
}

/// `INPUT #` into a boolean: TRUE/FALSE/1/0, else the interpreter's Type Mismatch.
@_cdecl("basic_rt_file_input_boolean")
public func basic_rt_file_input_boolean(_ number: Double) -> Bool {
    rtParseBoolean(RTFiles.nextField(number))
}

/// `INPUT #` into a string variable; owned.
@_cdecl("basic_rt_file_input_string")
public func basic_rt_file_input_string(_ number: Double) -> UnsafeMutableRawPointer {
    rtOwned(RTFiles.nextField(number))
}

/// `LINE INPUT #`; owned.
@_cdecl("basic_rt_file_line_input")
public func basic_rt_file_line_input(_ number: Double) -> UnsafeMutableRawPointer {
    let file = RTFiles.readable(number)
    guard let line = RTFiles.readLine(file) else { basic_rt_fail("Input past end") }
    return rtOwned(line)
}

/// `INPUT$(count, #n)`: the next `count` bytes (raw) or characters (text); owned.
@_cdecl("basic_rt_file_input_chars")
public func basic_rt_file_input_chars(_ countValue: Double, _ number: Double) -> UnsafeMutableRawPointer {
    let count = Int(countValue.rounded())
    guard count >= 0 else { basic_rt_fail("INPUT$ requires a non-negative length") }
    guard count > 0 else { return rtOwned("") }
    let file = RTFiles.readable(number)
    if file.contentType == .raw {
        let data = file.content.rawData
        guard file.position < data.count else { basic_rt_fail("Input past end") }
        let end = min(data.count, file.position + count)
        let value = RTText(data: data.subdata(in: file.position..<end))
        file.position = end
        return rtOwned(value)
    }
    let raw = file.content.rawString
    guard file.position < raw.count else { basic_rt_fail("Input past end") }
    let start = raw.index(raw.startIndex, offsetBy: file.position)
    let end = raw.index(start, offsetBy: count, limitedBy: raw.endIndex) ?? raw.endIndex
    let value = String(raw[start..<end])
    file.position = raw.distance(from: raw.startIndex, to: end)
    return rtOwned(value)
}

@_cdecl("basic_rt_file_eof")
public func basic_rt_file_eof(_ number: Double) -> Bool {
    let file = RTFiles.readable(number)
    return file.position >= file.extent
}

@_cdecl("basic_rt_file_lof")
public func basic_rt_file_lof(_ number: Double) -> Double {
    Double(RTFiles.file(number).content.byteCount)
}

/// `LOC(n)`: records completed for RANDOM files, else the position.
@_cdecl("basic_rt_file_loc")
public func basic_rt_file_loc(_ number: Double) -> Double {
    let file = RTFiles.file(number)
    if file.legacyMode == .random, let recordLength = file.recordLength, recordLength > 0 {
        return Double(file.position / recordLength)
    }
    return Double(file.position)
}

/// `SEEK(n)`: the next record (RANDOM) or position, 1-based.
@_cdecl("basic_rt_file_seek_position")
public func basic_rt_file_seek_position(_ number: Double) -> Double {
    let file = RTFiles.file(number)
    if file.legacyMode == .random, let recordLength = file.recordLength, recordLength > 0 {
        return Double(file.position / recordLength + 1)
    }
    return Double(file.position + 1)
}

/// `SEEK #n, p`: 1-based; records for RANDOM files.
@_cdecl("basic_rt_file_seek")
public func basic_rt_file_seek(_ number: Double, _ positionValue: Double) {
    let file = RTFiles.file(number)
    let requested = Int(positionValue.rounded())
    guard requested > 0 else { basic_rt_fail("Bad file position") }
    if file.legacyMode == .random, let recordLength = file.recordLength {
        file.position = (requested - 1) * recordLength
    } else {
        file.position = requested - 1
    }
}

/// `FIELD #n, …`: starts a new layout for the file.
@_cdecl("basic_rt_file_field_begin")
public func basic_rt_file_field_begin(_ number: Double) {
    let file = RTFiles.file(number)
    guard file.legacyMode == .random, let recordLength = file.recordLength, recordLength > 0 else {
        basic_rt_fail("Bad file mode")
    }
    file.fields = []
}

/// One `w AS var$` of a FIELD: registers it and returns the variable's
/// initial value (`w` spaces), owned. The compiler stores it.
@_cdecl("basic_rt_file_field")
public func basic_rt_file_field(_ number: Double, _ widthValue: Double, _ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
    let file = RTFiles.file(number)
    let width = Int(widthValue.rounded())
    guard width > 0 else { basic_rt_fail("FIELD width must be positive") }
    let variable = String(cString: name)
    guard variable.hasSuffix("$") else { basic_rt_fail("FIELD requires string variables") }
    let total = file.fields.reduce(0) { $0 + $1.width } + width
    guard total <= (file.recordLength ?? 0) else { basic_rt_fail("FIELD overflow") }
    file.fields.append((width, variable))
    let initial = RTText(data: Data(repeating: 32, count: width))
    RTFiles.fieldValues[variable] = initial
    return rtOwned(initial)
}

/// The compiler mirrors every store to a FIELD variable here.
@_cdecl("basic_rt_field_mirror")
public func basic_rt_field_mirror(_ name: UnsafePointer<CChar>, _ value: UnsafeMutableRawPointer?) {
    RTFiles.fieldValues[String(cString: name)] = rtString(value)
}

/// `LSET`/`RSET var$ = value`: the value fitted to the field's width.
@_cdecl("basic_rt_field_set")
public func basic_rt_field_set(_ name: UnsafePointer<CChar>, _ value: UnsafeMutableRawPointer?, _ rightAligned: Bool) -> UnsafeMutableRawPointer {
    let variable = String(cString: name)
    guard let width = RTFiles.fieldWidth(named: variable) else {
        basic_rt_fail("LSET and RSET require a FIELD string variable")
    }
    var bytes = Data(rtString(value).rawData.prefix(width))
    if bytes.count < width {
        let padding = Data(repeating: 32, count: width - bytes.count)
        bytes = rightAligned ? padding + bytes : bytes + padding
    }
    let fitted = RTText(data: bytes)
    RTFiles.fieldValues[variable] = fitted
    return rtOwned(fitted)
}

/// `PUT #n[, record]`: writes the FIELD variables as one record.
@_cdecl("basic_rt_file_put")
public func basic_rt_file_put(_ number: Double, _ recordValue: Double, _ hasRecord: Bool) {
    let file = RTFiles.file(number)
    guard file.legacyMode == .random, let recordLength = file.recordLength, recordLength > 0 else {
        basic_rt_fail("Bad file mode")
    }
    let recordNumber = hasRecord ? Int(recordValue.rounded()) : file.position / recordLength + 1
    guard recordNumber > 0 else { basic_rt_fail("Bad record number") }
    var record = Data()
    for field in file.fields {
        var bytes = Data((RTFiles.fieldValues[field.name] ?? .empty).rawData.prefix(field.width))
        if bytes.count < field.width {
            bytes.append(Data(repeating: 32, count: field.width - bytes.count))
        }
        record.append(bytes)
    }
    if record.count < recordLength {
        record.append(Data(repeating: 0, count: recordLength - record.count))
    }
    let offset = (recordNumber - 1) * recordLength
    var data = file.content.rawData
    if data.count < offset {
        data.append(Data(repeating: 0, count: offset - data.count))
    }
    let replacementEnd = min(data.count, offset + recordLength)
    data.replaceSubrange(offset..<replacementEnd, with: record.prefix(recordLength))
    file.content = RTText(data: data)
    file.position = offset + recordLength
    RTFiles.saveData(data, to: file.path)
}

/// `GET #n[, record]`: reads one record into the FIELD mirror; the
/// compiler then refreshes the variables.
@_cdecl("basic_rt_file_get")
public func basic_rt_file_get(_ number: Double, _ recordValue: Double, _ hasRecord: Bool) {
    let file = RTFiles.file(number)
    guard file.legacyMode == .random, let recordLength = file.recordLength, recordLength > 0 else {
        basic_rt_fail("Bad file mode")
    }
    let recordNumber = hasRecord ? Int(recordValue.rounded()) : file.position / recordLength + 1
    guard recordNumber > 0 else { basic_rt_fail("Bad record number") }
    let offset = (recordNumber - 1) * recordLength
    let data = file.content.rawData
    guard offset + recordLength <= data.count else { basic_rt_fail("Input past end") }
    let bytes = data.subdata(in: offset..<(offset + recordLength))
    var fieldOffset = 0
    for field in file.fields {
        let end = fieldOffset + field.width
        RTFiles.fieldValues[field.name] = RTText(data: bytes.subdata(in: fieldOffset..<end))
        fieldOffset = end
    }
    file.position = offset + recordLength
}

/// After GET: the FIELD variable's value when it belongs to an open file's
/// layout, else `current` retained; owned either way.
@_cdecl("basic_rt_field_value_or")
public func basic_rt_field_value_or(_ name: UnsafePointer<CChar>, _ current: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    let variable = String(cString: name)
    if RTFiles.fieldWidth(named: variable) != nil, let value = RTFiles.fieldValues[variable] {
        return rtOwned(value)
    }
    basic_rt_string_retain(current)
    return current
}

// MARK: - MKx$/CVx

enum RTByteOrder { case little, big }

private func rtByteOrder(_ pointer: UnsafeMutableRawPointer?, name: String) -> RTByteOrder {
    switch rtText(pointer).uppercased() {
    case "NATIVE":
        var marker: UInt16 = 1
        return withUnsafeBytes(of: &marker) { $0[0] == 1 ? .little : .big }
    case "LITTLE": return .little
    case "BIG": return .big
    default: basic_rt_fail("\(name) byte order must be NATIVE, LITTLE, or BIG")
    }
}

private func rtWidth(_ value: Double, name: String) -> Int {
    let width = Int(value.rounded())
    guard width == 16 || width == 32 || width == 64 else { basic_rt_fail("\(name) width must be 16, 32, or 64") }
    return width
}

private func rtBinaryData(_ value: UInt64, byteCount: Int, order: RTByteOrder) -> Data {
    let littleEndianBytes = (0..<byteCount).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    return Data(order == .little ? littleEndianBytes : littleEndianBytes.reversed())
}

private func rtBinaryUInt(_ data: Data, order: RTByteOrder) -> UInt64 {
    let bytes = order == .little ? Array(data) : Array(data.reversed())
    return bytes.enumerated().reduce(into: UInt64(0)) { value, byte in
        value |= UInt64(byte.element) << UInt64(byte.offset * 8)
    }
}

private func rtConversionData(_ pointer: UnsafeMutableRawPointer?, count: Int, name: String) -> Data {
    let value = rtString(pointer)
    guard value.byteCount >= count else { basic_rt_fail("\(name) requires at least \(count) bytes") }
    return Data(value.rawData.prefix(count))
}

/// `MKI$(value[, width[, order]])`.
@_cdecl("basic_rt_mki")
public func basic_rt_mki(_ number: Double, _ widthValue: Double, _ orderPointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    guard number.isFinite, number.rounded() == number, let value = Int64(exactly: number) else { basic_rt_fail("Overflow") }
    let width = rtWidth(widthValue, name: "MKI$")
    switch width {
    case 16 where value < Int64(Int16.min) || value > Int64(Int16.max),
         32 where value < Int64(Int32.min) || value > Int64(Int32.max):
        basic_rt_fail("Overflow")
    default: break
    }
    let order = rtByteOrder(orderPointer, name: "MKI$")
    return rtOwned(RTText(data: rtBinaryData(UInt64(bitPattern: value), byteCount: width / 8, order: order)))
}

@_cdecl("basic_rt_mks")
public func basic_rt_mks(_ number: Double, _ orderPointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    let order = rtByteOrder(orderPointer, name: "MKS$")
    return rtOwned(RTText(data: rtBinaryData(UInt64(Float(number).bitPattern), byteCount: 4, order: order)))
}

@_cdecl("basic_rt_mkd")
public func basic_rt_mkd(_ number: Double, _ orderPointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    let order = rtByteOrder(orderPointer, name: "MKD$")
    return rtOwned(RTText(data: rtBinaryData(number.bitPattern, byteCount: 8, order: order)))
}

/// `CVI(bytes$[, width[, order]])`.
@_cdecl("basic_rt_cvi")
public func basic_rt_cvi(_ pointer: UnsafeMutableRawPointer?, _ widthValue: Double, _ orderPointer: UnsafeMutableRawPointer?) -> Double {
    let width = rtWidth(widthValue, name: "CVI")
    let data = rtConversionData(pointer, count: width / 8, name: "CVI")
    let order = rtByteOrder(orderPointer, name: "CVI")
    let raw = rtBinaryUInt(data, order: order)
    switch width {
    case 16: return Double(Int16(truncatingIfNeeded: raw))
    case 32: return Double(Int32(truncatingIfNeeded: raw))
    default:
        let value = Int64(bitPattern: raw)
        guard let exact = Double(exactly: value) else { basic_rt_fail("CVI 64-bit value cannot be represented exactly") }
        return exact
    }
}

@_cdecl("basic_rt_cvs")
public func basic_rt_cvs(_ pointer: UnsafeMutableRawPointer?, _ orderPointer: UnsafeMutableRawPointer?) -> Double {
    let data = rtConversionData(pointer, count: 4, name: "CVS")
    let order = rtByteOrder(orderPointer, name: "CVS")
    return Double(Float(bitPattern: UInt32(truncatingIfNeeded: rtBinaryUInt(data, order: order))))
}

@_cdecl("basic_rt_cvd")
public func basic_rt_cvd(_ pointer: UnsafeMutableRawPointer?, _ orderPointer: UnsafeMutableRawPointer?) -> Double {
    let data = rtConversionData(pointer, count: 8, name: "CVD")
    let order = rtByteOrder(orderPointer, name: "CVD")
    return Double(bitPattern: rtBinaryUInt(data, order: order))
}
