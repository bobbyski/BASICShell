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

        let lineRecords = joinContinuationLines(
            sourceLines.enumerated().map { (lineNumber: $0.offset + 1 + sourceLineOffset, source: $0.element) }
        )

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

    private static func colorizedListingLine(_ source: String) -> String {
        var output = ""
        var index = source.startIndex
        var atLineStart = true
        var previousWasIdentifier = false

        func appendComment(from commentStart: String.Index) {
            output += ansiComment + source[commentStart...] + ansiReset
            index = source.endIndex
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
            if character == "'" {
                appendComment(from: index)
                break
            }
            if character == "/", source.index(after: index) < source.endIndex, source[source.index(after: index)] == "/" {
                appendComment(from: index)
                break
            }
            if character == "\"" {
                let start = index
                index = source.index(after: index)
                while index < source.endIndex {
                    let current = source[index]
                    index = source.index(after: index)
                    if current == "\"" { break }
                }
                output += ansiString + source[start..<index] + ansiReset
                atLineStart = false
                previousWasIdentifier = false
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
