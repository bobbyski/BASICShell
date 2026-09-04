import Darwin
import Foundation

// BASICRT keys and the console surface — INKEY$, OPTION AIBASIC-KEYS/IBM-KEYS,
// LOCATE, SCREENWIDTH/SCREENHEIGHT, and LINE INPUT with LENGTH, MAX,
// DEFAULT, and EXITVAR.
//
// Key names are the interpreter's `BASICKeyNormalizer`, ported: a raw
// terminal escape sequence becomes `[H`, `[!F5`, `[$M` … (AIBASIC keys) or
// the IBM two-byte form. Reading is the Shell's: the terminal in raw mode
// for the read, an ESC followed by whatever arrives within 25 ms.

enum RTKeyEncoding { case aibasic, ibm }

enum RTKeys {
    nonisolated(unsafe) static var encoding: RTKeyEncoding = .aibasic
    nonisolated(unsafe) static var lastExitKey = ""

    // MARK: - The normalizer

    static func normalize(_ rawKey: String, encoding: RTKeyEncoding) -> String {
        guard !rawKey.isEmpty else { return "" }
        if rawKey.hasPrefix("[GP:") { return rawKey }
        if rawKey.count == 1 {
            if rawKey == "\u{7F}" { return "\u{8}" }
            return rawKey
        }
        if let normalized = normalizedEscapeSequence(rawKey, encoding: encoding) { return normalized }
        return extended(code: 255, encoding: encoding)
    }

    private static func normalizedEscapeSequence(_ rawKey: String, encoding: RTKeyEncoding) -> String? {
        guard rawKey.first == "\u{1B}" else { return nil }
        if rawKey == "\u{1B}" { return "\u{1B}" }
        let suffix = String(rawKey.dropFirst())
        let modifiers = modifiers(from: suffix)
        if let modified = modifiedCharacter(from: suffix) { return modified }
        if let code = modifiedNavigationCode(from: suffix) {
            return extended(code: code, shift: modifiers.shift, command: modifiers.command, option: modifiers.option, encoding: encoding)
        }
        if let key = modifiedFunctionKey(from: suffix) {
            return functionKey(key.number, ibmCode: key.ibmCode, shift: modifiers.shift, command: modifiers.command, option: modifiers.option, encoding: encoding)
        }
        switch suffix {
        case "[Z": return shiftTab(encoding: encoding)
        case "[A": return extended(code: 72, encoding: encoding)
        case "[B": return extended(code: 80, encoding: encoding)
        case "[C": return extended(code: 77, encoding: encoding)
        case "[D": return extended(code: 75, encoding: encoding)
        case "[H", "OH", "[1~", "[7~": return extended(code: 71, encoding: encoding)
        case "[F", "OF", "[4~", "[8~": return extended(code: 79, encoding: encoding)
        case "[2~": return extended(code: 82, encoding: encoding)
        case "[3~": return extended(code: 83, encoding: encoding)
        case "[5~": return extended(code: 73, encoding: encoding)
        case "[6~": return extended(code: 81, encoding: encoding)
        case "OP": return functionKey(1, ibmCode: 59, encoding: encoding)
        case "OQ": return functionKey(2, ibmCode: 60, encoding: encoding)
        case "OR": return functionKey(3, ibmCode: 61, encoding: encoding)
        case "OS": return functionKey(4, ibmCode: 62, encoding: encoding)
        case "[15~": return functionKey(5, ibmCode: 63, encoding: encoding)
        case "[17~": return functionKey(6, ibmCode: 64, encoding: encoding)
        case "[18~": return functionKey(7, ibmCode: 65, encoding: encoding)
        case "[19~": return functionKey(8, ibmCode: 66, encoding: encoding)
        case "[20~": return functionKey(9, ibmCode: 67, encoding: encoding)
        case "[21~": return functionKey(10, ibmCode: 68, encoding: encoding)
        case "[23~": return functionKey(11, ibmCode: 133, encoding: encoding)
        case "[24~": return functionKey(12, ibmCode: 134, encoding: encoding)
        default:
            if let number = functionKeyNumber(from: suffix), (13...22).contains(number) {
                return functionKey(number, ibmCode: 255, encoding: encoding)
            }
            return nil
        }
    }

