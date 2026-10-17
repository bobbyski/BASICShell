import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct Lexer {
    private let source: String
    private var index: String.Index
    private var atStatementStart = true
    /// Whether the program asked to be read as a 1970s listing (OPTION CLASSIC).
    private let classic: Bool
    /// Whether the token just produced was a number, which is the only place a
    /// crunched keyword can appear.
    private var afterNumber = false

    public init(source: String, classic: Bool = false) {
        self.source = source
        self.index = source.startIndex
        self.classic = classic
    }

    public mutating func tokenize() throws -> [LexedToken] {
        var tokens: [LexedToken] = []
        while let token = try nextToken() {
            tokens.append(token)
            if case .number = token.token { afterNumber = true } else { afterNumber = false }
            if token.token == .eof { break }
        }
        return tokens
    }

    private mutating func nextToken() throws -> LexedToken? {
        skipWhitespace()
        let column = self.column
        guard index < source.endIndex else { return LexedToken(token: .eof, column: column) }
        let character = source[index]

        if startsComment(character) {
            index = source.endIndex
            return emit(.eof, column: column)
        }
        if character.isNumber || (character == "." && nextCharacter?.isNumber == true) {
            return try scanNumber()
        }
        if character == "$", let nextCharacter, Self.stringDelimiters.contains(nextCharacter) {
            advance()
            return try scanString(delimiter: nextCharacter, forceInterpolated: true, column: column)
        }
        if Self.stringDelimiters.contains(character), !(character == "'" && startsComment(character)) {
            return try scanString(delimiter: character, forceInterpolated: false, column: column)
        }
        if character.isLetter {
            return scanIdentifier()
        }
        // `#2026-09-25#` and friends (DB19). The language has used `#` for file
        // numbers since the 1970s, so this only claims the character when what
        // follows really is a date, a time or both, closed by another `#` --
        // `PRINT #1: PRINT #2` has letters in between and stays two file
        // numbers. Checked by *parsing* the candidate rather than by pattern,
        // so the lexer and the evaluator can never disagree about what one is.
        if character == "#", let literal = temporalLiteralAhead() {
            for _ in 0..<(literal.count + 2) { advance() }
            return emit(.temporal(literal), column: column)
        }

        advance()
        let token: Token
        switch character {
        case ",": token = .comma
        case ";": token = .semicolon
        case ":": token = .colon
        case "#": token = .hash
        case "=": token = .equals
        case "+": token = .plus
        case "-": token = .minus
        case "*": token = .star
        case "/": token = .slash
        case "^": token = .caret
        case "\\": token = .backslash
        case ".": token = .dot
        case "(": token = .leftParen
        case ")": token = .rightParen
        case "{": token = .leftBrace
        case "}": token = .rightBrace
        case "<":
            if match("=") { token = .lessEqual }
            else if match(">") { token = .notEqual }
            else { token = .less }
        case ">":
            if match("=") { token = .greaterEqual }
            else { token = .greater }
        default:
            throw BASICError.contextualSyntax(message: "Unexpected character \(character)", source: source, column: column)
        }
        return emit(token, column: column)
    }

    /// The body of a `#…#` literal starting here, or nil.
    ///
    /// Bounded, because an unclosed `#` must not make the lexer walk the rest of
    /// the line looking for one: a date is at most `yyyy-MM-dd HH:mm:ss.fffffffff`.
    private func temporalLiteralAhead() -> String? {
        var cursor = source.index(after: index)
        var body = ""
        while cursor < source.endIndex, body.count <= 32 {
            let character = source[cursor]
            if character == "#" {
                return BASICTemporalLiteral.isLiteral(body) ? body : nil
            }
            guard character.isNumber || character == "-" || character == ":"
                    || character == "." || character == " " || character == "T" else {
                return nil
            }
            body.append(character)
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private mutating func scanNumber() throws -> LexedToken {
        let start = index
        let column = self.column
        var seenDot = false
        while index < source.endIndex {
            let character = source[index]
            if character == "." {
                guard !seenDot else { break }
                seenDot = true
            } else if !character.isNumber {
                break
            }
            advance()
        }
        let text = String(source[start..<index])
        // `123.45D` is an exact decimal (DB19). Only when nothing identifier-ish
        // follows, so `123Dog` stays the error it always was -- and a bare
        // `123.45` stays a DOUBLE, which is what every existing program means.
        if index < source.endIndex, source[index] == "D" || source[index] == "d" {
            let afterSuffix = source.index(after: index)
            let next = afterSuffix < source.endIndex ? source[afterSuffix] : " "
            if !next.isLetter && !next.isNumber && next != "_" {
                advance()
                return emit(.decimal(text), column: column)
            }
        }
        guard let value = Double(text) else {
            throw BASICError.contextualSyntax(message: "Invalid number \(text)", source: source, column: column)
        }
        return emit(.number(value), column: column)
    }

    private mutating func scanString(delimiter: Character, forceInterpolated: Bool, column: Int) throws -> LexedToken {
        let isTripleQuoted = delimiter == "\"" && hasTripleQuote(at: index)
        if isTripleQuoted {
            advance()
            advance()
            advance()
            let start = index
            while index < source.endIndex, !hasTripleQuote(at: index) {
                advance()
            }
            guard index < source.endIndex else {
                throw BASICError.contextualSyntax(message: "Unterminated string", source: source, column: column)
            }
            let value = String(source[start..<index])
            advance()
            advance()
            advance()
            return emit(forceInterpolated ? .interpolatedString(value) : .string(value), column: column)
        }

        advance()
        let start = index
        while index < source.endIndex, source[index] != delimiter {
            advance()
        }
        guard index < source.endIndex else {
            throw BASICError.contextualSyntax(message: "Unterminated string", source: source, column: column)
        }
        let value = String(source[start..<index])
        advance()
        return emit(forceInterpolated ? .interpolatedString(value) : .string(value), column: column)
    }

    /// The keyword `name` begins with, when a 1970s listing crunched one onto
    /// the end of a number. `TOQ1` is `TO` and `Q1`; `TOTAL` is just `TOTAL`,
    /// because a keyword only counts when something follows it that could
    /// start an operand.
    static func crunchedKeyword(at name: String) -> String? {
        let upper = name.uppercased()
        for keyword in BASICClassicMode.crunchable where upper.hasPrefix(keyword) {
            let rest = upper.dropFirst(keyword.count)
            guard !rest.isEmpty else { return nil }   // the whole word *is* the keyword
            return keyword
        }
        return nil
    }

    private mutating func scanIdentifier() -> LexedToken {
        let start = index
        let column = self.column
        while index < source.endIndex, source[index].isLetter || source[index].isNumber || source[index] == "_" {
            advance()
        }
        if index < source.endIndex, source[index] == "$" || source[index] == "%" || source[index] == "#" {
            advance()
        }
        var name = String(source[start..<index])
        // `1TO3` lexes as the number 1 and then the identifier `TO3`. Under
        // OPTION CLASSIC, split the keyword back off -- but only here, right
        // after a number, because `TOTAL` is a perfectly good name and only a
        // 1970s listing writes `TO` with no space in front of it.
        if classic, afterNumber, let keyword = Self.crunchedKeyword(at: name) {
            index = source.index(start, offsetBy: keyword.count)
            name = keyword
        }
        if atStatementStart, name.uppercased() == "REM" {
            index = source.endIndex
        }
        return emit(.identifier(name), column: column)
    }

    private mutating func skipWhitespace() {
        while index < source.endIndex, source[index].isWhitespace {
            advance()
        }
    }

    private mutating func match(_ expected: Character) -> Bool {
        guard index < source.endIndex, source[index] == expected else { return false }
        advance()
        return true
    }

    private mutating func advance() {
        index = source.index(after: index)
    }

    private mutating func emit(_ token: Token, column: Int) -> LexedToken {
        if token == .colon {
            atStatementStart = true
        } else if token != .eof {
            atStatementStart = false
        }
        return LexedToken(token: token, column: column)
    }

    private func startsComment(_ character: Character) -> Bool {
        if character == "'" {
            return atStatementStart || !hasClosingQuote(delimiter: "'")
        }
        if character == "#" {
            return isAtPhysicalLineStart
        }
        if character == "/" {
            let next = source.index(after: index)
            return next < source.endIndex && source[next] == "/"
        }
        return false
    }

    private var isAtPhysicalLineStart: Bool {
        source[..<index].allSatisfy(\.isWhitespace)
    }

    private var nextCharacter: Character? {
        let next = source.index(after: index)
        return next < source.endIndex ? source[next] : nil
    }

    private static let stringDelimiters: Set<Character> = ["\"", "'", "`"]

    private func hasClosingQuote(delimiter: Character) -> Bool {
        var cursor = source.index(after: index)
        while cursor < source.endIndex {
            if source[cursor] == delimiter {
                return true
            }
            cursor = source.index(after: cursor)
        }
        return false
    }

    private func hasTripleQuote(at position: String.Index) -> Bool {
        guard position < source.endIndex, source[position] == "\"" else { return false }
        let second = source.index(after: position)
        guard second < source.endIndex, source[second] == "\"" else { return false }
        let third = source.index(after: second)
        return third < source.endIndex && source[third] == "\""
    }

    private var column: Int {
        source.distance(from: source.startIndex, to: index)
    }
}
