import BASICCore
import Darwin
import Foundation
@preconcurrency import VectorTerminalSDK

nonisolated(unsafe) private var shellInterruptWriteFD: Int32 = -1

final class ShellEventTrace: @unchecked Sendable {
    static let shared = ShellEventTrace()

    private let lock = NSLock()
    private let url: URL?

    private init() {
        guard let path = ProcessInfo.processInfo.environment["AIBASIC_SHELL_EVENT_LOG"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            url = nil
            return
        }
        url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    func write(_ message: String) {
        guard let url else { return }
        let line = "\(Date()) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try line.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            // Event tracing is diagnostic-only; never let it disturb the shell.
        }
    }
}

private func handleShellInterruptSignal(_ signal: Int32) {
    guard shellInterruptWriteFD >= 0 else { return }
    var byte = UInt8(signal == SIGINT ? 3 : 0)
    _ = Darwin.write(shellInterruptWriteFD, &byte, 1)
}

final class ShellInterruptBridge {
    private var readFD: Int32 = -1
    private var writeFD: Int32 = -1
    private var readerThread: Thread?

    func start(executionControl: BASICExecutionControl) {
        guard readFD < 0, writeFD < 0 else { return }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        readFD = fds[0]
        writeFD = fds[1]
        shellInterruptWriteFD = writeFD

        let flags = fcntl(writeFD, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(writeFD, F_SETFL, flags | O_NONBLOCK)
        }

        signal(SIGINT, handleShellInterruptSignal)

        let thread = Thread { [readFD] in
            var byte: UInt8 = 0
            while Darwin.read(readFD, &byte, 1) == 1 {
                ShellEventTrace.shared.write("interrupt-bridge byte=\(byte)")
                if byte == 3 {
                    executionControl.requestBreak()
                }
            }
        }
        thread.name = "AIBasic.Shell.InterruptBridge"
        thread.start()
        readerThread = thread
    }
}

final class ShellLineEditor: @unchecked Sendable {
    static let shared = ShellLineEditor()