    private static func modifiedCharacter(from suffix: String) -> String? {
        guard suffix.hasPrefix("[") else { return nil }
        let body = suffix.dropFirst()
        guard body.count >= 2 else { return nil }
        var index = body.startIndex
        var sawModifier = false
        while index < body.endIndex {
            let character = body[index]
            guard character == "!" || character == "$" || character == "#" else { break }
            sawModifier = true
            index = body.index(after: index)
        }
        guard sawModifier, index < body.endIndex else { return nil }
        let character = body[index]
        guard character.unicodeScalars.allSatisfy({ (32...126).contains(Int($0.value)) }) else { return nil }
        guard body.index(after: index) == body.endIndex else { return nil }
        return suffix
    }

    private static func modifiedNavigationCode(from suffix: String) -> Int? {
        guard suffix.hasPrefix("[") else { return nil }
        if suffix.hasPrefix("[1;"), let last = suffix.last {
            switch last {
            case "A": return 72
            case "B": return 80
            case "C": return 77
            case "D": return 75
            case "H": return 71
            case "F": return 79
            default: return nil
            }
        }
        guard suffix.hasSuffix("~") else { return nil }
        let body = suffix.dropFirst().dropLast()
        let base = body.split(separator: ";").first ?? ""
        switch base {
        case "2": return 82
        case "3": return 83
        case "5": return 73
        case "6": return 81
        default: return nil
        }
    }

    private static func modifiedFunctionKey(from suffix: String) -> (number: Int, ibmCode: Int)? {
        if suffix.hasPrefix("[1;"), let last = suffix.last {
            switch last {
            case "P": return (1, 59)
            case "Q": return (2, 60)
            case "R": return (3, 61)
            case "S": return (4, 62)
            default: break
            }
        }
        guard suffix.hasPrefix("["), suffix.hasSuffix("~") else { return nil }
        let body = suffix.dropFirst().dropLast()
        guard let base = Int(body.split(separator: ";").first ?? "") else { return nil }
        switch base {
        case 15: return (5, 63)
        case 17: return (6, 64)
        case 18: return (7, 65)
        case 19: return (8, 66)
        case 20: return (9, 67)
        case 21: return (10, 68)
        case 23: return (11, 133)
        case 24: return (12, 134)
        default:
            guard let number = functionKeyNumber(from: suffix), (13...22).contains(number) else { return nil }
            return (number, 255)
        }
    }

    private static func modifiers(from suffix: String) -> (shift: Bool, command: Bool, option: Bool) {
        guard let parameter = modifierParameter(from: suffix) else { return (false, false, false) }
        switch parameter {
        case 2: return (true, false, false)
        case 3: return (false, false, true)
        case 4: return (true, false, true)
        case 5: return (false, false, false)
        case 6: return (true, false, false)
        case 7: return (false, false, true)
        case 8: return (true, false, true)
        case 9: return (false, true, false)
        case 10: return (true, true, false)
        case 11: return (false, true, true)
        case 12: return (true, true, true)
        default: return (false, false, false)
        }
    }

    private static func modifierParameter(from suffix: String) -> Int? {
        guard let semicolon = suffix.lastIndex(of: ";") else { return nil }
        var digits = ""
        var index = suffix.index(after: semicolon)
        while index < suffix.endIndex {
            let character = suffix[index]
            guard character.isNumber else { break }
            digits.append(character)
            index = suffix.index(after: index)
        }
        return Int(digits)
    }

    private static func functionKeyNumber(from suffix: String) -> Int? {
        guard suffix.hasPrefix("["), suffix.hasSuffix("~") else { return nil }
        let body = suffix.dropFirst().dropLast()
        guard let value = Int(body.split(separator: ";").first ?? "") else { return nil }
        switch value {
        case 25: return 13
        case 26: return 14
        case 28: return 15
        case 29: return 16
        case 31: return 17
        case 32: return 18
        case 33: return 19
        case 34: return 20
        case 35: return 21
        case 36: return 22
        default: return nil
        }
    }

