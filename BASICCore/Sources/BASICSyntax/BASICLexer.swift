import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct Lexer {
    private let source: String
    private var index: String.Index
    private var atStatementStart = true

    public init(source: String) {
        self.source = source
        self.index = source.startIndex
    }

    public mutating func tokenize() throws -> [LexedToken] {
        var tokens: [LexedToken] = []
        while let token = try nextToken() {
            tokens.append(token)
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

    private mutating func scanIdentifier() -> LexedToken {
        let start = index
        let column = self.column
        while index < source.endIndex, source[index].isLetter || source[index].isNumber || source[index] == "_" {
            advance()
        }
        if index < source.endIndex, source[index] == "$" || source[index] == "%" || source[index] == "#" {
            advance()
        }
        let name = String(source[start..<index])
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
