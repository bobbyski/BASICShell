import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct ProgramLine {
    public let number: Int?
    public var source: String
    public var fileName: String?
    public var sourceLineNumber: Int?
    public var isImported: Bool

    /// Creates a value from its parts.
    public init(number: Int?, source: String, fileName: String?, sourceLineNumber: Int?, isImported: Bool) {
        self.number = number
        self.source = source
        self.fileName = fileName
        self.sourceLineNumber = sourceLineNumber
        self.isImported = isImported
    }
}

extension ProgramLine {
    /// Splits source text into program lines.
    ///
    /// Handles the `#!` shebang, `\` continuation lines, triple-quoted
    /// strings spanning lines, blank-line removal, and leading line numbers.
    /// Both the interpreter (`BASICProgram`) and the compiler load source
    /// through this, so "line 12" means the same thing to both.
    public static func parse(_ source: String, fileName: String?, isImported: Bool) -> [ProgramLine] {
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

    static func joinContinuationLines(_ sourceLines: [(lineNumber: Int, source: String)]) -> [(lineNumber: Int, source: String)] {
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

    static func joinTripleQuotedLines(_ sourceLines: [(lineNumber: Int, source: String)]) -> [(lineNumber: Int, source: String)] {
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

    static func removingTrailingContinuation(from line: String) -> String? {
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

    /// Splits a leading line number off a line, or returns nil when the line
    /// has none.
    public static func splitNumberedLine(_ source: String) -> (number: Int, source: String)? {
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
}

extension Bool {
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