    private static func functionKey(_ number: Int, ibmCode: Int, shift: Bool = false, command: Bool = false, option: Bool = false, encoding: RTKeyEncoding) -> String {
        switch encoding {
        case .aibasic:
            var modifiers = ""
            if shift { modifiers += "!" }
            if command { modifiers += "$" }
            if option { modifiers += "#" }
            return "[\(modifiers)F\(number)"
        case .ibm:
            return extended(code: ibmCode, encoding: encoding)
        }
    }

    private static func shiftTab(encoding: RTKeyEncoding) -> String {
        switch encoding {
        case .aibasic: return "[!T"
        case .ibm: return extended(code: 255, encoding: encoding)
        }
    }

    private static func extended(code: Int, shift: Bool = false, command: Bool = false, option: Bool = false, encoding: RTKeyEncoding) -> String {
        let scalar = String(UnicodeScalar(code) ?? UnicodeScalar(255)!)
        switch encoding {
        case .aibasic:
            var modifiers = ""
            if shift { modifiers += "!" }
            if command { modifiers += "$" }
            if option { modifiers += "#" }
            return "[\(modifiers)\(scalar)"
        case .ibm:
            return "\u{0}\(scalar)"
        }
    }

    // MARK: - Reading the terminal

    private static func fdSet(_ fd: Int32, _ set: inout fd_set) {
        let bitsPerField = MemoryLayout<Int32>.size * 8
        let intOffset = Int(fd) / bitsPerField
        let mask = Int32(1 << (Int(fd) % bitsPerField))
        withUnsafeMutablePointer(to: &set.fds_bits) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 32) { $0[intOffset] |= mask }
        }
    }

    static func readByteIfAvailable(fd: Int32, timeoutMicroseconds: Int32) -> UInt8? {
        var readSet = fd_set()
        fdSet(fd, &readSet)
        var timeout = timeval(tv_sec: 0, tv_usec: timeoutMicroseconds)
        guard select(fd + 1, &readSet, nil, nil, &timeout) > 0 else { return nil }
        var byte: UInt8 = 0
        return Darwin.read(fd, &byte, 1) == 1 ? byte : nil
    }

    static func isCompleteEscapeSequence(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        if bytes[1] == UInt8(ascii: "O") { return bytes.count >= 3 }
        if bytes[1] == UInt8(ascii: "["), let last = bytes.last {
            if (65...90).contains(last) || (97...122).contains(last) || last == UInt8(ascii: "~") { return true }
        }
        return bytes.count >= 8
    }

    /// One key from a raw-mode terminal, blocking; nil at end of input.
    static func readRawKey(fd: Int32) -> String? {
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count == 1 { break }
            if count < 0, errno == EINTR { continue }
            return nil
        }
        var bytes = [byte]
        if byte == 27 {
            while let next = readByteIfAvailable(fd: fd, timeoutMicroseconds: 25_000) {
                bytes.append(next)
                if isCompleteEscapeSequence(bytes) { break }
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? String(UnicodeScalar(byte))
    }

    /// Runs `body` with the terminal in raw (no canonical, no echo) mode.
    static func withRawTerminal<T>(blocking: Bool, _ body: (Int32) -> T?) -> T? {
        let fd = STDIN_FILENO
        guard isatty(fd) == 1 else { return nil }
        var original = termios()
        guard tcgetattr(fd, &original) == 0 else { return nil }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        raw.c_cc.16 = blocking ? 1 : 0
        raw.c_cc.17 = 0
        let originalFlags = fcntl(fd, F_GETFL, 0)
        guard tcsetattr(fd, TCSANOW, &raw) == 0 else { return nil }
        if !blocking { _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) }
        defer {
            if !blocking { _ = fcntl(fd, F_SETFL, originalFlags) }
            var restored = original
            _ = tcsetattr(fd, TCSANOW, &restored)
        }
        return body(fd)
    }

    /// `INKEY$`: the next key if one is waiting, else "".
    static func inkey() -> String {
        fflush(stdout)
        let raw: String? = withRawTerminal(blocking: false) { fd -> String? in
            var byte: UInt8 = 0
            guard Darwin.read(fd, &byte, 1) == 1 else { return nil }
            var bytes = [byte]
            if byte == 27 {
                while let next = readByteIfAvailable(fd: fd, timeoutMicroseconds: 25_000) {
                    bytes.append(next)
                    if isCompleteEscapeSequence(bytes) { break }
                }
            }
            if byte == 3 { exit(130) }
            return String(bytes: bytes, encoding: .utf8) ?? String(UnicodeScalar(byte))
        }
        return normalize(raw ?? "", encoding: encoding)
    }

    // MARK: - LINE INPUT with options (the Shell's field editor)

    static func readField(prompt: String, exitOnSpecialKey: Bool, fieldLength: Int?, maxLength: Int?, defaultText: String?) -> (text: String, exitKey: String?) {
        func limited(_ value: String) -> String { maxLength.map { String(value.prefix($0)) } ?? value }
        fflush(stdout)
        guard isatty(STDIN_FILENO) == 1 else {
            RTConsole.write(prompt)
            return (limited(readLine() ?? defaultText ?? ""), nil)
        }
        let result: (String, String?)? = withRawTerminal(blocking: true) { fd -> (String, String?)? in
            var buffer = limited(defaultText ?? "")
            var cursor = buffer.count
            var fieldViewStart = 0
            var fieldDisplayCursor = 0
            var isOverwriteMode = false

            func emit(_ text: String) { RTConsole.write(text) }
            func range(_ offset: Int, _ length: Int) -> Range<String.Index> {
                let start = buffer.index(buffer.startIndex, offsetBy: offset)
                return start..<buffer.index(start, offsetBy: length)
            }
            func ensureFieldViewContains(_ fieldLength: Int) {
                if cursor < fieldViewStart { fieldViewStart = cursor }
                else if cursor > fieldViewStart + fieldLength { fieldViewStart = cursor - fieldLength }
            }
            func visibleField(_ fieldLength: Int) -> String {
                let visible = String(buffer.dropFirst(fieldViewStart).prefix(fieldLength))
                return visible + String(repeating: " ", count: max(0, fieldLength - visible.count))
            }
            func repaint(from oldCursor: Int? = nil, prefix: String = "") {
                if let fieldLength {
                    ensureFieldViewContains(fieldLength)
                    let displayCursor = cursor - fieldViewStart
                    emit(String(repeating: "\u{1B}[D", count: fieldDisplayCursor) + visibleField(fieldLength) + String(repeating: "\u{1B}[D", count: max(0, fieldLength - displayCursor)))
                    fieldDisplayCursor = displayCursor
                    return
                }
                let redrawStart = oldCursor ?? cursor
                let suffix = String(buffer.dropFirst(redrawStart))
                emit(prefix + "\u{1B}[K" + suffix + String(repeating: "\u{1B}[D", count: max(0, buffer.count - cursor)))
            }
            func moveCursor(to newCursor: Int) {
                let clamped = min(max(newCursor, 0), buffer.count)
                guard clamped != cursor else { return }
                if fieldLength != nil { cursor = clamped; repaint(); return }
                let delta = clamped - cursor
                cursor = clamped
                emit(delta > 0 ? String(repeating: "\u{1B}[C", count: delta) : String(repeating: "\u{1B}[D", count: -delta))
            }
            func insert(_ text: String) {
                let textCount = text.count
                let replacedCount = isOverwriteMode && cursor < buffer.count ? min(textCount, buffer.count - cursor) : 0
                if let maxLength, buffer.count - replacedCount + textCount > maxLength { return }
                if isOverwriteMode, cursor < buffer.count {
                    buffer.removeSubrange(range(cursor, min(textCount, buffer.count - cursor)))
                }
                buffer.insert(contentsOf: text, at: buffer.index(buffer.startIndex, offsetBy: cursor))
                let oldCursor = cursor
                cursor += textCount
                repaint(from: oldCursor)
            }

            emit(prompt)
            if let fieldLength {
                let visible = String(buffer.prefix(fieldLength))
                fieldDisplayCursor = min(cursor, fieldLength)
                emit(visible + String(repeating: " ", count: max(0, fieldLength - visible.count)) + String(repeating: "\u{1B}[D", count: max(0, fieldLength - fieldDisplayCursor)))
            } else if !buffer.isEmpty {
                emit(buffer)
            }

            while true {
                guard let raw = readRawKey(fd: fd) else { return nil }
                if raw == "\r" || raw == "\n" {
                    emit("\n")
                    return (buffer, nil)
                }
                if raw == "\u{4}", buffer.isEmpty { emit("\n"); return nil }
                if raw == "\u{3}" { emit("^C\n"); return ("", nil) }
                if raw == "\t" {
                    if exitOnSpecialKey { emit("\n"); return (buffer, raw) }
                    continue
                }
                if raw == "\u{8}" || raw == "\u{7F}" {
                    guard cursor > 0 else { continue }
                    cursor -= 1
                    buffer.removeSubrange(range(cursor, 1))
                    repaint(prefix: "\u{1B}[D")
                    continue
                }
                if raw.first == "\u{1B}" {
                    if exitOnSpecialKey { emit("\n"); return (buffer, normalize(raw, encoding: .aibasic)) }
                    switch normalize(raw, encoding: .aibasic) {
                    case "[K": moveCursor(to: cursor - 1)
                    case "[M": moveCursor(to: cursor + 1)
                    case "[G": moveCursor(to: 0)
                    case "[O": moveCursor(to: buffer.count)
                    case "[S":
                        guard cursor < buffer.count else { continue }
                        buffer.removeSubrange(range(cursor, 1))
                        repaint()
                    case "[R": isOverwriteMode.toggle()
                    default: break
                    }
                    continue
                }
                if raw.count == 1, let scalar = raw.unicodeScalars.first, scalar.value >= 32 {
                    insert(raw)
                    continue
                }
                if raw.count > 1 { insert(raw) }
            }
        }
        guard let result else { return (defaultText ?? "", nil) }
        return (result.0, result.1)
    }
}