    private var isOverwriteMode = false
    private var fieldLength: Int?
    private var maxLength: Int?
    private var fieldViewStart = 0
    private var fieldDisplayCursor = 0
    private var commandHistory = ShellLineEditor.loadCommandHistory()
    private var aliasCompletionWords: [String] = []
    private var includesExternalCommandCompletions = true
    private static let maxCommandHistoryEntries = 500
    private static let commandCompletionWords = [
        "alias", "cat", "cd", "clear", "dirs", "edit", "exec", "exit", "export", "files",
        "help", "history", "load", "ls", "new", "pipe", "popd", "prompt", "pushd", "pwd",
        "quit", "run", "save", "setenv", "system", "tasks", "type", "unsetenv", "which"
    ]
    private static let basicCompletionWords = [
        "ASYNC", "AWAIT", "CALL", "CASE", "CLASS", "COLOR", "DATA", "DEF", "DIM", "DO",
        "ELSE", "ELSEIF", "END", "ERROR", "EXIT", "FOR", "FUNCTION", "GLOBAL", "GOSUB",
        "GOTO", "IF", "IMPORT", "INPUT", "INTERFACE", "JOIN", "LABEL", "LET", "LINE",
        "LOCAL", "LOOP", "NEXT", "ON", "OPTION", "PRINT", "READ", "REM", "RESTORE",
        "RETURN", "SELECT", "SLEEP", "STEP", "SYSTEM", "THEN", "TO", "TYPE", "WEND",
        "WHILE", "YIELD"
    ]
    private static let commandHistoryURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("BASICShell", isDirectory: true).appendingPathComponent("BASICShellHistory.txt")
    }()
    private static let legacyCommandHistoryURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AIBasic", isDirectory: true).appendingPathComponent("BASICShellHistory.txt")
    }()

    func readLine(prompt: String) -> String? {
        readLine(prompt: prompt, exitOnSpecialKey: false)?.text
    }

    func readLine(prompt: String, exitOnSpecialKey: Bool) -> BASICLineInputResult? {
        readLine(prompt: prompt, exitOnSpecialKey: exitOnSpecialKey, options: BASICLineInputOptions())
    }

    func readLine(prompt: String, exitOnSpecialKey: Bool, options: BASICLineInputOptions) -> BASICLineInputResult? {
        let usesCommandHistory = !exitOnSpecialKey
            && options.fieldLength == nil
            && options.maxLength == nil
            && options.defaultText == nil
        let fd = STDIN_FILENO
        guard isatty(fd) == 1 else {
            Swift.print(prompt, terminator: "")
            return Swift.readLine().map {
                let text = limited($0, maxLength: options.maxLength)
                if usesCommandHistory { appendCommandHistory(text) }
                return BASICLineInputResult(text: text)
            }
        }

        var originalTermios = termios()
        guard tcgetattr(fd, &originalTermios) == 0 else {
            Swift.print(prompt, terminator: "")
            return Swift.readLine().map {
                let text = limited($0, maxLength: options.maxLength)
                if usesCommandHistory { appendCommandHistory(text) }
                return BASICLineInputResult(text: text)
            }
        }

        var rawTermios = originalTermios
        rawTermios.c_lflag &= ~tcflag_t(ICANON | ECHO)
        rawTermios.c_cc.16 = 1
        rawTermios.c_cc.17 = 0
        guard tcsetattr(fd, TCSANOW, &rawTermios) == 0 else {
            Swift.print(prompt, terminator: "")
            return Swift.readLine().map {
                let text = limited($0, maxLength: options.maxLength)
                if usesCommandHistory { appendCommandHistory(text) }
                return BASICLineInputResult(text: text)
            }
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
        var historyIndex: Int?
        var draftBeforeHistory = ""
        var historySearchQuery: String?
        var completionMenu: CompletionMenu?

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
                if acceptCompletionSelection(&completionMenu, prompt: prompt, buffer: &buffer, cursor: &cursor) {
                    historyIndex = nil
                    historySearchQuery = nil
                    continue
                }
                clearCompletionMenu(&completionMenu, prompt: prompt, buffer: buffer, cursor: cursor)
                Swift.print()
                if usesCommandHistory {
                    appendCommandHistory(buffer)
                }
                return BASICLineInputResult(text: buffer)
            }

            if raw == "\u{4}", buffer.isEmpty {
                clearCompletionMenu(&completionMenu, prompt: prompt, buffer: buffer, cursor: cursor)
                Swift.print()
                return nil
            }

            if raw == "\u{3}" {
                clearCompletionMenu(&completionMenu, prompt: prompt, buffer: buffer, cursor: cursor)
                Swift.print("^C")
                buffer = ""
                cursor = 0
                return BASICLineInputResult(text: "")
            }

            if raw == "\u{12}" {
                clearCompletionMenu(&completionMenu, prompt: prompt, buffer: buffer, cursor: cursor)
                guard usesCommandHistory else { continue }
                reverseSearchHistory(
                    buffer: &buffer,
                    cursor: &cursor,
                    historyIndex: &historyIndex,
                    draftBeforeHistory: &draftBeforeHistory,
                    searchQuery: &historySearchQuery
                )
                continue
            }

            if raw == "\t" {
                if exitOnSpecialKey {
                    clearCompletionMenu(&completionMenu, prompt: prompt, buffer: buffer, cursor: cursor)
                    Swift.print()
                    return BASICLineInputResult(text: buffer, exitKey: raw)
                }
                historySearchQuery = nil
                completeLine(prompt: prompt, buffer: &buffer, cursor: &cursor, completionMenu: &completionMenu)
                continue
            }

            clearCompletionMenu(&completionMenu, prompt: prompt, buffer: buffer, cursor: cursor)

            if raw == "\u{8}" || raw == "\u{7F}" {
                historyIndex = nil
                historySearchQuery = nil
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
                handleEscape(
                    raw,
                    buffer: &buffer,
                    cursor: &cursor,
                    usesCommandHistory: usesCommandHistory,
                    historyIndex: &historyIndex,
                    draftBeforeHistory: &draftBeforeHistory,
                    historySearchQuery: &historySearchQuery
                )
                continue
            }

            if raw.count == 1, let scalar = raw.unicodeScalars.first, scalar.value >= 32 {
                historyIndex = nil
                historySearchQuery = nil
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

    func historyEntries() -> [String] {
        commandHistory
    }

    func clearHistory() {
        commandHistory.removeAll()
        saveCommandHistory()
    }

    func setAliasCompletionWords(_ words: [String]) {
        aliasCompletionWords = words
    }

    func setIncludesExternalCommandCompletions(_ enabled: Bool) {
        includesExternalCommandCompletions = enabled
    }

    func deleteHistoryEntry(at index: Int) throws {
        guard commandHistory.indices.contains(index) else {
            throw BASICError.runtime("History entry \(index + 1) does not exist")
        }
        commandHistory.remove(at: index)
        saveCommandHistory()
    }

    private func readRawKey(fd: Int32) -> String? {
        var byte: UInt8 = 0
        guard Darwin.read(fd, &byte, 1) == 1 else { return nil }
        var bytes = [byte]
        if byte == 27 {
            while let next = readByteIfAvailable(fd: fd, timeoutMicroseconds: 25_000) {
                bytes.append(next)
                if bytes.count == 2, next == UInt8(ascii: "_") {
                    drainVectorTerminalResponseBody(fd: fd)
                    return readRawKey(fd: fd)
                }
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

    private func handleEscape(
        _ raw: String,
        buffer: inout String,
        cursor: inout Int,
        usesCommandHistory: Bool,
        historyIndex: inout Int?,
        draftBeforeHistory: inout String,
        historySearchQuery: inout String?
    ) {
        let key = BASICKeyNormalizer.normalize(raw)
        switch key {
        case "[H":
            guard usesCommandHistory else { break }
            historySearchQuery = nil
            showPreviousCommand(buffer: &buffer, cursor: &cursor, historyIndex: &historyIndex, draftBeforeHistory: &draftBeforeHistory)
        case "[P":
            guard usesCommandHistory else { break }
            historySearchQuery = nil
            showNextCommand(buffer: &buffer, cursor: &cursor, historyIndex: &historyIndex, draftBeforeHistory: draftBeforeHistory)
        case "[K": moveCursor(to: cursor - 1, cursor: &cursor, buffer: buffer)
        case "[M": moveCursor(to: cursor + 1, cursor: &cursor, buffer: buffer)
        case "[G": moveCursor(to: 0, cursor: &cursor, buffer: buffer)
        case "[O": moveCursor(to: buffer.count, cursor: &cursor, buffer: buffer)
        case "[S":
            guard cursor < buffer.count else { return }
            historySearchQuery = nil
            buffer.removeSubrange(range(in: buffer, offset: cursor, length: 1))
            repaint(buffer: buffer, cursor: cursor)
        case "[R":
            isOverwriteMode.toggle()
        default:
            break
        }
    }

    private func reverseSearchHistory(
        buffer: inout String,
        cursor: inout Int,
        historyIndex: inout Int?,
        draftBeforeHistory: inout String,
        searchQuery: inout String?
    ) {
        guard !commandHistory.isEmpty else { return }
        let query: String
        if let existingQuery = searchQuery {
            query = existingQuery
        } else {
            draftBeforeHistory = buffer
            query = buffer
            searchQuery = query
        }

        let startIndex = historyIndex.map { max(0, $0 - 1) } ?? commandHistory.count - 1
        guard let matchIndex = findPreviousHistoryMatch(query: query, beforeOrAt: startIndex) else {
            bell()
            return
        }

        historyIndex = matchIndex
        replaceLine(with: commandHistory[matchIndex], buffer: &buffer, cursor: &cursor)
    }

    private func findPreviousHistoryMatch(query: String, beforeOrAt startIndex: Int) -> Int? {
        guard !commandHistory.isEmpty else { return nil }
        let safeStart = min(max(0, startIndex), commandHistory.count - 1)
        for index in stride(from: safeStart, through: 0, by: -1) {
            if query.isEmpty || commandHistory[index].localizedCaseInsensitiveContains(query) {
                return index
            }
        }
        return nil
    }

    private func completeLine(prompt: String, buffer: inout String, cursor: inout Int) {
        var menu: CompletionMenu?
        completeLine(prompt: prompt, buffer: &buffer, cursor: &cursor, completionMenu: &menu)
    }

    private func completeLine(
        prompt: String,
        buffer: inout String,
        cursor: inout Int,
        completionMenu: inout CompletionMenu?
    ) {
        guard fieldLength == nil else { return }

        if var menu = completionMenu {
            guard menu.context == completionContext(buffer: buffer, cursor: cursor) else {
                clearCompletionMenu(&completionMenu, prompt: prompt, buffer: buffer, cursor: cursor)
                return
            }
            if let selectedIndex = menu.selectedIndex {
                menu.selectedIndex = (selectedIndex + 1) % menu.candidates.count
            } else {
                menu.selectedIndex = 0
            }
            renderCompletionMenu(&menu, prompt: prompt, buffer: buffer, cursor: cursor)
            completionMenu = menu
            return
        }

        let context = completionContext(buffer: buffer, cursor: cursor)
        let candidates = completionCandidates(for: context)
        guard !candidates.isEmpty else {
            bell()
            return
        }

        if candidates.count == 1 {
            replaceCompletionToken(with: candidates[0], context: context, buffer: &buffer, cursor: &cursor)
            return
        }

        let common = commonPrefix(candidates)
        if common.count > context.token.count {
            replaceCompletionToken(with: common, context: context, buffer: &buffer, cursor: &cursor)
            return
        }

        var menu = CompletionMenu(candidates: candidates, context: context)
        renderCompletionMenu(&menu, prompt: prompt, buffer: buffer, cursor: cursor)
        completionMenu = menu
    }

    private struct CompletionMenu {
        let candidates: [String]
        let context: CompletionContext
        var selectedIndex: Int?
        var displayLineCount = 0
    }

    private struct CompletionContext: Equatable {
        let token: String
        let startOffset: Int
        let isCommandPosition: Bool
    }

    private func completionContext(buffer: String, cursor: Int) -> CompletionContext {
        let prefix = String(buffer.prefix(cursor))
        let tokenStart = prefix.lastIndex(where: { $0.isWhitespace }).map { prefix.index(after: $0) } ?? prefix.startIndex
        let token = String(prefix[tokenStart...])
        let leading = prefix[..<tokenStart].trimmingCharacters(in: .whitespacesAndNewlines)
        return CompletionContext(
            token: token,
            startOffset: prefix.distance(from: prefix.startIndex, to: tokenStart),
            isCommandPosition: leading.isEmpty
        )
    }

    private func completionCandidates(for context: CompletionContext) -> [String] {
        var seen = Set<String>()
        var candidates: [String] = []

        func append(_ value: String) {
            guard !value.isEmpty, seen.insert(value).inserted else { return }
            candidates.append(value)
        }

        for candidate in pathCompletionCandidates(for: context.token) {
            append(candidate)
        }

        if context.isCommandPosition, !context.token.contains("/") {
            var commandWords = Self.commandCompletionWords + Self.basicCompletionWords + aliasCompletionWords
            if includesExternalCommandCompletions {
                commandWords += pathExecutableCompletionWords()
            }
            for word in commandWords where caseInsensitiveHasPrefix(word, prefix: context.token) {
                append(word)
            }
        }

        return candidates.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func pathCompletionCandidates(for token: String) -> [String] {
        let split = splitPathCompletionToken(token)
        let directoryPath = expandedPath(split.directory)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directoryPath) else { return [] }

        let visibleDirectory = split.directory
        return entries
            .filter { caseInsensitiveHasPrefix($0, prefix: split.partial) }
            .map { entry in
                let fullPath = URL(fileURLWithPath: directoryPath).appendingPathComponent(entry).path
                let suffix = FileManager.default.fileExists(atPath: fullPath, isDirectory: nil) && isDirectory(fullPath) ? "/" : ""
                return visibleDirectory + escapedCompletionPathComponent(entry) + suffix
            }
    }

    private func splitPathCompletionToken(_ token: String) -> (directory: String, partial: String) {
        if let slash = token.lastIndex(of: "/") {
            let directory = String(token[...slash])
            let partial = String(token[token.index(after: slash)...])
            return (directory, partial)
        }
        return ("", token)
    }

    private func expandedPath(_ visibleDirectory: String) -> String {
        if visibleDirectory.isEmpty {
            return FileManager.default.currentDirectoryPath
        }
        if visibleDirectory == "~/" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        if visibleDirectory.hasPrefix("~/") {
            let rest = visibleDirectory.dropFirst(2)
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(rest)).path
        }
        return NSString(string: visibleDirectory).expandingTildeInPath
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func escapedCompletionPathComponent(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "\\ ")
    }

    private func pathExecutableCompletionWords() -> [String] {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var words: [String] = []
        var seen = Set<String>()
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: String(directory)) else { continue }
            for entry in entries where seen.insert(entry).inserted {
                let fullPath = URL(fileURLWithPath: String(directory)).appendingPathComponent(entry).path
                guard access(fullPath, X_OK) == 0, !isDirectory(fullPath) else { continue }
                words.append(entry)
            }
        }
        return words
    }

    private func replaceCompletionToken(
        with replacement: String,
        context: CompletionContext,
        buffer: inout String,
        cursor: inout Int
    ) {
        let oldCursor = cursor
        let tokenRange = range(in: buffer, offset: context.startOffset, length: cursor - context.startOffset)
        buffer.replaceSubrange(tokenRange, with: replacement)
        cursor = context.startOffset + replacement.count
        let redrawStart = min(context.startOffset, oldCursor)
        let prefix = terminalCursorMovement(from: oldCursor, to: redrawStart)
        repaint(buffer: buffer, cursor: cursor, from: redrawStart, prefix: prefix)
    }

    private func commonPrefix(_ values: [String]) -> String {
        guard var prefix = values.first else { return "" }
        for value in values.dropFirst() {
            while !prefix.isEmpty && !caseInsensitiveHasPrefix(value, prefix: prefix) {
                prefix.removeLast()
            }
        }
        return prefix
    }

    private func caseInsensitiveHasPrefix(_ value: String, prefix: String) -> Bool {
        guard !prefix.isEmpty else { return true }
        return value.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }

    private func acceptCompletionSelection(
        _ completionMenu: inout CompletionMenu?,
        prompt: String,
        buffer: inout String,
        cursor: inout Int
    ) -> Bool {
        guard let menu = completionMenu, let selectedIndex = menu.selectedIndex else {
            return false
        }
        clearCompletionMenu(&completionMenu, prompt: prompt, buffer: buffer, cursor: cursor)
        replaceCompletionToken(with: menu.candidates[selectedIndex], context: menu.context, buffer: &buffer, cursor: &cursor)
        return true
    }

    private func clearCompletionMenu(
        _ completionMenu: inout CompletionMenu?,
        prompt: String,
        buffer: String,
        cursor: Int
    ) {
        guard let menu = completionMenu, menu.displayLineCount > 0 else {
            completionMenu = nil
            return
        }
        moveFromInputCursorToLineEnd(buffer: buffer, cursor: cursor)
        for _ in 0..<menu.displayLineCount {
            Swift.print("\r\n\u{1B}[2K", terminator: "")
        }
        returnFromCompletionRowsToInput(prompt: prompt, cursor: cursor, rowCount: menu.displayLineCount)
        fflush(stdout)
        completionMenu = nil
    }

    private func renderCompletionMenu(_ menu: inout CompletionMenu, prompt: String, buffer: String, cursor: Int) {
        var oldMenu: CompletionMenu? = menu
        clearCompletionMenu(&oldMenu, prompt: prompt, buffer: buffer, cursor: cursor)

        let lines = completionMenuLines(candidates: menu.candidates, selectedIndex: menu.selectedIndex)
        guard !lines.isEmpty else { return }

        moveFromInputCursorToLineEnd(buffer: buffer, cursor: cursor)
        for line in lines {
            Swift.print("\r\n\u{1B}[2K" + line, terminator: "")
        }
        returnFromCompletionRowsToInput(prompt: prompt, cursor: cursor, rowCount: lines.count)
        fflush(stdout)
        menu.displayLineCount = lines.count
    }

    private func completionMenuLines(candidates: [String], selectedIndex: Int?) -> [String] {
        let columns = terminalColumns()
        let cellWidth = min(max((candidates.map(\.count).max() ?? 0) + 2, 8), columns)
        let columnCount = max(1, columns / cellWidth)
        var lines: [String] = []
        var line = ""
        for (index, candidate) in candidates.enumerated() {
            let padded = candidate.padding(toLength: cellWidth, withPad: " ", startingAt: 0)
            let rendered = index == selectedIndex ? "\u{1B}[0;7m" + padded + "\u{1B}[0m" : padded
            line += rendered
            if (index + 1).isMultiple(of: columnCount) {
                lines.append(line)
                line = ""
            }
        }
        if !line.isEmpty {
            lines.append(line)
        }
        return lines
    }

    private func moveFromInputCursorToLineEnd(buffer: String, cursor: Int) {
        let right = max(0, buffer.count - cursor)
        if right > 0 {
            Swift.print(String(repeating: "\u{1B}[C", count: right), terminator: "")
        }
    }

    private func terminalCursorMovement(from oldCursor: Int, to newCursor: Int) -> String {
        let delta = newCursor - oldCursor
        if delta > 0 {
            return String(repeating: "\u{1B}[C", count: delta)
        }
        if delta < 0 {
            return String(repeating: "\u{1B}[D", count: -delta)
        }
        return ""
    }

    private func returnFromCompletionRowsToInput(prompt: String, cursor: Int, rowCount: Int) {
        Swift.print("\r", terminator: "")
        if rowCount > 0 {
            Swift.print("\u{1B}[\(rowCount)A", terminator: "")
        }
        let targetColumn = visiblePromptWidth(prompt) + cursor
        if targetColumn > 0 {
            Swift.print("\u{1B}[\(targetColumn)C", terminator: "")
        }
    }

    private func visiblePromptWidth(_ prompt: String) -> Int {
        var width = 0
        var index = prompt.startIndex
        while index < prompt.endIndex {
            let scalar = prompt[index].unicodeScalars.first
            if scalar?.value == 0x1B {
                index = indexAfterANSISequence(in: prompt, startingAt: index)
                continue
            }
            if scalar?.value == 0x07 {
                index = prompt.index(after: index)
                continue
            }
            width += 1
            index = prompt.index(after: index)
        }
        return width
    }

    private func indexAfterANSISequence(in text: String, startingAt escapeIndex: String.Index) -> String.Index {
        var index = text.index(after: escapeIndex)
        guard index < text.endIndex else { return index }
        let introducer = text[index]
        index = text.index(after: index)

        if introducer == "[" {
            while index < text.endIndex {
                let scalar = text[index].unicodeScalars.first?.value ?? 0
                index = text.index(after: index)
                if (0x40...0x7E).contains(scalar) {
                    break
                }
            }
            return index
        }

        if introducer == "]" {
            while index < text.endIndex {
                let char = text[index]
                if char.unicodeScalars.first?.value == 0x07 {
                    return text.index(after: index)
                }
                if char.unicodeScalars.first?.value == 0x1B {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\\" {
                        return text.index(after: next)
                    }
                }
                index = text.index(after: index)
            }
            return index
        }

        return index
    }

    private func terminalColumns() -> Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
            return Int(size.ws_col)
        }
        return 80
    }

    private func showPreviousCommand(
        buffer: inout String,
        cursor: inout Int,
        historyIndex: inout Int?,
        draftBeforeHistory: inout String
    ) {
        guard !commandHistory.isEmpty else { return }
        if let index = historyIndex {
            historyIndex = max(0, index - 1)
        } else {
            draftBeforeHistory = buffer
            historyIndex = commandHistory.count - 1
        }
        guard let index = historyIndex else { return }
        replaceLine(with: commandHistory[index], buffer: &buffer, cursor: &cursor)
    }

    private func showNextCommand(
        buffer: inout String,
        cursor: inout Int,
        historyIndex: inout Int?,
        draftBeforeHistory: String
    ) {
        guard let index = historyIndex else { return }
        if index < commandHistory.count - 1 {
            historyIndex = index + 1
            replaceLine(with: commandHistory[index + 1], buffer: &buffer, cursor: &cursor)
        } else {
            historyIndex = nil
            replaceLine(with: draftBeforeHistory, buffer: &buffer, cursor: &cursor)
        }
    }

    private func replaceLine(with text: String, buffer: inout String, cursor: inout Int) {
        moveCursor(to: 0, cursor: &cursor, buffer: buffer)
        buffer = text
        cursor = buffer.count
        Swift.print("\u{1B}[K" + buffer, terminator: "")
        fflush(stdout)
    }

    private func bell() {
        Swift.print("\u{7}", terminator: "")
        fflush(stdout)
    }

    private func appendCommandHistory(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if commandHistory.last == command { return }
        commandHistory.append(command)
        if commandHistory.count > Self.maxCommandHistoryEntries {
            commandHistory.removeFirst(commandHistory.count - Self.maxCommandHistoryEntries)
        }
        saveCommandHistory()
    }

    private static func loadCommandHistory() -> [String] {
        let sourceURL = FileManager.default.fileExists(atPath: commandHistoryURL.path)
            ? commandHistoryURL
            : legacyCommandHistoryURL
        guard let contents = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return []
        }
        return contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(maxCommandHistoryEntries)
            .map(String.init)
    }

    private func saveCommandHistory() {
        let directory = Self.commandHistoryURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try commandHistory.joined(separator: "\n").write(to: Self.commandHistoryURL, atomically: true, encoding: .utf8)
        } catch {
            // History is a convenience feature; keep the shell usable if persistence fails.
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

    func drainPendingVectorTerminalResponses() {
        let fd = STDIN_FILENO
        guard isatty(fd) == 1 else { return }

        var originalTermios = termios()
        guard tcgetattr(fd, &originalTermios) == 0 else { return }
        var rawTermios = originalTermios
        rawTermios.c_lflag &= ~tcflag_t(ICANON | ECHO)
        rawTermios.c_cc.16 = 0
        rawTermios.c_cc.17 = 0
        guard tcsetattr(fd, TCSANOW, &rawTermios) == 0 else { return }
        defer {
            var restored = originalTermios
            _ = tcsetattr(fd, TCSANOW, &restored)
        }

        while let first = readByteIfAvailable(fd: fd, timeoutMicroseconds: 20_000) {
            guard first == 0x1b else {
                continue
            }
            guard let second = readByteIfAvailable(fd: fd, timeoutMicroseconds: 5_000) else {
                continue
            }
            guard second == UInt8(ascii: "_") else {
                continue
            }
            drainVectorTerminalResponseBody(fd: fd)
        }
    }

    private func drainVectorTerminalResponseBody(fd: Int32) {
        while let next = readByteIfAvailable(fd: fd, timeoutMicroseconds: 5_000) {
            if next == 0x07 {
                break
            }
            if next == 0x1b,
               let terminator = readByteIfAvailable(fd: fd, timeoutMicroseconds: 5_000),
               terminator == UInt8(ascii: "\\") {
                break
            }
        }
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

enum ShellGraphicsPolicy: String {
    case auto
    case off

    static let environmentName = "BASICSHELL_GRAPHICS"
    static let legacyEnvironmentName = "AIBASIC_GRAPHICS"

    static func fromEnvironment(default defaultPolicy: ShellGraphicsPolicy = .auto) -> ShellGraphicsPolicy {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment[environmentName] ?? environment[legacyEnvironmentName] else {
            return defaultPolicy
        }
        return raw.lowercased() == "off" ? .off : defaultPolicy
    }

    static func parse(arguments: inout [String]) throws -> ShellGraphicsPolicy {
        var policy = fromEnvironment()
        var remaining: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--graphics=") {
                let rawValue = String(argument.dropFirst("--graphics=".count)).lowercased()
                guard rawValue == "off" else {
                    throw BASICError.runtime("Unknown graphics mode: \(rawValue). Supported mode: off")
                }
                policy = .off
            } else if argument == "--graphics" {
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    throw BASICError.runtime("Missing value for --graphics")
                }
                let rawValue = arguments[valueIndex].lowercased()
                guard rawValue == "off" else {
                    throw BASICError.runtime("Unknown graphics mode: \(rawValue). Supported mode: off")
                }
                policy = .off
                index += 1
            } else {
                remaining.append(argument)
            }
            index += 1
        }
        arguments = remaining
        return policy
    }
}

