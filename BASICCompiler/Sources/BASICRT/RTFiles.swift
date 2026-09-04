import Foundation

// BASICRT legacy sequential files — OPEN … FOR INPUT|OUTPUT|APPEND AS #n,
// PRINT #, WRITE #, INPUT #, LINE INPUT #, CLOSE, EOF, LOF, LOC.
//
// The interpreter keeps each open file's whole content in memory and
// rewrites the file on every PRINT #/WRITE #; this does the same, so the
// observable behavior (including what a crash leaves on disk) matches.
// BINARY and RANDOM modes arrive with the FIELD/GET/PUT work.

final class RTOpenFile {
    let path: String
    /// 0 read, 1 write.
    let access: Int
    var content: String
    var position: Int

    init(path: String, access: Int, content: String, position: Int) {
        self.path = path
        self.access = access
        self.content = content
        self.position = position
    }
}

enum RTFiles {
    nonisolated(unsafe) static var open: [Int: RTOpenFile] = [:]

    static func handle(_ number: Double) -> Int {
        let handle = Int(number.rounded())
        guard handle > 0 else { basic_rt_fail("Bad file number") }
        return handle
    }

    static func readable(_ number: Double) -> RTOpenFile {
        guard let file = open[handle(number)] else { basic_rt_fail("Bad file number") }
        guard file.access == 0 else { basic_rt_fail("Bad file mode") }
        return file
    }

    static func writable(_ number: Double) -> RTOpenFile {
        guard let file = open[handle(number)] else { basic_rt_fail("Bad file number") }
        guard file.access == 1 else { basic_rt_fail("Bad file mode") }
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

    static func save(_ file: RTOpenFile) {
        do {
            try file.content.write(toFile: file.path, atomically: true, encoding: .utf8)
        } catch {
            basic_rt_fail("Could not write \(file.path)")
        }
    }

    /// The next line, or nil at end of file.
    static func readLine(_ file: RTOpenFile) -> String? {
        let raw = file.content
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
}

/// `OPEN path FOR mode AS #n`; mode 0 input, 1 output, 2 append.
@_cdecl("basic_rt_file_open")
public func basic_rt_file_open(_ pathPointer: UnsafeMutableRawPointer?, _ mode: Int, _ number: Double) {
    let handle = RTFiles.handle(number)
    guard RTFiles.open[handle] == nil else { basic_rt_fail("File Already Open") }
    let path = RTFiles.validated(rtText(pathPointer))
    let exists = FileManager.default.fileExists(atPath: path)
    switch mode {
    case 0:
        guard exists, let text = try? String(contentsOfFile: path, encoding: .utf8) else { basic_rt_fail("File Not Found") }
        RTFiles.open[handle] = RTOpenFile(path: path, access: 0, content: text, position: 0)
    case 1:
        let file = RTOpenFile(path: path, access: 1, content: "", position: 0)
        RTFiles.save(file)
        RTFiles.open[handle] = file
    default:
        let text = exists ? ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "") : ""
        RTFiles.open[handle] = RTOpenFile(path: path, access: 1, content: text, position: text.count)
    }
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

/// Appends text produced by a PRINT # (already rendered) and saves.
@_cdecl("basic_rt_file_print")
public func basic_rt_file_print(_ number: Double, _ text: UnsafeMutableRawPointer?) {
    let file = RTFiles.writable(number)
    file.content += rtText(text)
    file.position = file.content.count
    RTFiles.save(file)
}

/// `WRITE #`: the fields are joined by the compiler; this appends the line.
@_cdecl("basic_rt_file_write_line")
public func basic_rt_file_write_line(_ number: Double, _ text: UnsafeMutableRawPointer?) {
    let file = RTFiles.writable(number)
    file.content += rtText(text) + "\n"
    file.position = file.content.count
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

@_cdecl("basic_rt_file_eof")
public func basic_rt_file_eof(_ number: Double) -> Bool {
    let file = RTFiles.readable(number)
    return file.position >= file.content.count
}

@_cdecl("basic_rt_file_lof")
public func basic_rt_file_lof(_ number: Double) -> Double {
    guard let file = RTFiles.open[RTFiles.handle(number)] else { basic_rt_fail("Bad file number") }
    return Double(file.content.utf8.count)
}

@_cdecl("basic_rt_file_loc")
public func basic_rt_file_loc(_ number: Double) -> Double {
    guard let file = RTFiles.open[RTFiles.handle(number)] else { basic_rt_fail("Bad file number") }
    return Double(file.position)
}