/// `FILES` inside a program: the directory listing in columns, the
/// interpreter's `BASICFileListFormatter`.
@_cdecl("basic_rt_files_list")
public func basic_rt_files_list() {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.currentDirectoryPath) else {
        basic_rt_fail("Could not list files")
    }
    let names = entries.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    guard !names.isEmpty else { return }
    let availableColumns = max(1, rtTerminalSize().columns)
    let longestNameWidth = names.map(\.count).max() ?? 0
    let paddedColumnWidth = longestNameWidth + 2
    let columnCount = max(1, (availableColumns + 2) / max(1, paddedColumnWidth))
    let rowCount = Int((Double(names.count) / Double(columnCount)).rounded(.up))
    let text = (0..<rowCount).map { row -> String in
        var cells: [String] = []
        for column in 0..<columnCount {
            let index = column * rowCount + row
            guard index < names.count else { continue }
            cells.append(names[index])
        }
        return cells.enumerated().map { index, name in
            guard index < cells.count - 1 else { return name }
            return name.padding(toLength: paddedColumnWidth, withPad: " ", startingAt: 0)
        }.joined()
    }.joined(separator: "\n")
    RTConsole.write(text + "\n")
    RTConsole.column = 0
}

/// `SYSTEM cmd` / `SYSTEM$(cmd)`: `/bin/sh -lc` in the working directory
/// with COLUMNS/LINES set, stdout and stderr combined; owned.
@_cdecl("basic_rt_system")
public func basic_rt_system(_ command: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-lc", rtText(command)]
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    var environment = ProcessInfo.processInfo.environment
    let size = rtTerminalSize()
    environment["COLUMNS"] = String(size.columns)
    environment["LINES"] = String(size.rows)
    process.environment = environment
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        basic_rt_fail("Could not execute command: \(error.localizedDescription)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return rtOwned(String(decoding: data, as: UTF8.self))
}

/// The `SYSTEM` statement: runs the command and prints what it wrote.
@_cdecl("basic_rt_system_print")
public func basic_rt_system_print(_ command: UnsafeMutableRawPointer?) {
    fflush(stdout)
    let output = basic_rt_system(command)
    defer { basic_rt_string_release(output) }
    let text = rtText(output)
    if !text.isEmpty { RTConsole.write(text) }
}

/// `CURRENTDIR$`: the working directory at start.
@_cdecl("basic_rt_current_dir")
public func basic_rt_current_dir() -> UnsafeMutableRawPointer {
    rtOwned(FileManager.default.currentDirectoryPath)
}

@_cdecl("basic_rt_inkey")
public func basic_rt_inkey() -> UnsafeMutableRawPointer {
    rtOwned(RTKeys.inkey())
}

/// `OPTION AIBASIC-KEYS` (0) / `OPTION IBM-KEYS` (1).
@_cdecl("basic_rt_key_mode")
public func basic_rt_key_mode(_ mode: Int) {
    RTKeys.encoding = mode == 1 ? .ibm : .aibasic
}

/// The Shell's `terminalSize`: 80×25 when the query fails, else at least 1×1.
func rtTerminalSize() -> (columns: Int, rows: Int) {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 else { return (80, 25) }
    return (max(1, Int(size.ws_col)), max(1, Int(size.ws_row)))
}

@_cdecl("basic_rt_screen_width")
public func basic_rt_screen_width() -> Double { Double(rtTerminalSize().columns) }

@_cdecl("basic_rt_screen_height")
public func basic_rt_screen_height() -> Double { Double(rtTerminalSize().rows) }

/// `LOCATE row, column`: the console host's ANSI positioning.
@_cdecl("basic_rt_locate")
public func basic_rt_locate(_ row: Double, _ column: Double) {
    let safeRow = max(1, Int(row.rounded()))
    let safeColumn = max(1, Int(column.rounded()))
    RTConsole.write("\u{1B}[\(safeRow);\(safeColumn)H")
    RTConsole.column = safeColumn - 1
}

/// `LINE INPUT [prompt,] var$ [LENGTH n] [MAX n] [DEFAULT d$] [EXITVAR k$]`:
/// the text; the exit key is left for `basic_rt_line_input_exit_key`.
/// A negative length or max means "not given".
@_cdecl("basic_rt_line_input_field")
public func basic_rt_line_input_field(_ prompt: UnsafeMutableRawPointer?, _ exitOnSpecialKey: Bool, _ fieldLength: Double, _ maxLength: Double, _ defaultText: UnsafeMutableRawPointer?, _ hasDefault: Bool) -> UnsafeMutableRawPointer {
    let length: Int? = fieldLength < 0 ? nil : Int(fieldLength.rounded())
    let maximum: Int? = maxLength < 0 ? nil : Int(maxLength.rounded())
    if let length, length <= 0 { basic_rt_fail("LINE INPUT LENGTH must be greater than zero") }
    if let maximum, maximum < 0 { basic_rt_fail("LINE INPUT MAX must be zero or greater") }
    let result = RTKeys.readField(prompt: rtString(prompt).description, exitOnSpecialKey: exitOnSpecialKey, fieldLength: length, maxLength: maximum, defaultText: hasDefault ? rtText(defaultText) : nil)
    RTKeys.lastExitKey = result.exitKey ?? ""
    RTConsole.column = 0
    let text = maximum.map { String(result.text.prefix($0)) } ?? result.text
    return rtOwned(text)
}

@_cdecl("basic_rt_line_input_exit_key")
public func basic_rt_line_input_exit_key() -> UnsafeMutableRawPointer {
    rtOwned(RTKeys.lastExitKey)
}