final class ConsoleHost: BASICFileHost, BASICSystemHost, BASICProcessHost, BASICForegroundTTYProcessHost, BASICExecutableResolverHost, BASICCommandHistoryHost, BASICBlockingKeyboardHost, BASICConsoleHost, BASICConfiguredLineInputHost, BASICLoggingHost, BASICListingStyleHost, BASICRunDisplayHost, BASICGraphicsHost, BASICVectorTerminalHost {
    var usesColoredListing: Bool { true }
    var supportsForegroundTTYProcesses: Bool { true }
    var isBASICLoggingEnabled: Bool { false }
    var isGraphicsAvailable: Bool { isVectorTerminalAvailable }
    var isVectorTerminalAvailable: Bool { vectorTerminalAvailability }
    var graphicsUnavailableMessage: String { "VectorTerminal graphics are not supported by this terminal" }
    private let graphicsPolicy: ShellGraphicsPolicy
    private lazy var vectorTerminalAvailability = vectorTerminalProbe.isAvailable
    private var didUseVectorTerminal = false
    private var graphicsMode = BASICScreenMode(number: 0, width: 0, height: 0, colorCount: 0)
    private var graphicsPixels: [Int] = []
    private var graphicsColor = 1
    private var basicGraphicsOperationID = 0
    private var liveVTGCanvasSize = BASICVectorTerminalCanvasSnapshot(width: 0, height: 0, source: "BASICShell")
    private weak var session: BASICSession?
    private weak var executionControl: BASICExecutionControl?
    private let eventPollLock = NSLock()
    private var isVectorTerminalEventPollingEnabled = false
    private var eventPollOriginalTermios: termios?
    private var pendingKeyInput: [String] = []
    private var partialTerminalEscapeBytes: [UInt8] = []
    private lazy var vtgCanvas: VectorTerminalCanvas = vectorTerminalProbe.canvas
    private lazy var vectorTerminalProbe: (canvas: VectorTerminalCanvas, isAvailable: Bool) = {
        guard isatty(STDOUT_FILENO) == 1 else {
            return (.noOp(), false)
        }
        if case .off = graphicsPolicy {
            return (.noOp(), false)
        }
        guard let canvas = try? VectorTerminalCanvas(timeoutMilliseconds: 750) else {
            return (.noOp(), false)
        }
        if let snapshot = canvasSnapshot(canvas.queryCurrentCanvas(timeoutMilliseconds: 750)) {
            liveVTGCanvasSize = snapshot
        }
        return (canvas, true)
    }()

    init(graphicsPolicy: ShellGraphicsPolicy) {
        self.graphicsPolicy = graphicsPolicy
    }

    func attachSession(_ session: BASICSession) {
        self.session = session
    }

    func attachExecutionControl(_ executionControl: BASICExecutionControl) {
        self.executionControl = executionControl
    }

    private func detectVectorTerminalAvailability() -> Bool {
        guard isatty(STDOUT_FILENO) == 1 else { return false }
        switch graphicsPolicy {
        case .off:
            return false
        case .auto:
            return vectorTerminalProbe.isAvailable
        }
    }

    private func requireVectorTerminal() throws {
        guard isVectorTerminalAvailable else {
            throw BASICError.runtime("VectorTerminal graphics are not supported by this terminal")
        }
        startVectorTerminalEventPolling()
    }

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

    func commandHistoryEntries() -> [String] {
        ShellLineEditor.shared.historyEntries()
    }

    func clearCommandHistory() {
        ShellLineEditor.shared.clearHistory()
    }

    func deleteCommandHistoryEntry(at index: Int) throws {
        try ShellLineEditor.shared.deleteHistoryEntry(at: index)
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
        pollVectorTerminalEvents()
        if let buffered = popPendingKeyInput() {
            return buffered
        }
        if hasPartialTerminalEscapeBuffered() {
            return nil
        }
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

        while true {
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            guard count == 1 else { return nil }
            var bytes = [byte]
            if byte == 27 {
                while let next = readByteIfAvailable(fd: fd, timeoutMicroseconds: terminalEscapeContinuationTimeoutMicroseconds(for: bytes)) {
                    bytes.append(next)
                    if isCompleteTerminalEscape(bytes) || isCompleteKeyboardEscape(bytes) { break }
                }
                if isPartialTerminalEscape(bytes) {
                    bufferPartialTerminalEscape(bytes, source: "read-key")
                    return nil
                }
                if handleTerminalEventBytes(bytes) {
                    if let buffered = popPendingKeyInput() {
                        return buffered
                    }
                    continue
                }
            }
            if byte == 3 {
                ShellEventTrace.shared.write("read-key-etx-request-break")
                executionControl?.requestBreak()
                return nil
            }
            return String(bytes: bytes, encoding: .utf8) ?? String(UnicodeScalar(byte))
        }
    }

    private func popPendingKeyInput() -> String? {
        eventPollLock.lock()
        defer { eventPollLock.unlock() }
        guard !pendingKeyInput.isEmpty else { return nil }
        return pendingKeyInput.removeFirst()
    }

    private func hasPartialTerminalEscapeBuffered() -> Bool {
        eventPollLock.lock()
        defer { eventPollLock.unlock() }
        return !partialTerminalEscapeBytes.isEmpty
    }

    private func pushPendingKeyInput(_ value: String) {
        eventPollLock.lock()
        pendingKeyInput.append(value)
        eventPollLock.unlock()
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

    func resolveExecutable(_ command: String, environment: BASICEnvironmentPatch) throws -> String? {
        let expandedCommand = expandedPath(command)
        if expandedCommand.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expandedCommand) ? expandedCommand : nil
        }

