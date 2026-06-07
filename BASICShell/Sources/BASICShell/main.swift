import BASICCore
import Darwin
import Foundation

final class ShellLineEditor: @unchecked Sendable {
    static let shared = ShellLineEditor()

    private var isOverwriteMode = false
    private var fieldLength: Int?
    private var maxLength: Int?
    private var fieldViewStart = 0
    private var fieldDisplayCursor = 0

    func readLine(prompt: String) -> String? {
        readLine(prompt: prompt, exitOnSpecialKey: false)?.text
    }

    func readLine(prompt: String, exitOnSpecialKey: Bool) -> BASICLineInputResult? {
        readLine(prompt: prompt, exitOnSpecialKey: exitOnSpecialKey, options: BASICLineInputOptions())
    }

    func readLine(prompt: String, exitOnSpecialKey: Bool, options: BASICLineInputOptions) -> BASICLineInputResult? {
        let fd = STDIN_FILENO
        guard isatty(fd) == 1 else {
            Swift.print(prompt, terminator: "")
            return Swift.readLine().map { BASICLineInputResult(text: limited($0, maxLength: options.maxLength)) }
        }

        var originalTermios = termios()
        guard tcgetattr(fd, &originalTermios) == 0 else {
            Swift.print(prompt, terminator: "")
            return Swift.readLine().map { BASICLineInputResult(text: limited($0, maxLength: options.maxLength)) }
        }

        var rawTermios = originalTermios
        rawTermios.c_lflag &= ~tcflag_t(ICANON | ECHO)
        rawTermios.c_cc.16 = 1
        rawTermios.c_cc.17 = 0
        guard tcsetattr(fd, TCSANOW, &rawTermios) == 0 else {
            Swift.print(prompt, terminator: "")
            return Swift.readLine().map { BASICLineInputResult(text: limited($0, maxLength: options.maxLength)) }
        }
        defer {
            var restored = originalTermios
            _ = tcsetattr(fd, TCSANOW, &restored)
        }

        fieldLength = options.fieldLength
        maxLength = options.maxLength
        fieldViewStart = 0
        fieldDisplayCursor = 0
        var buffer = limited(options.defaultText ?? "", maxLength: options.maxLength)
        var cursor = buffer.count

        Swift.print(prompt, terminator: "")
        if let fieldLength {
            let visible = String(buffer.prefix(fieldLength))
            fieldDisplayCursor = min(cursor, fieldLength)
            Swift.print(
                visible
                + String(repeating: " ", count: max(0, fieldLength - visible.count))
                + String(repeating: "\u{1B}[D", count: max(0, fieldLength - fieldDisplayCursor)),
                terminator: ""
            )
        } else if !buffer.isEmpty {
            Swift.print(buffer, terminator: "")
        }
        fflush(stdout)

        while true {
            guard let raw = readRawKey(fd: fd) else { return nil }
            if raw == "\r" || raw == "\n" {
                Swift.print()
                return BASICLineInputResult(text: buffer)
            }

            if raw == "\u{4}", buffer.isEmpty {
                Swift.print()
                return nil
            }

            if raw == "\u{3}" {
                Swift.print("^C")
                buffer = ""
                cursor = 0
                return BASICLineInputResult(text: "")
            }

            if raw == "\t" {
                if exitOnSpecialKey {
                    Swift.print()
                    return BASICLineInputResult(text: buffer, exitKey: raw)
                }
                isOverwriteMode.toggle()
                continue
            }

            if raw == "\u{8}" || raw == "\u{7F}" {
                guard cursor > 0 else { continue }
                cursor -= 1
                buffer.removeSubrange(range(in: buffer, offset: cursor, length: 1))
                repaint(buffer: buffer, cursor: cursor, prefix: "\u{1B}[D")
                continue
            }

            if raw.first == Character(BASICRawKey.escape) {
                if exitOnSpecialKey {
                    Swift.print()
                    return BASICLineInputResult(text: buffer, exitKey: BASICKeyNormalizer.normalize(raw))
                }
                handleEscape(raw, buffer: &buffer, cursor: &cursor)
                continue
            }

            if raw.count == 1, let scalar = raw.unicodeScalars.first, scalar.value >= 32 {
                insert(raw, into: &buffer, cursor: &cursor)
            }
        }
    }

