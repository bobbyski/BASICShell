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
        lines = ProgramLine.parse(source, fileName: fileName, isImported: false)
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
        ProgramLine.parse(source, fileName: fileName, isImported: true)
    }

    private static let ansiReset = "\u{001B}[0m"
    private static let ansiKeyword = "\u{001B}[38;5;39m"
    private static let ansiString = "\u{001B}[38;5;215m"
    private static let ansiComment = "\u{001B}[38;5;71m"
    private static let ansiNumber = "\u{001B}[38;5;141m"

    // The whole vocabulary, not a 58-word subset of it. `LIST` used to print
    // `CLS`, `OPEN`, `PSET` and every builtin in the plain-text colour while
    // colouring `PRINT` — which reads as though the interpreter did not know
    // its own language.
    private static let listingKeywords: Set<String> = BASICKeywords.all


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