        let patchedEnvironment = environment.applying(to: ProcessInfo.processInfo.environment)
        let pathValue = patchedEnvironment["PATH"] ?? patchedEnvironment["Path"] ?? patchedEnvironment["path"] ?? ""
        for directory in pathValue.split(separator: ":", omittingEmptySubsequences: false) {
            let base = directory.isEmpty ? "." : String(directory)
            let candidate = URL(fileURLWithPath: expandedPath(base), isDirectory: true)
                .appendingPathComponent(command)
                .standardizedFileURL
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
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
        let legacyPrefixes = [
            "basicPrograms/demos/",
            "basicPrograms/shell/",
            "basicPrograms/BASICStudio/",
            "shell/",
            "studio/"
        ]
        var didStrip = true
        while didStrip {
            didStrip = false
            for prefix in legacyPrefixes where normalized.hasPrefix(prefix) {
                normalized.removeFirst(prefix.count)
                didStrip = true
            }
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

    private func vtgColor(_ value: String?) -> VTGColor? {
        guard let value, value.lowercased() != "none" else { return nil }
        return VTGColor(value)
    }

    private func vtgLineCap(_ value: String?) -> VTGLineCap? {
        guard let value else { return nil }
        return VTGLineCap(rawValue: value.lowercased())
    }

    private func vtgLineJoin(_ value: String?) -> VTGLineJoin? {
        guard let value else { return nil }
        return VTGLineJoin(rawValue: value.lowercased())
    }

    private func vtgSpriteFilter(_ value: String) -> VTGSpriteFilter {
        VTGSpriteFilter(rawValue: value.lowercased()) ?? .smooth
    }

    private func ansiColor(_ value: String) throws -> ANSIColor {
        switch value.lowercased() {
        case "black": return .black
        case "red": return .red
        case "green": return .green
        case "yellow": return .yellow
        case "blue": return .blue
        case "magenta": return .magenta
        case "cyan": return .cyan
        case "white": return .white
        default: throw BASICError.runtime("Unknown ANSI color \(value)")
        }
    }

    private func canvasSnapshot(_ canvas: VTGCanvas?) -> BASICVectorTerminalCanvasSnapshot? {
        guard let canvas else { return nil }
        return BASICVectorTerminalCanvasSnapshot(
            width: canvas.width,
            height: canvas.height,
            source: canvas.source,
            rawResponse: canvas.rawResponse
        )
    }

    private func updateLiveVTGCanvasSize(_ canvas: VTGCanvas?) -> BASICVectorTerminalCanvasSnapshot? {
        guard let snapshot = canvasSnapshot(canvas) else { return nil }
        liveVTGCanvasSize = snapshot
        return snapshot
    }

    private func startVectorTerminalEventPolling() {
        eventPollLock.lock()
        defer { eventPollLock.unlock() }
        guard !isVectorTerminalEventPollingEnabled, isatty(STDIN_FILENO) == 1 else { return }
        ShellEventTrace.shared.write("vtg-event-polling start")

        var original = termios()
        if tcgetattr(STDIN_FILENO, &original) == 0 {
            var raw = original
            raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
            raw.c_lflag |= tcflag_t(ISIG)
            raw.c_cc.16 = 0
            raw.c_cc.17 = 0
            if tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 {
                eventPollOriginalTermios = original
                ShellEventTrace.shared.write("vtg-event-polling termios noncanonical noecho isig")
            }
        }

        vtgCanvas.enableResizeEvents()
        if session?.acceptsHostInputEvent(type: "MOUSE") == true {
            vtgCanvas.enableMouseReporting(mode: "all")
            enableANSIMouseMotionReporting()
        }
        isVectorTerminalEventPollingEnabled = true
    }

    func stopVectorTerminalEventPolling() {
        eventPollLock.lock()
        let wasEnabled = isVectorTerminalEventPollingEnabled
        isVectorTerminalEventPollingEnabled = false
        let original = eventPollOriginalTermios
        eventPollOriginalTermios = nil
        pendingKeyInput.removeAll()
        partialTerminalEscapeBytes.removeAll()
        eventPollLock.unlock()

        if wasEnabled {
            ShellEventTrace.shared.write("vtg-event-polling stop")
            vtgCanvas.disableMouseReporting()
            disableANSIMouseMotionReporting()
            vtgCanvas.disableResizeEvents()
        }
        if var original {
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
        }
    }

    private func pollVectorTerminalEvents() {
        eventPollLock.lock()
        let isEnabled = isVectorTerminalEventPollingEnabled
        eventPollLock.unlock()
        guard isEnabled else { return }

        while let bytes = readTerminalEventBytes(timeoutMilliseconds: 0) {
            _ = handleTerminalEventBytes(bytes)
        }
    }

    private func enableANSIMouseMotionReporting() {
        writeRawTerminal("\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1003h\u{1B}[?1006h")
    }

    private func disableANSIMouseMotionReporting() {
        writeRawTerminal("\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1000l\u{1B}[?1006l")
    }

    private func writeRawTerminal(_ value: String) {
        FileHandle.standardOutput.write(Data(value.utf8))
    }

    private func readTerminalEventBytes(timeoutMilliseconds: Int32) -> [UInt8]? {
        var byte: UInt8 = 0
        var bytes: [UInt8]
        if partialTerminalEscapeBytes.isEmpty {
            var pollFD = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, timeoutMilliseconds) > 0 else { return nil }

            guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
            guard byte == 0x1b else { return [byte] }
            bytes = [byte]
        } else {
            bytes = partialTerminalEscapeBytes
            partialTerminalEscapeBytes.removeAll()
        }
        while !isCompleteTerminalEscape(bytes) {
            if bytes.count > 8192 { return bytes }
            var nextPollFD = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&nextPollFD, 1, terminalEscapeContinuationTimeoutMilliseconds(for: bytes)) > 0 else {
                bufferPartialTerminalEscape(bytes, source: "poll")
                return nil
            }
            guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else {
                bufferPartialTerminalEscape(bytes, source: "poll")
                return nil
            }
            bytes.append(byte)
        }
        return bytes
    }

    private func bufferPartialTerminalEscape(_ bytes: [UInt8], source: String) {
        guard isPartialTerminalEscape(bytes) else { return }
        partialTerminalEscapeBytes = bytes
        ShellEventTrace.shared.write("terminal-partial-buffered source=\(source) bytes=\(debugEscaped(bytes))")
    }

    private func isPartialTerminalEscape(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2, bytes[0] == 0x1b else { return false }
        guard !isCompleteTerminalEscape(bytes) else { return false }
        if bytes[1] == UInt8(ascii: "_") {
            return true
        }
        if bytes[1] == UInt8(ascii: "[") {
            return true
        }
        return false
    }

    private func terminalEscapeContinuationTimeoutMilliseconds(for bytes: [UInt8]) -> Int32 {
        guard bytes.count >= 2 else { return 25 }
        if bytes[1] == UInt8(ascii: "_") {
            return 150
        }
        return 25
    }

    private func terminalEscapeContinuationTimeoutMicroseconds(for bytes: [UInt8]) -> Int32 {
        terminalEscapeContinuationTimeoutMilliseconds(for: bytes) * 1_000
    }

    private func isCompleteTerminalEscape(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2, bytes[0] == 0x1b else { return false }
        if bytes[1] == UInt8(ascii: "_") {
            return bytes.count >= 2 &&
                bytes[bytes.count - 2] == 0x1b &&
                bytes[bytes.count - 1] == UInt8(ascii: "\\")
        }
        if bytes.count >= 3,
           bytes[1] == UInt8(ascii: "["),
           bytes[2] == UInt8(ascii: "M") {
            return bytes.count >= 6
        }
        if bytes[1] == UInt8(ascii: "[") {
            guard bytes.count >= 3 else { return false }
            if bytes[2] == UInt8(ascii: "<") {
                guard let last = bytes.last else { return false }
                return last == UInt8(ascii: "M") || last == UInt8(ascii: "m")
            }
            guard let last = bytes.last else { return false }
            return last >= 0x40 && last <= 0x7e
        }
        if bytes[1] == UInt8(ascii: "O"),
           let last = bytes.last {
            return bytes.count >= 3 && last >= 0x40 && last <= 0x7e
        }
        return bytes.count > 1
    }

    private func isCompleteKeyboardEscape(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        if bytes[1] == UInt8(ascii: "_") {
            return false
        }
        return isCompleteEscapeSequence(bytes)
    }

    private func handleTerminalEventBytes(_ bytes: [UInt8]) -> Bool {
        traceTerminalBytes(bytes)
        guard bytes.first == 0x1b else {
            guard let byte = bytes.first else { return false }
            if byte == 3 {
                ShellEventTrace.shared.write("plain-etx-request-break")
                executionControl?.requestBreak()
                return true
            } else {
                return false
            }
        }

        if handleANSIX10Mouse(bytes) { return true }

        if let response = String(bytes: bytes, encoding: .utf8) {
            if handleVTGKeyResponse(response) { return true }
            if handleVTGTerminalResponse(response) { return true }
            if handleANSISGRMouse(response) { return true }
        }
        return false
    }

    private func handleVTGKeyResponse(_ response: String) -> Bool {
        guard response.contains("_VTG;key") else { return false }
        let fields = vtgFields(from: response)
        ShellEventTrace.shared.write("vtg-key fields=\(fields)")
        let key = fields["key"] ?? fields["char"] ?? fields["value"] ?? ""
        let modifiers = (fields["mods"] ?? fields["modifiers"] ?? "").lowercased()
        let code = fields["code"].flatMap(Int.init)
            ?? fields["ascii"].flatMap(Int.init)
            ?? fields["byte"].flatMap(Int.init)

        if code == 3 || (key.caseInsensitiveCompare("c") == .orderedSame && modifiers.contains("control")) {
            ShellEventTrace.shared.write("vtg-key-request-break key=\(key) code=\(code.map(String.init) ?? "nil") modifiers=\(modifiers)")
            executionControl?.requestBreak()
        } else if !key.isEmpty, key.count == 1 {
            pushPendingKeyInput(key)
        }
        return true
    }

    private func handleVTGTerminalResponse(_ response: String) -> Bool {
        if response.contains("_VTG;resize") || response.contains("_VTG;canvas") || response.contains("_VTG;size") {
            let fields = vtgFields(from: response)
            guard let width = fields["width"].flatMap(Int.init),
                  let height = fields["height"].flatMap(Int.init) else {
                return true
            }
            let previous = liveVTGCanvasSize
            liveVTGCanvasSize = BASICVectorTerminalCanvasSnapshot(
                width: width,
                height: height,
                source: response.contains("_VTG;resize") ? "resize" : "canvas",
                rawResponse: response
            )
            if width != previous.width || height != previous.height {
                session?.postResizeEvent(width: max(1, width), height: max(1, height))
            }
            return true
        }

        guard response.contains("_VTG;mouse") else { return false }
        let fields = vtgFields(from: response)
        ShellEventTrace.shared.write("vtg-mouse fields=\(fields)")
        guard let x = fields["virtualX"].flatMap(Int.init) ?? fields["x"].flatMap(Int.init),
              let y = fields["virtualY"].flatMap(Int.init) ?? fields["y"].flatMap(Int.init) else {
            return true
        }
        let subtype = normalizedMouseSubtype(fields["type"] ?? "down")
        let button = normalizedVTGMouseButton(fields["button"])
        postMouseEvent(
            subtype: subtype,
            x: x,
            y: y,
            button: button,
            deltaX: normalizedMouseDelta(fields["deltaX"] ?? fields["scrollX"]),
            deltaY: normalizedMouseDelta(fields["deltaY"] ?? fields["scrollY"]),
            hitID: fields["hit"] ?? fields["hitID"] ?? "",
            target: fields["target"] ?? fields["targetID"] ?? ""
        )
        return true
    }