    func readBlockingKey() -> String? {
        let fd = STDIN_FILENO
        guard isatty(fd) == 1 else { return nil }

        var originalTermios = termios()
        guard tcgetattr(fd, &originalTermios) == 0 else { return nil }
        var rawTermios = originalTermios
        rawTermios.c_lflag &= ~tcflag_t(ICANON | ECHO)
        rawTermios.c_cc.16 = 1
        rawTermios.c_cc.17 = 0
        guard tcsetattr(fd, TCSANOW, &rawTermios) == 0 else { return nil }
        defer {
            var restored = originalTermios
            _ = tcsetattr(fd, TCSANOW, &restored)
        }

        return readRawKey(fd: fd)
    }

    private func readRawKey(fd: Int32) -> String? {
        var byte: UInt8 = 0
        guard Darwin.read(fd, &byte, 1) == 1 else { return nil }
        var bytes = [byte]
        if byte == 27 {
            while let next = readByteIfAvailable(fd: fd, timeoutMicroseconds: 25_000) {
                bytes.append(next)
                if isCompleteEscapeSequence(bytes) { break }
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? String(UnicodeScalar(byte))
    }

    private func insert(_ text: String, into buffer: inout String, cursor: inout Int) {
        let textCount = text.count
        let replacedCount = isOverwriteMode && cursor < buffer.count ? min(textCount, buffer.count - cursor) : 0
        if let maxLength, buffer.count - replacedCount + textCount > maxLength {
            return
        }
        if isOverwriteMode, cursor < buffer.count {
            buffer.removeSubrange(range(in: buffer, offset: cursor, length: min(textCount, buffer.count - cursor)))
        }
        buffer.insert(contentsOf: text, at: buffer.index(buffer.startIndex, offsetBy: cursor))
        let oldCursor = cursor
        cursor += textCount
        repaint(buffer: buffer, cursor: cursor, from: oldCursor)
    }

    private func handleEscape(_ raw: String, buffer: inout String, cursor: inout Int) {
        let key = BASICKeyNormalizer.normalize(raw)
        switch key {
        case "[K": moveCursor(to: cursor - 1, cursor: &cursor, buffer: buffer)
        case "[M": moveCursor(to: cursor + 1, cursor: &cursor, buffer: buffer)
        case "[G": moveCursor(to: 0, cursor: &cursor, buffer: buffer)
        case "[O": moveCursor(to: buffer.count, cursor: &cursor, buffer: buffer)
        case "[S":
            guard cursor < buffer.count else { return }
            buffer.removeSubrange(range(in: buffer, offset: cursor, length: 1))
            repaint(buffer: buffer, cursor: cursor)
        case "[R":
            isOverwriteMode.toggle()
        default:
            break
        }
    }

    private func moveCursor(to newCursor: Int, cursor: inout Int, buffer: String) {
        let bufferCount = buffer.count
        let clamped = min(max(newCursor, 0), bufferCount)
        guard clamped != cursor else { return }
        if fieldLength != nil {
            cursor = clamped
            repaint(buffer: buffer, cursor: cursor)
            return
        }
        let delta = clamped - cursor
        cursor = clamped
        if delta > 0 {
            Swift.print(String(repeating: "\u{1B}[C", count: delta), terminator: "")
        } else {
            Swift.print(String(repeating: "\u{1B}[D", count: -delta), terminator: "")
        }
        fflush(stdout)
    }

    private func repaint(buffer: String, cursor: Int, from oldCursor: Int? = nil, prefix: String = "") {
        if let fieldLength {
            ensureFieldViewContains(cursor: cursor, fieldLength: fieldLength)
            let visible = visibleField(buffer: buffer, fieldLength: fieldLength)
            let displayCursor = cursor - fieldViewStart
            Swift.print(
                String(repeating: "\u{1B}[D", count: fieldDisplayCursor)
                + visible
                + String(repeating: "\u{1B}[D", count: max(0, fieldLength - displayCursor)),
                terminator: ""
            )
            fieldDisplayCursor = displayCursor
            fflush(stdout)
            return
        }
        let redrawStart = oldCursor ?? cursor
        let suffix = String(buffer.dropFirst(redrawStart))
        let backtrack = max(0, buffer.count - cursor)
        Swift.print(prefix + "\u{1B}[K" + suffix + String(repeating: "\u{1B}[D", count: backtrack), terminator: "")
        fflush(stdout)
    }

    private func limited(_ value: String, maxLength: Int?) -> String {
        maxLength.map { String(value.prefix($0)) } ?? value
    }

    private func ensureFieldViewContains(cursor: Int, fieldLength: Int) {
        if cursor < fieldViewStart {
            fieldViewStart = cursor
        } else if cursor > fieldViewStart + fieldLength {
            fieldViewStart = cursor - fieldLength
        }
    }

    private func visibleField(buffer: String, fieldLength: Int) -> String {
        let visible = String(buffer.dropFirst(fieldViewStart).prefix(fieldLength))
        return visible + String(repeating: " ", count: max(0, fieldLength - visible.count))
    }

    private func range(in string: String, offset: Int, length: Int) -> Range<String.Index> {
        let start = string.index(string.startIndex, offsetBy: offset)
        let end = string.index(start, offsetBy: length)
        return start..<end
    }

    private func readByteIfAvailable(fd: Int32, timeoutMicroseconds: Int32) -> UInt8? {
        var readSet = fd_set()
        fdZero(&readSet)
        fdSet(fd, &readSet)
        var timeout = timeval(tv_sec: 0, tv_usec: timeoutMicroseconds)
        guard select(fd + 1, &readSet, nil, nil, &timeout) > 0 else { return nil }
        var byte: UInt8 = 0
        return Darwin.read(fd, &byte, 1) == 1 ? byte : nil
    }

    private func isCompleteEscapeSequence(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        if bytes[1] == UInt8(ascii: "O") {
            return bytes.count >= 3
        }
        if bytes[1] == UInt8(ascii: "[") {
            guard let last = bytes.last else { return false }
            if (65...90).contains(last) || (97...122).contains(last) || last == UInt8(ascii: "~") {
                return true
            }
        }
        return bytes.count >= 8
    }

    private func fdZero(_ set: inout fd_set) {
        set = fd_set()
    }

    private func fdSet(_ fd: Int32, _ set: inout fd_set) {
        let bitsPerField = MemoryLayout<Int32>.size * 8
        let intOffset = Int(fd) / bitsPerField
        let bitOffset = Int(fd) % bitsPerField
        let mask = Int32(1 << bitOffset)
        switch intOffset {
        case 0: set.fds_bits.0 |= mask
        case 1: set.fds_bits.1 |= mask
        case 2: set.fds_bits.2 |= mask
        case 3: set.fds_bits.3 |= mask
        case 4: set.fds_bits.4 |= mask
        case 5: set.fds_bits.5 |= mask
        case 6: set.fds_bits.6 |= mask
        case 7: set.fds_bits.7 |= mask
        case 8: set.fds_bits.8 |= mask
        case 9: set.fds_bits.9 |= mask
        case 10: set.fds_bits.10 |= mask
        case 11: set.fds_bits.11 |= mask
        case 12: set.fds_bits.12 |= mask
        case 13: set.fds_bits.13 |= mask
        case 14: set.fds_bits.14 |= mask
        case 15: set.fds_bits.15 |= mask
        case 16: set.fds_bits.16 |= mask
        case 17: set.fds_bits.17 |= mask
        case 18: set.fds_bits.18 |= mask
        case 19: set.fds_bits.19 |= mask
        case 20: set.fds_bits.20 |= mask
        case 21: set.fds_bits.21 |= mask
        case 22: set.fds_bits.22 |= mask
        case 23: set.fds_bits.23 |= mask
        case 24: set.fds_bits.24 |= mask
        case 25: set.fds_bits.25 |= mask
        case 26: set.fds_bits.26 |= mask
        case 27: set.fds_bits.27 |= mask
        case 28: set.fds_bits.28 |= mask
        case 29: set.fds_bits.29 |= mask
        case 30: set.fds_bits.30 |= mask
        case 31: set.fds_bits.31 |= mask
        default: break
        }
    }
}

final class ConsoleHost: BASICFileHost, BASICSystemHost, BASICBlockingKeyboardHost, BASICConsoleHost, BASICConfiguredLineInputHost, BASICLoggingHost, BASICListingStyleHost {
    var usesColoredListing: Bool { true }
    var isBASICLoggingEnabled: Bool { false }

    func log(level: String, issuer: String, module: String, text: String) {
        // Shell logging will grow a real viewer later; LOG is currently a no-op here.
    }

    func print(_ text: String, terminator: String) {
        Swift.print(text, terminator: terminator)
    }

    func printLine(_ text: String) {
        Swift.print(text)
    }

    func readLine(prompt: String) -> String? {
        ShellLineEditor.shared.readLine(prompt: prompt)
    }

    func readLine(prompt: String, exitOnSpecialKey: Bool) -> BASICLineInputResult? {
        ShellLineEditor.shared.readLine(prompt: prompt, exitOnSpecialKey: exitOnSpecialKey)
    }

    func readLine(prompt: String, exitOnSpecialKey: Bool, options: BASICLineInputOptions) -> BASICLineInputResult? {
        ShellLineEditor.shared.readLine(prompt: prompt, exitOnSpecialKey: exitOnSpecialKey, options: options)
    }

    func screenColumns() -> Int {
        terminalSize().columns
    }

    func screenRows() -> Int {
        terminalSize().rows
    }

    private func terminalSize() -> (columns: Int, rows: Int) {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 else {
            return (80, 25)
        }
        return (max(1, Int(size.ws_col)), max(1, Int(size.ws_row)))
    }

    func readKey() -> String? {
        let fd = STDIN_FILENO
        guard isatty(fd) == 1 else { return nil }

        var originalTermios = termios()
        guard tcgetattr(fd, &originalTermios) == 0 else { return nil }
        var rawTermios = originalTermios
        rawTermios.c_lflag &= ~tcflag_t(ICANON | ECHO)
        rawTermios.c_cc.16 = 0
        rawTermios.c_cc.17 = 0

        let originalFlags = fcntl(fd, F_GETFL, 0)
        guard originalFlags >= 0 else { return nil }

        guard tcsetattr(fd, TCSANOW, &rawTermios) == 0 else { return nil }
        _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
        defer {
            _ = fcntl(fd, F_SETFL, originalFlags)
            var restored = originalTermios
            _ = tcsetattr(fd, TCSANOW, &restored)
        }

        var byte: UInt8 = 0
        let count = Darwin.read(fd, &byte, 1)
        guard count == 1 else { return nil }
        var bytes = [byte]
        if byte == 27 {
            while let next = readByteIfAvailable(fd: fd, timeoutMicroseconds: 25_000) {
                bytes.append(next)
                if isCompleteEscapeSequence(bytes) { break }
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? String(UnicodeScalar(byte))
    }

    func readBlockingKey() -> String? {
        ShellLineEditor.shared.readBlockingKey()
    }

    private func readByteIfAvailable(fd: Int32, timeoutMicroseconds: Int32) -> UInt8? {
        var readSet = fd_set()
        fdZero(&readSet)
        fdSet(fd, &readSet)
        var timeout = timeval(tv_sec: 0, tv_usec: timeoutMicroseconds)
        guard select(fd + 1, &readSet, nil, nil, &timeout) > 0 else { return nil }
        var byte: UInt8 = 0
        return Darwin.read(fd, &byte, 1) == 1 ? byte : nil
    }

    private func isCompleteEscapeSequence(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        if bytes[1] == UInt8(ascii: "O") {
            return bytes.count >= 3
        }
        if bytes[1] == UInt8(ascii: "[") {
            guard let last = bytes.last else { return false }
            if (65...90).contains(last) || (97...122).contains(last) || last == UInt8(ascii: "~") {
                return true
            }
        }
        return bytes.count >= 8
    }

    private func fdZero(_ set: inout fd_set) {
        set = fd_set()
    }

    private func fdSet(_ fd: Int32, _ set: inout fd_set) {
        let bitsPerField = MemoryLayout<Int32>.size * 8
        let intOffset = Int(fd) / bitsPerField
        let bitOffset = Int(fd) % bitsPerField
        let mask = Int32(1 << bitOffset)
        switch intOffset {
        case 0: set.fds_bits.0 |= mask
        case 1: set.fds_bits.1 |= mask
        case 2: set.fds_bits.2 |= mask
        case 3: set.fds_bits.3 |= mask
        case 4: set.fds_bits.4 |= mask
        case 5: set.fds_bits.5 |= mask
        case 6: set.fds_bits.6 |= mask
        case 7: set.fds_bits.7 |= mask
        case 8: set.fds_bits.8 |= mask
        case 9: set.fds_bits.9 |= mask
        case 10: set.fds_bits.10 |= mask
        case 11: set.fds_bits.11 |= mask
        case 12: set.fds_bits.12 |= mask
        case 13: set.fds_bits.13 |= mask
        case 14: set.fds_bits.14 |= mask
        case 15: set.fds_bits.15 |= mask
        case 16: set.fds_bits.16 |= mask
        case 17: set.fds_bits.17 |= mask
        case 18: set.fds_bits.18 |= mask
        case 19: set.fds_bits.19 |= mask
        case 20: set.fds_bits.20 |= mask
        case 21: set.fds_bits.21 |= mask
        case 22: set.fds_bits.22 |= mask
        case 23: set.fds_bits.23 |= mask
        case 24: set.fds_bits.24 |= mask
        case 25: set.fds_bits.25 |= mask
        case 26: set.fds_bits.26 |= mask
        case 27: set.fds_bits.27 |= mask
        case 28: set.fds_bits.28 |= mask
        case 29: set.fds_bits.29 |= mask
        case 30: set.fds_bits.30 |= mask
        case 31: set.fds_bits.31 |= mask
        default: break
        }
    }

    func loadTextFile(path: String) throws -> String {
        do {
            return try String(contentsOfFile: expandedPath(path), encoding: .utf8)
        } catch {
            guard let url = bundledDemoURL(path: path) else { throw error }
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    func saveTextFile(path: String, text: String) throws {
        try ensureParentDirectory(for: path)
        try text.write(toFile: expandedPath(path), atomically: true, encoding: .utf8)
    }

    func fileExists(path: String) throws -> Bool {
        FileManager.default.fileExists(atPath: expandedPath(path))
    }

    func currentDirectoryPath() throws -> String {
        FileManager.default.currentDirectoryPath
    }

    func changeDirectory(path: String) throws {
        let resolvedPath = expandedPath(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.changeCurrentDirectoryPath(resolvedPath) else {
            throw BASICError.runtime("Could not change directory to \(path)")
        }
    }

    func listFiles() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: FileManager.default.currentDirectoryPath)
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func listFiles(path: String) throws -> [String] {
        let root = URL(fileURLWithPath: expandedPath(path), isDirectory: true).standardizedFileURL
        if let diskFiles = try recursiveFiles(at: root) {
            return diskFiles
        }

        guard let bundledRoot = bundledDemoURL(path: path),
              let bundledFiles = try recursiveFiles(at: bundledRoot.standardizedFileURL) else {
            return []
        }
        return bundledFiles
    }

    private func recursiveFiles(at root: URL) throws -> [String]? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return try enumerator
            .compactMap { $0 as? URL }
            .filter { url in
                try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            }
            .map { url in
                String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func bundledDemoURL(path: String) -> URL? {
        let normalized = normalizedDemoPath(path)
        let url = Bundle.module.resourceURL?
            .appendingPathComponent("Demos")
            .appendingPathComponent(normalized)
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func normalizedDemoPath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        if normalized.hasPrefix("basicPrograms/demos/") {
            normalized.removeFirst("basicPrograms/demos/".count)
        }
        return normalized
    }

    private func expandedPath(_ path: String) -> String {
        if path == "~" || path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst())
        }
        return path
    }

    private func ensureParentDirectory(for path: String) throws {
        let url = URL(fileURLWithPath: expandedPath(path))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
}

let host = ConsoleHost()
let session = BASICSession(host: host, promptTemplate: BASICSession.shellPromptTemplate)

func demoFileName(for name: String) -> String {
    name.hasSuffix(".bas") ? name : "\(name).bas"
}

@MainActor
func runTermKitEditor() {
    let temporaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIBasic-EDIT-\(UUID().uuidString).bas")

    do {
        try session.program.listing().write(to: temporaryURL, atomically: true, encoding: .utf8)
    } catch {
        host.printLine("Unable to prepare editor buffer: \(error.localizedDescription)")
        return
    }

    defer {
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    let editorCandidates = SelfPackage.editorCandidateURLs(invokedExecutablePath: CommandLine.arguments[0])

    let command: String
    if let editorURL = editorCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
        command = "\(shellQuoted(editorURL.path)) \(shellQuoted(temporaryURL.path))"
    } else if FileManager.default.fileExists(atPath: SelfPackage.rootURL.appendingPathComponent("Package.swift").path) {
        command = "cd \(shellQuoted(SelfPackage.rootURL.path)) && swift run BASICEdit \(shellQuoted(temporaryURL.path))"
    } else {
        host.printLine("Unable to find BASICEdit helper.")
        host.printLine("Searched:")
        for url in editorCandidates {
            host.printLine("  \(url.path)")
        }
        return
    }

    let result = runShellCommand(command)
    guard result == 0 else {
        host.printLine("Editor exited with status \(result).")
        return
    }

    do {
        session.program.loadSource(try String(contentsOf: temporaryURL, encoding: .utf8))
    } catch let error as BASICError {
        host.printLine(error.description)
    } catch {
        host.printLine("Unable to load edited program: \(error.localizedDescription)")
    }
}

func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func runShellCommand(_ command: String) -> Int32 {
    var pid = pid_t()
    var arguments: [UnsafeMutablePointer<CChar>?] = [
        strdup("sh"),
        strdup("-lc"),
        strdup(command),
        nil
    ]
    defer {
        for argument in arguments where argument != nil {
            free(argument)
        }
    }

    let spawnStatus = posix_spawnp(&pid, "sh", nil, nil, &arguments, environ)
    guard spawnStatus == 0 else { return spawnStatus }

    var waitStatus: Int32 = 0
    guard waitpid(pid, &waitStatus, 0) >= 0 else { return errno }
    if waitStatus & 0x7f == 0 {
        return (waitStatus >> 8) & 0xff
    }
    return 128 + (waitStatus & 0x7f)
}

enum SelfPackage {
    static var rootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func editorCandidateURLs(invokedExecutablePath: String) -> [URL] {
        let invokedDirectory = URL(fileURLWithPath: invokedExecutablePath).deletingLastPathComponent()
        return [
            invokedDirectory.appendingPathComponent("BASICEdit"),
            rootURL.appendingPathComponent(".build/debug/BASICEdit"),
            rootURL.appendingPathComponent(".build/arm64-apple-macosx/debug/BASICEdit"),
            rootURL.appendingPathComponent(".build/x86_64-apple-macosx/debug/BASICEdit")
        ]
    }
}

enum BundledDemos {
    static func names() -> [String] {
        guard let root = Bundle.module.resourceURL?.appendingPathComponent("Demos"),
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "bas" }
            .compactMap { url -> String? in
                guard let relative = pathRelativeToDemos(url) else { return nil }
                return String(relative.dropLast(4))
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func source(named name: String) -> String? {
        let normalized = name.hasSuffix(".bas") ? String(name.dropLast(4)) : name
        for candidate in [
            normalized,
            "shell/\(normalized)",
            "studio/\(normalized)"
        ] {
            guard let url = Bundle.module.url(forResource: URL(fileURLWithPath: candidate).lastPathComponent, withExtension: "bas", subdirectory: demoSubdirectory(for: candidate)),
                  let source = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            return source
        }
        return nil
    }

    private static func demoSubdirectory(for candidate: String) -> String {
        let url = URL(fileURLWithPath: candidate)
        let directory = url.deletingLastPathComponent().relativePath
        if directory == "." || directory.isEmpty { return "Demos" }
        return "Demos/\(directory)"
    }

    private static func pathRelativeToDemos(_ url: URL) -> String? {
        guard let root = Bundle.module.resourceURL?.appendingPathComponent("Demos").standardizedFileURL.path else {
            return nil
        }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }
}

func isRunCommand(_ input: String) -> Bool {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let uppercased = trimmed.uppercased()
    return uppercased == "RUN" || uppercased.hasPrefix("RUN ")
}

@MainActor
func printDiagnosticsIfNeeded() -> Bool {
    let diagnostics = session.diagnostics()
    guard !diagnostics.isEmpty else { return false }

    host.printLine("Diagnostics:")
    let indexedLines = session.program.orderedLines.enumerated().map { index, line in
        (
            sourceLineNumber: line.sourceLineNumber ?? index + 1,
            displayLineNumber: line.number ?? line.sourceLineNumber ?? index + 1,
            source: line.number.map { "\($0) \(line.source)" } ?? line.source
        )
    }

    for diagnostic in diagnostics {
        let source = diagnostic.fileName == nil
            ? indexedLines.first { $0.sourceLineNumber == diagnostic.lineNumber }
            : nil
        let displayLineNumber = source?.displayLineNumber ?? diagnostic.lineNumber
        let sourceText = source?.source
        let filePrefix = diagnostic.fileName.map { "\($0):" } ?? ""
        host.printLine("\(filePrefix)Line \(displayLineNumber), column \(diagnostic.column + 1): \(diagnostic.message)")
        if let sourceText {
            host.printLine(sourceText)
            host.printLine(String(repeating: " ", count: max(0, diagnostic.column)) + "^")
        }
    }

    return true
}

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--list-demos" {
    for name in BundledDemos.names() {
        host.printLine(name)
    }
    exit(0)
}

if arguments.first == "--demo" {
    guard arguments.count >= 2 else {
        host.printLine("Usage: BASICShell --demo <name>")
        exit(1)
    }
    guard let source = BundledDemos.source(named: arguments[1]) else {
        host.printLine("Unknown demo: \(arguments[1])")
        host.printLine("Available demos:")
        for name in BundledDemos.names() {
            host.printLine("  \(name)")
        }
        exit(1)
    }
    do {
        session.program.loadSource(source, fileName: demoFileName(for: arguments[1]))
        if printDiagnosticsIfNeeded() {
            exit(1)
        }
        try BASICInterpreter(program: session.program, host: host).run()
        exit(0)
    } catch let error as BASICError {
        host.printLine(error.description)
        exit(1)
    } catch {
        host.printLine("Error: \(error.localizedDescription)")
        exit(1)
    }
}

if let scriptPath = arguments.first {
    do {
        session.program.loadSource(try host.loadTextFile(path: scriptPath), fileName: scriptPath)
        if printDiagnosticsIfNeeded() {
            exit(1)
        }
        try BASICInterpreter(program: session.program, host: host).run()
        exit(0)
    } catch let error as BASICError {
        host.printLine(error.description)
        exit(1)
    } catch {
        host.printLine("Error: \(error.localizedDescription)")
        exit(1)
    }
}

print("AIBasic Shell")
print("Type HELP for commands. Type QUIT to exit.")

while true {
    guard let line = host.readLine(prompt: session.prompt) else { break }
    if line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "EDIT" {
        runTermKitEditor()
        continue
    }
    if isRunCommand(line), printDiagnosticsIfNeeded() {
        continue
    }
    if !session.submit(line) { break }
}
