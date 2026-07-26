import Foundation
#if canImport(Darwin)
import Darwin
#endif

public final class BASICProgram: @unchecked Sendable {
    private var lines: [ProgramLine] = []

    /// Creates an empty program.
    public init() {}

    /// Whether the program contains no source lines.
    public var isEmpty: Bool { lines.isEmpty }

    /// Adds, replaces, or deletes a numbered source line.
    public func setLine(number: Int, source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            lines.removeAll { $0.number == number }
        } else {
            if let index = lines.firstIndex(where: { $0.number == number }) {
                lines[index].source = source
            } else {
                lines.append(ProgramLine(number: number, source: source, fileName: nil, sourceLineNumber: nil, isImported: false))
            }
            lines.sort { ($0.number ?? Int.max) < ($1.number ?? Int.max) }
        }
    }

    /// Replaces the program with line-numbered or line-number-free source.
    public func loadSource(_ source: String, fileName: String? = nil) {
        lines = Self.parseLines(from: source, fileName: fileName, isImported: false)
    }

    /// Removes all program lines.
    public func clear() {
        lines.removeAll()
    }

    /// Returns a LIST-style rendering of the current program.
    public func listing(begin: Int? = nil, end: Int? = nil, colorized: Bool = false) -> String {
        orderedLines.filter { line in
            guard begin != nil || end != nil else { return true }
            guard let number = line.number else { return false }
            if let begin, number < begin { return false }
            if let end, number > end { return false }
            return true
        }.map { line in
            let source = colorized ? Self.colorizedListingLine(line.source) : line.source
            if let number = line.number {
                return "\(colorized ? Self.ansiNumber : "")\(number)\(colorized ? Self.ansiReset : "") \(source)"
            }
            return source
        }.joined(separator: "\n")
    }

    /// Deletes numbered program lines in the optional inclusive range.
    public func deleteLines(begin: Int? = nil, end: Int? = nil) {
        lines.removeAll { line in
            guard let number = line.number, !line.isImported else { return false }
            if let begin, number < begin { return false }
            if let end, number > end { return false }
            return true
        }
    }

    /// Renumbers numbered program lines and updates common line-number references.
    public func renumber(start: Int = 10, oldStart: Int? = nil, step: Int = 10) throws {
        guard start > 0 else { throw BASICError.runtime("RENUM start line must be positive") }
        guard step > 0 else { throw BASICError.runtime("RENUM increment must be positive") }

        let targets = lines
            .compactMap { line -> Int? in
                guard let number = line.number, !line.isImported else { return nil }
                if let oldStart, number < oldStart { return nil }
                return number
            }
            .sorted()
        guard !targets.isEmpty else { return }

        var next = start
        var mapping: [Int: Int] = [:]
        for oldNumber in targets {
            guard mapping[oldNumber] == nil else { continue }
            mapping[oldNumber] = next
            next += step
        }

        let unchangedNumbers = Set(lines.compactMap { line -> Int? in
            guard let number = line.number, !mapping.keys.contains(number) else { return nil }
            return number
        })
        let newNumbers = Set(mapping.values)
        if let collision = newNumbers.intersection(unchangedNumbers).sorted().first {
            throw BASICError.runtime("RENUM would collide with existing line \(collision)")
        }

        for index in lines.indices {
            if let number = lines[index].number, let newNumber = mapping[number] {
                lines[index] = ProgramLine(
                    number: newNumber,
                    source: Self.renumberedReferences(in: lines[index].source, mapping: mapping),
                    fileName: lines[index].fileName,
                    sourceLineNumber: lines[index].sourceLineNumber,
                    isImported: lines[index].isImported
                )
            } else {
                lines[index].source = Self.renumberedReferences(in: lines[index].source, mapping: mapping)
            }
        }
        lines.sort { ($0.number ?? Int.max) < ($1.number ?? Int.max) }
    }

    /// Program lines in execution order with source metadata.
    public var orderedLines: [(number: Int?, source: String, fileName: String?, sourceLineNumber: Int?, isImported: Bool)] {
        lines.map { ($0.number, $0.source, $0.fileName, $0.sourceLineNumber, $0.isImported) }
    }

    static func importedLines(from source: String, fileName: String) -> [ProgramLine] {
        parseLines(from: source, fileName: fileName, isImported: true)
    }

    private static func splitNumberedLine(_ source: String) -> (number: Int, source: String)? {
        var digits = ""
        var index = source.startIndex
        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
        while index < source.endIndex, source[index].isNumber {
            digits.append(source[index])
            index = source.index(after: index)
        }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        if index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
        let rest = String(source[index...])
        return (number, rest)
    }

    private static func parseLines(from source: String, fileName: String?, isImported: Bool) -> [ProgramLine] {
        var sourceLines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var sourceLineOffset = 0
        if let firstLine = sourceLines.first,
           firstLine.trimmingCharacters(in: .whitespaces).hasPrefix("#!") {
            sourceLines.removeFirst()
            sourceLineOffset = 1
        }

        let physicalLineRecords = sourceLines.enumerated().map {
            (lineNumber: $0.offset + 1 + sourceLineOffset, source: $0.element)
        }
        let lineRecords = joinContinuationLines(joinTripleQuotedLines(physicalLineRecords))

        return lineRecords
            .filter { !$0.source.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { record in
                if let numbered = splitNumberedLine(record.source) {
                    return ProgramLine(number: numbered.number, source: numbered.source, fileName: fileName, sourceLineNumber: record.lineNumber, isImported: isImported)
                }
                return ProgramLine(number: nil, source: record.source, fileName: fileName, sourceLineNumber: record.lineNumber, isImported: isImported)
            }
    }

    private static func joinContinuationLines(_ sourceLines: [(lineNumber: Int, source: String)]) -> [(lineNumber: Int, source: String)] {
        var joinedLines: [(lineNumber: Int, source: String)] = []
        var pending: (lineNumber: Int, source: String)?

        for sourceLine in sourceLines {
            let line = sourceLine.source
            let combined = [pending?.source, line]
                .compactMap { $0 }
                .joined(separator: pending == nil ? "" : " ")

            if let continued = removingTrailingContinuation(from: combined) {
                pending = (lineNumber: pending?.lineNumber ?? sourceLine.lineNumber, source: continued)
            } else {
                joinedLines.append((lineNumber: pending?.lineNumber ?? sourceLine.lineNumber, source: combined))
                pending = nil
            }
        }

        if let pending {
            joinedLines.append(pending)
        }

        return joinedLines
    }

    private static func joinTripleQuotedLines(_ sourceLines: [(lineNumber: Int, source: String)]) -> [(lineNumber: Int, source: String)] {
        var joinedLines: [(lineNumber: Int, source: String)] = []
        var pending: (lineNumber: Int, source: String)?
        var insideTripleQuotedString = false

        for sourceLine in sourceLines {
            if var pendingRecord = pending {
                pendingRecord.source += "\n" + sourceLine.source
                insideTripleQuotedString.toggleIfNeeded(forTripleQuotesIn: sourceLine.source)
                if insideTripleQuotedString {
                    pending = pendingRecord
                } else {
                    joinedLines.append(pendingRecord)
                    pending = nil
                }
                continue
            }

            var isInside = false
            isInside.toggleIfNeeded(forTripleQuotesIn: sourceLine.source)
            if isInside {
                insideTripleQuotedString = true
                pending = sourceLine
            } else {
                joinedLines.append(sourceLine)
            }
        }

        if let pending {
            joinedLines.append(pending)
        }

        return joinedLines
    }

    private static func removingTrailingContinuation(from line: String) -> String? {
        var index = line.endIndex
        while index > line.startIndex {
            let previous = line.index(before: index)
            if line[previous].isWhitespace {
                index = previous
                continue
            }
            guard line[previous] == "\\" else { return nil }
            return String(line[..<previous]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static let ansiReset = "\u{001B}[0m"
    private static let ansiKeyword = "\u{001B}[38;5;39m"
    private static let ansiString = "\u{001B}[38;5;215m"
    private static let ansiComment = "\u{001B}[38;5;71m"
    private static let ansiNumber = "\u{001B}[38;5;141m"

    private static let listingKeywords: Set<String> = [
        "AS", "ASYNC", "AWAIT", "CASE", "CLASS", "CLOSE", "COLOR", "DATA", "DIM", "ELSE", "ELSEIF",
        "END", "EXIT", "FOR", "FUNCTION", "GLOBAL", "GOSUB", "GOTO", "IF", "IMPORT", "INPUT", "INTERFACE",
        "JOIN", "LET", "LINE", "LIST", "LOCAL", "LOG", "MODULE", "NEXT", "ON", "OPEN", "OPTION", "PRINT",
        "PRIVATE", "PROTECTED", "PUBLIC", "READ", "REM", "RESTORE", "RETURN", "RUN", "SAVE", "SELECT",
        "STEP", "SYSTEM", "THEN", "TO", "TYPE", "USING", "VIRTUAL", "VOID", "YIELD"
    ]

    private static let lineReferenceKeywords: Set<String> = [
        "GOTO", "GOSUB", "THEN", "ELSE", "RESTORE", "RESUME", "RETURN", "RUN", "ERL"
    ]

    private static func renumberedReferences(in source: String, mapping: [Int: Int]) -> String {
        var output = ""
        var index = source.startIndex
        var previousWord: String?
        var rewriteCommaSeparatedReferences = false

        func appendComment(from commentStart: String.Index) {
            output += source[commentStart...]
            index = source.endIndex
        }

        func hasTripleQuote(at position: String.Index) -> Bool {
            guard position < source.endIndex, source[position] == "\"" else { return false }
            let second = source.index(after: position)
            guard second < source.endIndex, source[second] == "\"" else { return false }
            let third = source.index(after: second)
            return third < source.endIndex && source[third] == "\""
        }

        func hasClosingQuote(from quoteStart: String.Index, delimiter: Character) -> Bool {
            var cursor = source.index(after: quoteStart)
            while cursor < source.endIndex {
                if source[cursor] == delimiter {
                    return true
                }
                cursor = source.index(after: cursor)
            }
            return false
        }

        func appendStringLiteral(from literalStart: String.Index, quoteStart: String.Index, delimiter: Character) {
            index = source.index(after: quoteStart)
            if delimiter == "\"", hasTripleQuote(at: quoteStart) {
                index = source.index(quoteStart, offsetBy: 3)
                while index < source.endIndex, !hasTripleQuote(at: index) {
                    index = source.index(after: index)
                }
                if index < source.endIndex {
                    index = source.index(index, offsetBy: 3)
                }
                output += source[literalStart..<index]
                return
            }

            while index < source.endIndex {
                let current = source[index]
                index = source.index(after: index)
                if current == delimiter { break }
            }
            output += source[literalStart..<index]
        }

        while index < source.endIndex {
            let character = source[index]

            if character == "$" {
                let quote = source.index(after: index)
                if quote < source.endIndex, ["\"", "'", "`"].contains(source[quote]) {
                    appendStringLiteral(from: index, quoteStart: quote, delimiter: source[quote])
                    previousWord = nil
                    continue
                }
            }

            if ["\"", "`"].contains(character) {
                appendStringLiteral(from: index, quoteStart: index, delimiter: character)
                previousWord = nil
                continue
            }

            if character == "'" {
                if hasClosingQuote(from: index, delimiter: "'") {
                    appendStringLiteral(from: index, quoteStart: index, delimiter: "'")
                    previousWord = nil
                    continue
                } else {
                    appendComment(from: index)
                    break
                }
            }
            if character == "#", output.trimmingCharacters(in: .whitespaces).isEmpty {
                appendComment(from: index)
                break
            }
            if character == "/", source.index(after: index) < source.endIndex, source[source.index(after: index)] == "/" {
                appendComment(from: index)
                break
            }

            if character.isLetter {
                let start = index
                index = source.index(after: index)
                while index < source.endIndex, source[index].isLetter || source[index].isNumber || source[index] == "$" || source[index] == "_" {
                    index = source.index(after: index)
                }
                let word = String(source[start..<index])
                previousWord = word.uppercased()
                if previousWord == "REM" {
                    output += source[start...]
                    index = source.endIndex
                    break
                }
                if previousWord != "GOTO" && previousWord != "GOSUB" {
                    rewriteCommaSeparatedReferences = false
                }
                output += word
                continue
            }

            if character.isNumber {
                let start = index
                index = source.index(after: index)
                while index < source.endIndex, source[index].isNumber {
                    index = source.index(after: index)
                }
                let text = String(source[start..<index])
                if let number = Int(text),
                   let replacement = mapping[number],
                   (previousWord.map(lineReferenceKeywords.contains) == true || rewriteCommaSeparatedReferences) {
                    output += String(replacement)
                } else {
                    output += text
                }
                if previousWord == "GOTO" || previousWord == "GOSUB" || rewriteCommaSeparatedReferences {
                    rewriteCommaSeparatedReferences = true
                }
                previousWord = nil
                continue
            }

            if character == "," {
                output.append(character)
                previousWord = nil
                index = source.index(after: index)
                continue
            }

            if !character.isWhitespace {
                rewriteCommaSeparatedReferences = false
            }
            output.append(character)
            index = source.index(after: index)
        }

        return output
    }

    private static func colorizedListingLine(_ source: String) -> String {
        var output = ""
        var index = source.startIndex
        var atLineStart = true
        var previousWasIdentifier = false

        func appendComment(from commentStart: String.Index) {
            output += ansiComment + source[commentStart...] + ansiReset
            index = source.endIndex
        }

        func hasTripleQuote(at position: String.Index) -> Bool {
            guard position < source.endIndex, source[position] == "\"" else { return false }
            let second = source.index(after: position)
            guard second < source.endIndex, source[second] == "\"" else { return false }
            let third = source.index(after: second)
            return third < source.endIndex && source[third] == "\""
        }

        func hasClosingQuote(from quoteStart: String.Index, delimiter: Character) -> Bool {
            var cursor = source.index(after: quoteStart)
            while cursor < source.endIndex {
                if source[cursor] == delimiter {
                    return true
                }
                cursor = source.index(after: cursor)
            }
            return false
        }

        func appendStringLiteral(from literalStart: String.Index, quoteStart: String.Index, delimiter: Character) {
            index = source.index(after: quoteStart)
            if delimiter == "\"", hasTripleQuote(at: quoteStart) {
                index = source.index(quoteStart, offsetBy: 3)
                while index < source.endIndex, !hasTripleQuote(at: index) {
                    index = source.index(after: index)
                }
                if index < source.endIndex {
                    index = source.index(index, offsetBy: 3)
                }
                output += ansiString + source[literalStart..<index] + ansiReset
                atLineStart = false
                previousWasIdentifier = false
                return
            }

            while index < source.endIndex {
                let current = source[index]
                index = source.index(after: index)
                if current == delimiter { break }
            }
            output += ansiString + source[literalStart..<index] + ansiReset
            atLineStart = false
            previousWasIdentifier = false
        }

        while index < source.endIndex {
            let character = source[index]
            if character.isWhitespace {
                output.append(character)
                atLineStart = atLineStart && character != "\t" ? atLineStart : false
                index = source.index(after: index)
                previousWasIdentifier = false
                continue
            }
            if atLineStart && character == "#" {
                appendComment(from: index)
                break
            }
            if character == "/", source.index(after: index) < source.endIndex, source[source.index(after: index)] == "/" {
                appendComment(from: index)
                break
            }
            if character == "$" {
                let quote = source.index(after: index)
                if quote < source.endIndex, ["\"", "'", "`"].contains(source[quote]) {
                    appendStringLiteral(from: index, quoteStart: quote, delimiter: source[quote])
                    continue
                }
            }
            if ["\"", "`"].contains(character) {
                appendStringLiteral(from: index, quoteStart: index, delimiter: character)
                continue
            }
            if character == "'" {
                if atLineStart || !hasClosingQuote(from: index, delimiter: "'") {
                    appendComment(from: index)
                    break
                }
                appendStringLiteral(from: index, quoteStart: index, delimiter: "'")
                continue
            }
            if character.isNumber {
                let start = index
                index = source.index(after: index)
                while index < source.endIndex, source[index].isNumber || source[index] == "." {
                    index = source.index(after: index)
                }
                output += ansiNumber + source[start..<index] + ansiReset
                atLineStart = false
                previousWasIdentifier = false
                continue
            }
            if character.isLetter {
                let start = index
                index = source.index(after: index)
                while index < source.endIndex, source[index].isLetter || source[index].isNumber || source[index] == "$" || source[index] == "%" || source[index] == "#" {
                    index = source.index(after: index)
                }
                let word = String(source[start..<index])
                let uppercased = word.uppercased()
                if uppercased == "REM" && !previousWasIdentifier {
                    output += ansiKeyword + word + ansiReset
                    if index < source.endIndex {
                        output += ansiComment + source[index...] + ansiReset
                    }
                    break
                }
                if listingKeywords.contains(uppercased) {
                    output += ansiKeyword + word + ansiReset
                } else {
                    output += word
                }
                atLineStart = false
                previousWasIdentifier = true
                continue
            }
            output.append(character)
            atLineStart = false
            previousWasIdentifier = false
            index = source.index(after: index)
        }
        return output + ansiReset
    }
}

private extension Bool {
    mutating func toggleIfNeeded(forTripleQuotesIn source: String) {
        var index = source.startIndex
        while index < source.endIndex {
            guard source[index] == "\"" else {
                index = source.index(after: index)
                continue
            }
            let second = source.index(after: index)
            guard second < source.endIndex, source[second] == "\"" else {
                index = second
                continue
            }
            let third = source.index(after: second)
            guard third < source.endIndex, source[third] == "\"" else {
                index = third
                continue
            }
            toggle()
            index = source.index(after: third)
        }
    }
}