    private func handleANSISGRMouse(_ response: String) -> Bool {
        guard response.hasPrefix("\u{1B}[<"),
              response.hasSuffix("M") || response.hasSuffix("m") else {
            return false
        }
        let body = response.dropFirst(3).dropLast().split(separator: ";")
        guard body.count == 3,
              let rawButton = Int(body[0]),
              let x = Int(body[1]),
              let y = Int(body[2]) else {
            ShellEventTrace.shared.write("ansi-sgr-mouse malformed response=\(debugEscaped(response))")
            return true
        }

        let isRelease = response.hasSuffix("m")
        let isMotion = (rawButton & 32) != 0
        let isScroll = (rawButton & 64) != 0
        let baseButton = rawButton & 3
        let button = normalizedMouseButton(rawButton)
        let subtype: String
        let scrollDelta = normalizedScrollDelta(rawButton)
        if isScroll {
            subtype = "scroll"
        } else if isMotion {
            subtype = "move"
        } else if isRelease {
            subtype = "up"
        } else {
            subtype = "down"
        }
        ShellEventTrace.shared.write("ansi-sgr-mouse rawButton=\(rawButton) base=\(baseButton) release=\(isRelease) motion=\(isMotion) scroll=\(isScroll) subtype=\(subtype) button=\(button) x=\(x) y=\(y) deltaX=\(scrollDelta.x) deltaY=\(scrollDelta.y)")
        postMouseEvent(subtype: subtype, x: x, y: y, button: button, deltaX: scrollDelta.x, deltaY: scrollDelta.y)
        return true
    }

    private func handleANSIX10Mouse(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 6,
              bytes[0] == 0x1b,
              bytes[1] == UInt8(ascii: "["),
              bytes[2] == UInt8(ascii: "M") else {
            return false
        }

        let rawButton = Int(bytes[3]) - 32
        let x = Int(bytes[4]) - 32
        let y = Int(bytes[5]) - 32
        let isRelease = rawButton & 3 == 3
        let isMotion = (rawButton & 32) != 0
        let isScroll = (rawButton & 64) != 0
        let baseButton = rawButton & 3
        let button = normalizedMouseButton(rawButton)
        let subtype: String
        let scrollDelta = normalizedScrollDelta(rawButton)
        if isScroll {
            subtype = "scroll"
        } else if isMotion {
            subtype = "move"
        } else if isRelease {
            subtype = "up"
        } else {
            subtype = "down"
        }
        ShellEventTrace.shared.write("ansi-x10-mouse rawButton=\(rawButton) base=\(baseButton) release=\(isRelease) motion=\(isMotion) scroll=\(isScroll) subtype=\(subtype) button=\(button) x=\(x) y=\(y) deltaX=\(scrollDelta.x) deltaY=\(scrollDelta.y)")
        postMouseEvent(subtype: subtype, x: x, y: y, button: button, deltaX: scrollDelta.x, deltaY: scrollDelta.y)
        return true
    }

    private func postMouseEvent(
        subtype: String,
        x: Int,
        y: Int,
        button: Int,
        deltaX: Double = 0,
        deltaY: Double = 0,
        hitID: String = "",
        target: String = ""
    ) {
        let normalizedSubtype = normalizedMouseSubtype(subtype)
        let pressedButtons = normalizedSubtype == "down" || normalizedSubtype == "click" || (normalizedSubtype == "move" && button > 0) ? button : 0
        ShellEventTrace.shared.write("post-mouse subtype=\(normalizedSubtype) x=\(x) y=\(y) button=\(button) buttons=\(pressedButtons) deltaX=\(deltaX) deltaY=\(deltaY) hit=\(hitID) target=\(target)")
        session?.postMouseEvent(
            subtype: normalizedSubtype,
            x: Double(x),
            y: Double(y),
            button: button,
            buttons: pressedButtons,
            duration: 0,
            deltaX: deltaX,
            deltaY: deltaY,
            hitID: hitID,
            target: target
        )
    }

    private func normalizedMouseDelta(_ value: String?) -> Double {
        guard let value else { return 0 }
        return Double(value) ?? 0
    }

    private func normalizedScrollDelta(_ rawButton: Int) -> (x: Double, y: Double) {
        guard (rawButton & 64) != 0 else { return (0, 0) }
        switch rawButton & 3 {
        case 0:
            return (0, 1)
        case 1:
            return (0, -1)
        case 2:
            return (-1, 0)
        case 3:
            return (1, 0)
        default:
            return (0, 0)
        }
    }

    private func normalizedMouseButton(_ rawButton: Int) -> Int {
        let base = rawButton & 3
        if base == 3 { return 0 }
        return base
    }

    private func normalizedVTGMouseButton(_ value: String?) -> Int {
        guard let value else { return 0 }
        switch value.lowercased() {
        case "left", "primary", "main":
            return 0
        case "middle", "center":
            return 1
        case "right", "secondary":
            return 2
        default:
            return Int(value) ?? 0
        }
    }

    private func traceTerminalBytes(_ bytes: [UInt8]) {
        ShellEventTrace.shared.write("terminal-bytes \(debugEscaped(bytes))")
        if let response = String(bytes: bytes, encoding: .utf8), bytes.first == 0x1b {
            ShellEventTrace.shared.write("terminal-string \(debugEscaped(response))")
        }
    }

    private func debugEscaped(_ bytes: [UInt8]) -> String {
        bytes.map { byte in
            switch byte {
            case 0x1b: return "ESC"
            case 0x20...0x7e: return String(UnicodeScalar(byte))
            default: return String(format: "0x%02X", byte)
            }
        }.joined(separator: " ")
    }

    private func debugEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{1B}", with: "ESC")
            .replacingOccurrences(of: "\u{07}", with: "BEL")
    }

    private func normalizedMouseSubtype(_ subtype: String) -> String {
        let lowered = subtype.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered == "up" || lowered.hasSuffix("up") || lowered.contains("release") {
            return "up"
        }
        if lowered == "move" || lowered.hasSuffix("move") || lowered == "motion" ||
            lowered == "drag" || lowered.hasSuffix("drag") {
            return "move"
        }
        if lowered == "click" || lowered.hasSuffix("click") {
            return "click"
        }
        if lowered == "scroll" || lowered.hasSuffix("scroll") {
            return "scroll"
        }
        return lowered.isEmpty ? "down" : lowered
    }

    private func vtgFields(from response: String) -> [String: String] {
        var payload = response
        if let start = payload.range(of: "_VTG;") {
            payload = String(payload[start.upperBound...])
        }
        payload = payload
            .replacingOccurrences(of: "\u{1B}\\", with: "")
            .replacingOccurrences(of: "\u{07}", with: "")
        var fields: [String: String] = [:]
        for part in payload.split(separator: ",") {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = String(part[..<equals])
            let value = String(part[part.index(after: equals)...])
            fields[key] = value
        }
        return fields
    }

    private func handleVectorTerminalEvent(_ event: VectorTerminalEvent) {
        switch event {
        case .key(let byte):
            if byte == 3 {
                executionControl?.requestBreak()
            } else {
                pushPendingKeyInput(String(UnicodeScalar(byte)))
            }
        case .specialKey:
            break
        case .mouse(let mouse):
            postMouseEvent(
                subtype: mouse.type,
                x: mouse.virtualX ?? mouse.x,
                y: mouse.virtualY ?? mouse.y,
                button: mouse.button,
                deltaX: Double(mouse.scrollX ?? 0),
                deltaY: Double(mouse.scrollY ?? 0),
                hitID: mouse.hitID ?? "",
                target: mouse.targetID ?? ""
            )
        case .resize(let canvas), .canvas(let canvas):
            let previous = liveVTGCanvasSize
            if let snapshot = updateLiveVTGCanvasSize(canvas),
               snapshot.width != previous.width || snapshot.height != previous.height {
                session?.postResizeEvent(width: max(1, snapshot.width), height: max(1, snapshot.height))
            }
        case .frame(let frame):
            postFrameEvent(frame)
        }
    }

    private func postFrameEvent(_ frame: VTGFrameEvent) {
        let subtype = normalizedFrameSubtype(frame.type)
        ShellEventTrace.shared.write("post-frame subtype=\(subtype) id=\(frame.id) frameType=\(frame.type) reason=\(frame.reason ?? "") timeout=\(frame.timeoutMilliseconds ?? 0)")
        session?.postFrameEvent(
            subtype: subtype,
            frameID: frame.id,
            frameType: frame.type,
            reason: frame.reason ?? "",
            timeoutMilliseconds: frame.timeoutMilliseconds ?? 0,
            rawResponse: frame.rawResponse
        )
    }

    private func normalizedFrameSubtype(_ type: String) -> String {
        let lowercased = type.lowercased()
        if lowercased.hasPrefix("frame") {
            let suffix = String(type.dropFirst("frame".count))
            if !suffix.isEmpty {
                return suffix.uppercased()
            }
        }
        return type.uppercased()
    }

    private func capabilityJSON(_ capabilities: VTGCapabilities?) -> String? {
        guard let capabilities else { return nil }
        var object: [String: Any] = [
            "commands": capabilities.commands,
            "planned": capabilities.planned,
            "primitives": capabilities.primitives,
            "underTextPrimitives": capabilities.underTextPrimitives,
            "formats": capabilities.formats,
            "raster": capabilities.raster,
            "sprites": capabilities.sprites,
            "events": capabilities.events,
            "colors": capabilities.colors,
            "textPlaneStatus": capabilities.textPlaneStatus.rawValue,
            "rawResponse": capabilities.rawResponse
        ]
        object["protocolName"] = capabilities.protocolName
        object["schema"] = capabilities.schema
        object["version"] = capabilities.version
        object["renderer"] = capabilities.renderer
        object["layers"] = capabilities.layers
        object["defaultLayer"] = capabilities.defaultLayer
        object["textPlane"] = capabilities.textPlane
        object["layerScroll"] = capabilities.layerScroll
        object["layerAlpha"] = capabilities.layerAlpha
        object["clip"] = capabilities.clip
        object["hit"] = capabilities.hit
        if let canvas = capabilities.canvas {
            object["canvas"] = ["width": canvas.width, "height": canvas.height, "source": canvas.source ?? ""]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    private func basicGraphicsColor(_ color: Int) -> VTGColor {
        let palette = [
            "#000000", "#60a5fa", "#22c55e", "#06b6d4",
            "#ef4444", "#d946ef", "#f59e0b", "#e5e7eb",
            "#6b7280", "#93c5fd", "#86efac", "#67e8f9",
            "#fca5a5", "#f0abfc", "#fde047", "#ffffff"
        ]
        let index = ((color % palette.count) + palette.count) % palette.count
        return VTGColor(palette[index])
    }

    private func basicGraphicsColor(_ color: BASICColor) -> VTGColor {
        VTGColor(color.cssHex)
    }

    private func normalizedGraphicsColor(_ color: Int) -> Int {
        guard graphicsMode.colorCount > 0 else { return max(0, color) }
        return max(0, color) % graphicsMode.colorCount
    }

    private func nativeSemanticGraphicsMode(number: Int = 0) -> BASICScreenMode {
        let width = liveVTGCanvasSize.width > 0 ? liveVTGCanvasSize.width : 1024
        let height = liveVTGCanvasSize.height > 0 ? liveVTGCanvasSize.height : 768
        return BASICScreenMode(number: number, width: width, height: height, colorCount: 16)
    }

    private func ensureNativeSemanticGraphicsMode(number: Int = 0) {
        guard graphicsMode.width <= 0 || graphicsMode.height <= 0 else { return }
        graphicsMode = nativeSemanticGraphicsMode(number: number)
        graphicsPixels = Array(repeating: 0, count: max(0, graphicsMode.width * graphicsMode.height))
    }

    private func nextBasicGraphicsID(_ prefix: String) -> String {
        basicGraphicsOperationID += 1
        return "basic-\(prefix)-\(basicGraphicsOperationID)"
    }

    private func setFramebufferPixel(x: Int, y: Int, color: Int) {
        guard graphicsMode.width > 0,
              graphicsMode.height > 0,
              x >= 0,
              y >= 0,
              x < graphicsMode.width,
              y < graphicsMode.height else { return }
        graphicsPixels[y * graphicsMode.width + x] = normalizedGraphicsColor(color)
    }

    private func drawFramebufferLine(x1: Int, y1: Int, x2: Int, y2: Int, color: Int) {
        var x = x1
        var y = y1
        let dx = abs(x2 - x1)
        let sx = x1 < x2 ? 1 : -1
        let dy = -abs(y2 - y1)
        let sy = y1 < y2 ? 1 : -1
        var error = dx + dy

        while true {
            setFramebufferPixel(x: x, y: y, color: color)
            if x == x2 && y == y2 { break }
            let nextError = 2 * error
            if nextError >= dy {
                error += dy
                x += sx
            }
            if nextError <= dx {
                error += dx
                y += sy
            }
        }
    }

    private func drawFramebufferCircle(cx: Int, cy: Int, radius: Int, color: Int) {
        var x = max(0, radius)
        var y = 0
        var error = 1 - x

        while x >= y {
            setFramebufferCirclePoints(cx: cx, cy: cy, x: x, y: y, color: color)
            y += 1
            if error < 0 {
                error += 2 * y + 1
            } else {
                x -= 1
                error += 2 * (y - x) + 1
            }
        }
    }

    private func drawFramebufferEllipse(cx: Int, cy: Int, radiusX: Int, radiusY: Int, color: Int) {
        let rx = max(0, radiusX)
        let ry = max(0, radiusY)
        guard rx > 0 || ry > 0 else {
            setFramebufferPixel(x: cx, y: cy, color: color)
            return
        }

        let steps = max(24, Int(Double(max(rx, ry)) * 8))
        var plotted = Set<Int>()
        for step in 0...steps {
            let angle = (Double(step) / Double(steps)) * Double.pi * 2
            let x = cx + Int((Double(rx) * cos(angle)).rounded())
            let y = cy + Int((Double(ry) * sin(angle)).rounded())
            let key = (y << 16) ^ x
            guard plotted.insert(key).inserted else { continue }
            setFramebufferPixel(x: x, y: y, color: color)
        }
    }

    private func setFramebufferCirclePoints(cx: Int, cy: Int, x: Int, y: Int, color: Int) {
        setFramebufferPixel(x: cx + x, y: cy + y, color: color)
        setFramebufferPixel(x: cx + y, y: cy + x, color: color)
        setFramebufferPixel(x: cx - y, y: cy + x, color: color)
        setFramebufferPixel(x: cx - x, y: cy + y, color: color)
        setFramebufferPixel(x: cx - x, y: cy - y, color: color)
        setFramebufferPixel(x: cx - y, y: cy - x, color: color)
        setFramebufferPixel(x: cx + y, y: cy - x, color: color)
        setFramebufferPixel(x: cx + x, y: cy - y, color: color)
    }

    private func paintFramebufferFill(x: Int, y: Int, color: Int, borderColor: Int?) -> [(x: Int, y: Int)] {
        guard graphicsMode.width > 0,
              graphicsMode.height > 0,
              x >= 0,
              y >= 0,
              x < graphicsMode.width,
              y < graphicsMode.height else { return [] }
        let fillColor = normalizedGraphicsColor(color)
        let border = borderColor.map(normalizedGraphicsColor)
        let startIndex = y * graphicsMode.width + x
        let startColor = graphicsPixels[startIndex]
        guard startColor != fillColor, border != startColor else { return [] }

        var changed: [(x: Int, y: Int)] = []
        var stack = [(x: x, y: y)]
        var visited = Set<Int>()

        while let point = stack.popLast() {
            guard point.x >= 0,
                  point.y >= 0,
                  point.x < graphicsMode.width,
                  point.y < graphicsMode.height else { continue }
            let index = point.y * graphicsMode.width + point.x
            guard visited.insert(index).inserted else { continue }
            let current = graphicsPixels[index]
            if let border, current == border { continue }
            guard current == startColor else { continue }

            graphicsPixels[index] = fillColor
            changed.append(point)
            stack.append((point.x + 1, point.y))
            stack.append((point.x - 1, point.y))
            stack.append((point.x, point.y + 1))
            stack.append((point.x, point.y - 1))
        }

        return changed
    }

    func finishVectorTerminalForegroundRun() {
        stopVectorTerminalEventPolling()
        guard didUseVectorTerminal, isVectorTerminalAvailable else { return }
        vtgCanvas.clear()
        vtgCanvas.present()
        didUseVectorTerminal = false
    }

    func clearVectorTerminalOnExit() {
        finishVectorTerminalForegroundRun()
    }

    func prepareToPrintRunResult() {
        finishVectorTerminalForegroundRun()
    }

    func clearEverything() {
        vtgCanvas.clearScreen()
        if isVectorTerminalAvailable {
            vtgCanvas.clear()
            vtgCanvas.present()
        }
    }

    func setScreenMode(_ mode: BASICScreenMode) {
        guard isVectorTerminalAvailable else { return }
        ensureNativeSemanticGraphicsMode(number: mode.number)
    }

    func setGraphicsColor(_ color: Int) {
        graphicsColor = color
    }

    func setGraphicsColor(_ color: BASICColor) {
        graphicsColor = color.legacyIndex ?? 1
    }

    func clearGraphics(color: Int?) {
        guard isVectorTerminalAvailable else { return }
        guard graphicsMode.width > 0, graphicsMode.height > 0 else {
            didUseVectorTerminal = true
            vtgCanvas.clear()
            vtgCanvas.present()
            return
        }
        graphicsPixels = Array(repeating: normalizedGraphicsColor(color ?? 0), count: graphicsMode.width * graphicsMode.height)
        basicGraphicsOperationID = 0
        didUseVectorTerminal = true
        vtgCanvas.clear()
        vtgCanvas.present()
    }

    func setPixel(x: Int, y: Int, color: Int) {
        guard isVectorTerminalAvailable else { return }
        ensureNativeSemanticGraphicsMode()
        setFramebufferPixel(x: x, y: y, color: color)
        didUseVectorTerminal = true
        vtgCanvas.pixel(id: nextBasicGraphicsID("pixel"), x: x, y: y, color: basicGraphicsColor(color), layer: nil)
        vtgCanvas.present()
    }

    func setPixel(x: Int, y: Int, color: BASICColor) {
        guard isVectorTerminalAvailable else { return }
        ensureNativeSemanticGraphicsMode()
        setFramebufferPixel(x: x, y: y, color: color.legacyIndex ?? 1)
        didUseVectorTerminal = true
        vtgCanvas.pixel(id: nextBasicGraphicsID("pixel"), x: x, y: y, color: basicGraphicsColor(color), layer: nil)
        vtgCanvas.present()
    }

    func getPixel(x: Int, y: Int) -> Int {
        guard graphicsMode.width > 0,
              graphicsMode.height > 0,
              x >= 0,
              y >= 0,
              x < graphicsMode.width,
              y < graphicsMode.height else { return 0 }
        return graphicsPixels[y * graphicsMode.width + x]
    }

    func drawLine(x1: Int, y1: Int, x2: Int, y2: Int, color: Int) {
        guard isVectorTerminalAvailable else { return }
        ensureNativeSemanticGraphicsMode()
        drawFramebufferLine(x1: x1, y1: y1, x2: x2, y2: y2, color: color)
        didUseVectorTerminal = true
        vtgCanvas.line(id: nextBasicGraphicsID("line"), x1: x1, y1: y1, x2: x2, y2: y2, stroke: basicGraphicsColor(color), width: 2, layer: nil)
        vtgCanvas.present()
    }

    func drawLine(x1: Int, y1: Int, x2: Int, y2: Int, color: BASICColor) {
        guard isVectorTerminalAvailable else { return }
        ensureNativeSemanticGraphicsMode()
        drawFramebufferLine(x1: x1, y1: y1, x2: x2, y2: y2, color: color.legacyIndex ?? 1)
        didUseVectorTerminal = true
        vtgCanvas.line(id: nextBasicGraphicsID("line"), x1: x1, y1: y1, x2: x2, y2: y2, stroke: basicGraphicsColor(color), width: 2, layer: nil)
        vtgCanvas.present()
    }

    func drawPath(points: [BASICGraphicsPoint], color: Int) {
        guard isVectorTerminalAvailable, points.count >= 2 else { return }
        ensureNativeSemanticGraphicsMode()
        for index in points.indices.dropLast() {
            let start = points[index]
            let end = points[points.index(after: index)]
            drawFramebufferLine(x1: start.x, y1: start.y, x2: end.x, y2: end.y, color: color)
        }
        didUseVectorTerminal = true
        vtgCanvas.draw(
            id: nextBasicGraphicsID("draw"),
            points: points.map { VTGPoint(x: $0.x, y: $0.y) },
            stroke: basicGraphicsColor(color),
            width: 2,
            layer: nil
        )
        vtgCanvas.present()
    }

    func drawPath(points: [BASICGraphicsPoint], color: BASICColor) {
        guard isVectorTerminalAvailable, points.count >= 2 else { return }
        ensureNativeSemanticGraphicsMode()
        for index in points.indices.dropLast() {
            let start = points[index]
            let end = points[points.index(after: index)]
            drawFramebufferLine(x1: start.x, y1: start.y, x2: end.x, y2: end.y, color: color.legacyIndex ?? 1)
        }
        didUseVectorTerminal = true
        vtgCanvas.draw(
            id: nextBasicGraphicsID("draw"),
            points: points.map { VTGPoint(x: $0.x, y: $0.y) },
            stroke: basicGraphicsColor(color),
            width: 2,
            layer: nil
        )
        vtgCanvas.present()
    }

    func drawCircle(cx: Int, cy: Int, radius: Int, color: Int) {
        guard isVectorTerminalAvailable else { return }
        ensureNativeSemanticGraphicsMode()
        drawFramebufferCircle(cx: cx, cy: cy, radius: radius, color: color)
        didUseVectorTerminal = true
        vtgCanvas.circle(id: nextBasicGraphicsID("circle"), cx: cx, cy: cy, radius: radius, stroke: basicGraphicsColor(color), fill: nil, lineWidth: 2, layer: nil)
        vtgCanvas.present()
    }

    func drawCircle(cx: Int, cy: Int, radius: Int, color: BASICColor) {
        guard isVectorTerminalAvailable else { return }
        ensureNativeSemanticGraphicsMode()
        drawFramebufferCircle(cx: cx, cy: cy, radius: radius, color: color.legacyIndex ?? 1)
        didUseVectorTerminal = true
        vtgCanvas.circle(id: nextBasicGraphicsID("circle"), cx: cx, cy: cy, radius: radius, stroke: basicGraphicsColor(color), fill: nil, lineWidth: 2, layer: nil)
        vtgCanvas.present()
    }

    func drawEllipse(cx: Int, cy: Int, radiusX: Int, radiusY: Int, color: Int) {
        guard isVectorTerminalAvailable else { return }
        ensureNativeSemanticGraphicsMode()
        drawFramebufferEllipse(cx: cx, cy: cy, radiusX: radiusX, radiusY: radiusY, color: color)
        didUseVectorTerminal = true
        vtgCanvas.ellipse(id: nextBasicGraphicsID("ellipse"), cx: cx, cy: cy, rx: radiusX, ry: radiusY, stroke: basicGraphicsColor(color), fill: nil, lineWidth: 2, layer: nil)
        vtgCanvas.present()
    }

    func drawEllipse(cx: Int, cy: Int, radiusX: Int, radiusY: Int, color: BASICColor) {
        guard isVectorTerminalAvailable else { return }
        ensureNativeSemanticGraphicsMode()
        drawFramebufferEllipse(cx: cx, cy: cy, radiusX: radiusX, radiusY: radiusY, color: color.legacyIndex ?? 1)
        didUseVectorTerminal = true
        vtgCanvas.ellipse(id: nextBasicGraphicsID("ellipse"), cx: cx, cy: cy, rx: radiusX, ry: radiusY, stroke: basicGraphicsColor(color), fill: nil, lineWidth: 2, layer: nil)
        vtgCanvas.present()
    }

    func paintFill(x: Int, y: Int, color: Int, borderColor: Int?) {
        guard isVectorTerminalAvailable else { return }
        ensureNativeSemanticGraphicsMode()
        let changed = paintFramebufferFill(x: x, y: y, color: color, borderColor: borderColor)
        didUseVectorTerminal = true
        for run in BASICGraphicsBatcher.horizontalRuns(from: changed.map { BASICGraphicsPoint(x: $0.x, y: $0.y) }) {
            if run.x1 == run.x2 {
                vtgCanvas.pixel(id: nextBasicGraphicsID("paint"), x: run.x1, y: run.y, color: basicGraphicsColor(color), layer: nil)
            } else {
                vtgCanvas.line(id: nextBasicGraphicsID("paint"), x1: run.x1, y1: run.y, x2: run.x2, y2: run.y, stroke: basicGraphicsColor(color), width: 1, layer: nil)
            }
        }
        vtgCanvas.present()
    }

    func paintFill(x: Int, y: Int, color: BASICColor, borderColor: BASICColor?) {
        guard isVectorTerminalAvailable else { return }
        ensureNativeSemanticGraphicsMode()
        let changed = paintFramebufferFill(x: x, y: y, color: color.legacyIndex ?? 1, borderColor: borderColor?.legacyIndex)
        didUseVectorTerminal = true
        for run in BASICGraphicsBatcher.horizontalRuns(from: changed.map { BASICGraphicsPoint(x: $0.x, y: $0.y) }) {
            if run.x1 == run.x2 {
                vtgCanvas.pixel(id: nextBasicGraphicsID("paint"), x: run.x1, y: run.y, color: basicGraphicsColor(color), layer: nil)
            } else {
                vtgCanvas.line(id: nextBasicGraphicsID("paint"), x1: run.x1, y1: run.y, x2: run.x2, y2: run.y, stroke: basicGraphicsColor(color), width: 1, layer: nil)
            }
        }
        vtgCanvas.present()
    }

    func vectorTerminalClear() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.clear()
    }

    func vectorTerminalPresent() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.present()
    }

    func vectorTerminalDelete(id: String) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.delete(id: id)
    }

    func vectorTerminalClearRect(id: String, x: Int, y: Int, width: Int, height: Int, layer: Int?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.clearRect(id: id, x: x, y: y, width: width, height: height, layer: layer)
    }

    func vectorTerminalPixel(id: String, x: Int, y: Int, color: String, layer: Int?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.pixel(id: id, x: x, y: y, color: VTGColor(color), layer: layer)
    }

    func vectorTerminalLine(id: String, x1: Int, y1: Int, x2: Int, y2: Int, stroke: String, width: Int, lineCap: String?, layer: Int?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.line(id: id, x1: x1, y1: y1, x2: x2, y2: y2, stroke: VTGColor(stroke), width: width, lineCap: vtgLineCap(lineCap), layer: layer)
    }

    func vectorTerminalDraw(id: String, points: [(x: Int, y: Int)], stroke: String, width: Int, lineCap: String?, lineJoin: String?, layer: Int?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.draw(id: id, points: points.map { VTGPoint(x: $0.x, y: $0.y) }, stroke: VTGColor(stroke), width: width, lineCap: vtgLineCap(lineCap), lineJoin: vtgLineJoin(lineJoin), layer: layer)
    }

    func vectorTerminalQuadraticCurve(id: String, x1: Int, y1: Int, cx: Int, cy: Int, x2: Int, y2: Int, stroke: String, width: Int, lineCap: String?, lineJoin: String?, layer: Int?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.quadraticCurve(id: id, x1: x1, y1: y1, cx: cx, cy: cy, x2: x2, y2: y2, stroke: VTGColor(stroke), width: width, lineCap: vtgLineCap(lineCap), lineJoin: vtgLineJoin(lineJoin), layer: layer)
    }

    func vectorTerminalCubicCurve(id: String, x1: Int, y1: Int, c1x: Int, c1y: Int, c2x: Int, c2y: Int, x2: Int, y2: Int, stroke: String, width: Int, lineCap: String?, lineJoin: String?, layer: Int?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.cubicCurve(id: id, x1: x1, y1: y1, c1x: c1x, c1y: c1y, c2x: c2x, c2y: c2y, x2: x2, y2: y2, stroke: VTGColor(stroke), width: width, lineCap: vtgLineCap(lineCap), lineJoin: vtgLineJoin(lineJoin), layer: layer)
    }

    func vectorTerminalPath(id: String, payload: String, stroke: String?, fill: String?, lineWidth: Int, lineCap: String?, lineJoin: String?, layer: Int?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.path(id: id, payload: payload, stroke: vtgColor(stroke), fill: vtgColor(fill), lineWidth: lineWidth, lineCap: vtgLineCap(lineCap), lineJoin: vtgLineJoin(lineJoin), layer: layer)
    }

    func vectorTerminalTriangle(id: String, x1: Int, y1: Int, x2: Int, y2: Int, x3: Int, y3: Int, stroke: String?, fill: String?, lineWidth: Int, radius: Int, lineJoin: String?, layer: Int?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.triangle(id: id, p1: VTGPoint(x: x1, y: y1), p2: VTGPoint(x: x2, y: y2), p3: VTGPoint(x: x3, y: y3), stroke: vtgColor(stroke), fill: vtgColor(fill), lineWidth: lineWidth, radius: radius, lineJoin: vtgLineJoin(lineJoin), layer: layer)
    }

    func vectorTerminalRect(id: String, x: Int, y: Int, width: Int, height: Int, stroke: String?, fill: String?, lineWidth: Int, radius: Int, corners: String?, lineJoin: String?, layer: Int?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.rect(id: id, x: x, y: y, width: width, height: height, stroke: vtgColor(stroke), fill: vtgColor(fill), lineWidth: lineWidth, radius: radius, corners: corners, lineJoin: vtgLineJoin(lineJoin), layer: layer)
    }

    func vectorTerminalCircle(id: String, cx: Int, cy: Int, radius: Int, stroke: String?, fill: String?, lineWidth: Int, layer: Int?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.circle(id: id, cx: cx, cy: cy, radius: radius, stroke: vtgColor(stroke), fill: vtgColor(fill), lineWidth: lineWidth, layer: layer)
    }

    func vectorTerminalEllipse(id: String, cx: Int, cy: Int, rx: Int, ry: Int, stroke: String?, fill: String?, lineWidth: Int, layer: Int?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.ellipse(id: id, cx: cx, cy: cy, rx: rx, ry: ry, stroke: vtgColor(stroke), fill: vtgColor(fill), lineWidth: lineWidth, layer: layer)
    }

    func vectorTerminalText(id: String, x: Int, y: Int, value: String, color: String, size: Int, layer: Int?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.text(id: id, x: x, y: y, value: value, color: VTGColor(color), size: size, layer: layer)
    }

    func vectorTerminalVectorPrint(id: String, x: Int, y: Int, height: Int, value: String, stroke: String, width: Int, layer: Int?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.vectorPrint(id: id, x: x, y: y, height: height, value: value, stroke: VTGColor(stroke), width: width, layer: layer)
    }

    func vectorTerminalVectorTextSize(height: Int, value: String) throws -> BASICVectorTerminalCanvasSnapshot {
        try requireVectorTerminal()
        let size = vtgCanvas.vectorTextSize(height: height, value: value)
        return BASICVectorTerminalCanvasSnapshot(width: size.width, height: size.height, source: "VectorTerminalSDK")
    }

    func vectorTerminalPillButton(id: String, text: String, fill: String, stroke: String?, lineWidth: Int, layer: Int?, target: String?, timeoutMilliseconds: Int) throws -> BASICVectorTerminalLayoutSnapshot? {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        guard let layout = vtgCanvas.pillButton(
            id: id,
            text: text,
            fill: VTGColor(fill),
            stroke: vtgColor(stroke),
            lineWidth: lineWidth,
            layer: layer,
            target: target,
            timeoutMilliseconds: timeoutMilliseconds
        ) else { return nil }
        return BASICVectorTerminalLayoutSnapshot(
            x: layout.x,
            y: layout.y,
            width: layout.width,
            height: layout.height,
            row: layout.row,
            column: layout.column
        )
    }

    func vectorTerminalImagePNG(id: String, x: Int, y: Int, width: Int, height: Int, data: Data, filter: String, layer: Int?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.image(id: id, x: x, y: y, width: width, height: height, pngData: data, filter: vtgSpriteFilter(filter), layer: layer)
    }

    func vectorTerminalImageJPEG(id: String, x: Int, y: Int, width: Int, height: Int, data: Data, filter: String, layer: Int?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.image(id: id, x: x, y: y, width: width, height: height, jpegData: data, filter: vtgSpriteFilter(filter), layer: layer)
    }

    func vectorTerminalUploadSpritePNG(id: String, width: Int, height: Int, data: Data, filter: String) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.uploadSprite(id: id, width: width, height: height, pngData: data, filter: vtgSpriteFilter(filter))
    }

    func vectorTerminalUploadSpriteJPEG(id: String, width: Int, height: Int, data: Data, filter: String) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.uploadSprite(id: id, width: width, height: height, jpegData: data, filter: vtgSpriteFilter(filter))
    }

    func vectorTerminalUploadVectorSprite(id: String, width: Int, height: Int, path: String, stroke: String?, fill: String?, lineWidth: Double) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.uploadVectorSprite(id: id, width: width, height: height, path: path, stroke: vtgColor(stroke), fill: vtgColor(fill), lineWidth: lineWidth)
    }

    func vectorTerminalUploadIndexedSprite(id: String, width: Int, height: Int, pixels: [Int], palette: [String], transparentIndex: Int?, filter: String) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.uploadIndexedSprite(id: id, width: width, height: height, pixels: pixels, palette: palette.map { VTGColor($0) }, transparentIndex: transparentIndex, filter: vtgSpriteFilter(filter))
    }

    func vectorTerminalSprite(id: String, imageID: String, x: Int, y: Int, rotation: Double, scale: Double, anchorX: Double, anchorY: Double, layer: Int?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.sprite(id: id, imageID: imageID, x: x, y: y, rotation: rotation, scale: scale, anchorX: anchorX, anchorY: anchorY, layer: layer)
    }

    func vectorTerminalMoveSprite(id: String, x: Int, y: Int) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.moveSprite(id: id, x: x, y: y)
    }

    func vectorTerminalRotateSprite(id: String, rotation: Double) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.rotateSprite(id: id, rotation: rotation)
    }

    func vectorTerminalAnchorSprite(id: String, anchorX: Double, anchorY: Double) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.anchorSprite(id: id, anchorX: anchorX, anchorY: anchorY)
    }

    func vectorTerminalTransformSprite(id: String, x: Int, y: Int, rotation: Double, scale: Double, anchorX: Double?, anchorY: Double?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.transformSprite(id: id, x: x, y: y, rotation: rotation, scale: scale, anchorX: anchorX, anchorY: anchorY)
    }

    func vectorTerminalRemoveSprite(id: String) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.removeSprite(id: id)
    }

    func vectorTerminalClearSprites() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.clearSprites()
    }

    func vectorTerminalSetDefaultLayer(_ layer: Int) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.setDefaultLayer(layer)
    }

    func vectorTerminalSetLayer(id: String, layer: Int) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.setLayer(id: id, layer: layer)
    }

    func vectorTerminalScrollLayer(_ layer: Int, x: Int, y: Int) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.scrollLayer(layer, x: x, y: y)
    }

    func vectorTerminalSetLayerAlpha(_ layer: Int, alpha: Double) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.setLayerAlpha(layer, alpha: alpha)
    }

    func vectorTerminalClipLayer(_ layer: Int, x: Int, y: Int, width: Int, height: Int) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.clipLayer(layer, x: x, y: y, width: width, height: height)
    }

    func vectorTerminalClearLayerClip(_ layer: Int) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.clearLayerClip(layer)
    }

    func vectorTerminalSetViewportMode(layer: Int, width: Int, height: Int, scale: String) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.setViewportMode(layer: layer, width: width, height: height, scale: VTGViewportScaleMode(rawValue: scale.lowercased()) ?? .fit)
    }

    func vectorTerminalClearViewportMode(layer: Int) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.clearViewportMode(layer: layer)
    }

    func vectorTerminalSetViewportScale(layer: Int, scale: Double, x: Int, y: Int) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.setViewportScale(layer: layer, scale: scale, x: x, y: y)
    }

    func vectorTerminalHitRegion(id: String, x: Int, y: Int, width: Int, height: Int, layer: Int?, target: String?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.hitRegion(id: id, x: x, y: y, width: width, height: height, layer: layer, target: target)
    }

    func vectorTerminalClearHitRegions(id: String?, layer: Int?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.clearHitRegions(id: id, layer: layer)
    }

    func vectorTerminalStartFrame(id: String, timeoutMilliseconds: Int) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.startFrame(id: id, timeoutMilliseconds: timeoutMilliseconds)
    }

    func vectorTerminalEndFrame(id: String) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.endFrame(id: id)
    }

    func vectorTerminalCancelFrame(id: String) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.cancelFrame(id: id)
    }

    func vectorTerminalQueryCapabilities(timeoutMilliseconds: Int) throws -> String? {
        try requireVectorTerminal()
        guard timeoutMilliseconds > 0 else { return nil }
        return vtgCanvas.queryCapabilities(timeoutMilliseconds: timeoutMilliseconds)
    }

    func vectorTerminalQueryCapabilityInfo(timeoutMilliseconds: Int) throws -> String? {
        try requireVectorTerminal()
        guard timeoutMilliseconds > 0 else { return nil }
        return capabilityJSON(vtgCanvas.queryCapabilityInfo(timeoutMilliseconds: timeoutMilliseconds))
    }

    func vectorTerminalQueryCanvas(timeoutMilliseconds: Int) throws -> BASICVectorTerminalCanvasSnapshot? {
        try requireVectorTerminal()
        guard timeoutMilliseconds > 0 else { return liveVTGCanvasSize }
        return updateLiveVTGCanvasSize(vtgCanvas.queryCanvas(timeoutMilliseconds: timeoutMilliseconds)) ?? liveVTGCanvasSize
    }

    func vectorTerminalQuerySize(timeoutMilliseconds: Int) throws -> BASICVectorTerminalCanvasSnapshot? {
        try requireVectorTerminal()
        guard timeoutMilliseconds > 0 else { return liveVTGCanvasSize }
        return updateLiveVTGCanvasSize(vtgCanvas.querySize(timeoutMilliseconds: timeoutMilliseconds)) ?? liveVTGCanvasSize
    }

    func vectorTerminalQueryCurrentCanvas(timeoutMilliseconds: Int) throws -> BASICVectorTerminalCanvasSnapshot? {
        try requireVectorTerminal()
        guard timeoutMilliseconds > 0 else { return liveVTGCanvasSize }
        return updateLiveVTGCanvasSize(vtgCanvas.queryCurrentCanvas(timeoutMilliseconds: timeoutMilliseconds)) ?? liveVTGCanvasSize
    }

    func vectorTerminalQueryTerminalCellSize() throws -> BASICVectorTerminalCellSnapshot? {
        try requireVectorTerminal()
        let cellSize = vtgCanvas.queryTerminalWSize(timeoutMilliseconds: 750)
        return BASICVectorTerminalCellSnapshot(
            columns: screenColumns(),
            rows: screenRows(),
            width: cellSize?.width,
            height: cellSize?.height
        )
    }

    func vectorTerminalEnableResizeEvents() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.enableResizeEvents()
    }

    func vectorTerminalDisableResizeEvents() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.disableResizeEvents()
    }

    func vectorTerminalEnableMouseReporting(mode: String?) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        if let mode {
            vtgCanvas.enableMouseReporting(mode: mode)
        } else {
            vtgCanvas.enableMouseReporting()
        }
        enableANSIMouseMotionReporting()
    }

    func vectorTerminalDisableMouseReporting() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.disableMouseReporting()
        disableANSIMouseMotionReporting()
    }

    func vectorTerminalReadEvent(timeoutMilliseconds: Int) throws -> String? {
        try requireVectorTerminal()
        return vtgCanvas.readEvent(timeoutMilliseconds: timeoutMilliseconds).map { "\($0)" }
    }

    func vectorTerminalEnterAlternateScreen() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.enterAlternateScreen()
    }

    func vectorTerminalLeaveAlternateScreen() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.leaveAlternateScreen()
    }

    func vectorTerminalEnableBracketedPaste() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.enableBracketedPaste()
    }

    func vectorTerminalDisableBracketedPaste() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.disableBracketedPaste()
    }

    func vectorTerminalEnableFocusReporting() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.enableFocusReporting()
    }

    func vectorTerminalDisableFocusReporting() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.disableFocusReporting()
    }

    func vectorTerminalClearScreen() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.clearScreen()
    }

    func vectorTerminalClearScrollbackAndScreen() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.clearScrollbackAndScreen()
    }

    func vectorTerminalClearLine() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.clearLine()
    }

    func vectorTerminalClearToEndOfLine() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.clearToEndOfLine()
    }

    func vectorTerminalWriteText(_ value: String) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.writeText(value)
    }

    func vectorTerminalMoveCursor(row: Int, column: Int) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.moveCursor(row: row, column: column)
    }

    func vectorTerminalSetCursor(row: Int, column: Int) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.setCursor(row: row, column: column)
    }

    func vectorTerminalMoveCursorUp(_ count: Int) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.moveCursorUp(count)
    }

    func vectorTerminalMoveCursorDown(_ count: Int) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.moveCursorDown(count)
    }

    func vectorTerminalMoveCursorForward(_ count: Int) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.moveCursorForward(count)
    }

    func vectorTerminalMoveCursorBackward(_ count: Int) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.moveCursorBackward(count)
    }

    func vectorTerminalSaveCursor() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.saveCursor()
    }

    func vectorTerminalRestoreCursor() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.restoreCursor()
    }

    func vectorTerminalHideCursor() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.hideCursor()
    }

    func vectorTerminalShowCursor() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.showCursor()
    }

    func vectorTerminalResetTextAttributes() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.resetTextAttributes()
    }

    func vectorTerminalBold(_ enabled: Bool) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.bold(enabled)
    }

    func vectorTerminalUnderline(_ enabled: Bool) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.underline(enabled)
    }

    func vectorTerminalInverse(_ enabled: Bool) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.inverse(enabled)
    }

    func vectorTerminalSetForeground(_ color: String, bright: Bool) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.setForeground(try ansiColor(color), bright: bright)
    }

    func vectorTerminalSetBackground(_ color: String, bright: Bool) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.setBackground(try ansiColor(color), bright: bright)
    }

    func vectorTerminalSetForegroundRGB(red: Int, green: Int, blue: Int) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.setForegroundRGB(red: red, green: green, blue: blue)
    }

    func vectorTerminalSetBackgroundRGB(red: Int, green: Int, blue: Int) throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.setBackgroundRGB(red: red, green: green, blue: blue)
    }

    func vectorTerminalBell() throws {
        try requireVectorTerminal()
        didUseVectorTerminal = true
        vtgCanvas.bell()
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
let graphicsPolicy: ShellGraphicsPolicy
do {
    graphicsPolicy = try ShellGraphicsPolicy.parse(arguments: &arguments)
} catch let error as BASICError {
    Swift.print(error.description)
    exit(1)
} catch {
    Swift.print("Error: \(error.localizedDescription)")
    exit(1)
}

let host = ConsoleHost(graphicsPolicy: graphicsPolicy)
defer {
    host.clearVectorTerminalOnExit()
}
let shellExecutionLane = BASICWorkerLane(label: "AIBasic.Shell.Execution")
let shellExecutionControl = BASICExecutionControl()
let shellInterruptBridge = ShellInterruptBridge()
let session = BASICSession(
    host: host,
    promptTemplate: BASICPromptTemplateStore.load(default: BASICSession.defaultPromptTemplate)
)
session.shellModeEnabled = true
session.stringSubstitutionEnabled = true
host.attachSession(session)
host.attachExecutionControl(shellExecutionControl)
session.foregroundRunLane = shellExecutionLane
session.foregroundExecutionControl = shellExecutionControl
session.stopsForegroundProgramOnBreak = true

shellInterruptBridge.start(executionControl: shellExecutionControl)

@MainActor
func finish(_ code: Int32) -> Never {
    host.clearVectorTerminalOnExit()
    exit(code)
}

@MainActor
func drainSessionEventLoop() {
    _ = session.eventLoop.runUntilIdle()
    host.finishVectorTerminalForegroundRun()
    ShellLineEditor.shared.drainPendingVectorTerminalResponses()
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

func isRunCommand(_ input: String) -> Bool {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let uppercased = trimmed.uppercased()
    guard uppercased == "RUN" || uppercased.hasPrefix("RUN ") else { return false }
    let rest = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
    return rest.isEmpty || Int(rest) != nil
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

if arguments.first == "--cls" {
    host.clearEverything()
    finish(0)
}

if let scriptPath = arguments.first {
    do {
        session.program.loadSource(try host.loadTextFile(path: scriptPath), fileName: scriptPath)
        if printDiagnosticsIfNeeded() {
            finish(1)
        }
        try session.runProgramInForeground(executionControl: shellExecutionControl)
        drainSessionEventLoop()
        finish(0)
    } catch let error as BASICError {
        host.prepareToPrintRunResult()
        host.printLine(error.description)
        finish(1)
    } catch {
        host.prepareToPrintRunResult()
        host.printLine("Error: \(error.localizedDescription)")
        finish(1)
    }
}

print("BASICShell")
print("Type HELP for commands. Type QUIT to exit.")

var shellExitCode: Int32 = 0
while true {
    ShellLineEditor.shared.setAliasCompletionWords(session.aliasNames)
    ShellLineEditor.shared.setIncludesExternalCommandCompletions(session.shellModeEnabled)
    guard let line = host.readLine(prompt: session.prompt) else { break }
    if line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "EDIT" {
        runTermKitEditor()
        drainSessionEventLoop()
        continue
    }
    if isRunCommand(line), printDiagnosticsIfNeeded() {
        continue
    }
    let oldPromptTemplate = session.promptTemplate
    let shouldContinue = session.submit(line)
    if session.promptTemplate != oldPromptTemplate {
        BASICPromptTemplateStore.save(session.promptTemplate)
    }
    drainSessionEventLoop()
    if !shouldContinue {
        shellExitCode = Int32(session.requestedExitStatus)
        break
    }
}

finish(shellExitCode)
