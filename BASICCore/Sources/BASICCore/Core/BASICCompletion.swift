import Foundation

public struct BASICCompletionContext: Equatable, Sendable {
    public let token: String
    public let startOffset: Int
    public let isCommandPosition: Bool

    public init(token: String, startOffset: Int, isCommandPosition: Bool) {
        self.token = token
        self.startOffset = startOffset
        self.isCommandPosition = isCommandPosition
    }
}

public enum BASICCompletionEngine {
    public static let shellBuiltinWords = [
        "alias", "cat", "cd", "clear", "dirs", "edit", "exec", "exit", "export", "files",
        "help", "history", "load", "ls", "new", "pipe", "popd", "prompt", "pushd", "pwd",
        "quit", "run", "save", "setenv", "system", "tasks", "type", "unalias", "unsetenv", "which"
    ]

    public static let basicKeywordWords = [
        "ASYNC", "AWAIT", "CALL", "CASE", "CLASS", "COLOR", "DATA", "DEF", "DIM", "DO",
        "ELSE", "ELSEIF", "END", "ERROR", "EXIT", "FOR", "FUNCTION", "GLOBAL", "GOSUB",
        "GOTO", "IF", "IMPORT", "INPUT", "INTERFACE", "JOIN", "LABEL", "LET", "LINE",
        "LOCAL", "LOOP", "NEXT", "ON", "OPTION", "PRINT", "READ", "REM", "RESTORE",
        "RETURN", "SELECT", "SLEEP", "STEP", "SYSTEM", "THEN", "TO", "TYPE", "WEND",
        "WHILE", "YIELD"
    ]

    public static func context(buffer: String, cursor: Int) -> BASICCompletionContext {
        let prefix = String(buffer.prefix(cursor))
        let tokenStart = prefix.lastIndex(where: { $0.isWhitespace }).map { prefix.index(after: $0) } ?? prefix.startIndex
        let token = String(prefix[tokenStart...])
        let leading = prefix[..<tokenStart].trimmingCharacters(in: .whitespacesAndNewlines)
        return BASICCompletionContext(
            token: token,
            startOffset: prefix.distance(from: prefix.startIndex, to: tokenStart),
            isCommandPosition: leading.isEmpty
        )
    }

    public static func candidates(
        for context: BASICCompletionContext,
        pathCandidates: [String],
        commandWords: [String],
        symbolWords: [String]
    ) -> [String] {
        var seen = Set<String>()
        var candidates: [String] = []

        func append(_ value: String) {
            guard !value.isEmpty, seen.insert(value).inserted else { return }
            candidates.append(value)
        }

        for candidate in pathCandidates {
            append(candidate)
        }

        if context.isCommandPosition, !context.token.contains("/") {
            for word in commandWords where caseInsensitiveHasPrefix(word, prefix: context.token) {
                append(word)
            }
        }

        if !context.token.contains("/") {
            for word in symbolWords where caseInsensitiveHasPrefix(word, prefix: context.token) {
                append(word)
            }
        }

        return candidates.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public static func commonPrefix(_ values: [String]) -> String {
        guard var prefix = values.first else { return "" }
        for value in values.dropFirst() {
            while !prefix.isEmpty && !caseInsensitiveHasPrefix(value, prefix: prefix) {
                prefix.removeLast()
            }
        }
        return prefix
    }

    public static func caseInsensitiveHasPrefix(_ value: String, prefix: String) -> Bool {
        guard !prefix.isEmpty else { return true }
        return value.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }

    public static func programSymbolWords(in program: BASICProgram) -> [String] {
        var words: [String] = []
        var seen = Set<String>()

        func append(_ raw: String) {
            let word = sanitizedBASICSymbol(raw)
            guard !word.isEmpty, seen.insert(word.uppercased()).inserted else { return }
            words.append(word)
        }

        for line in program.orderedLines {
            let source = line.source.trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty else { continue }

            if let colon = source.firstIndex(of: ":") {
                let label = String(source[..<colon]).trimmingCharacters(in: .whitespaces)
                if isBASICIdentifier(label) {
                    append(label)
                }
            }

            let tokens = basicCompletionTokens(from: source)
            guard !tokens.isEmpty else { continue }
            let upperTokens = tokens.map { $0.uppercased() }

            if upperTokens.first == "LABEL", tokens.count >= 2 {
                append(tokens[1])
            }
            if upperTokens.count >= 3, upperTokens[0] == "FUNCTION", upperTokens[1] == "TYPE" {
                append(tokens[2])
            } else if let functionIndex = upperTokens.firstIndex(of: "FUNCTION"),
                      tokens.indices.contains(functionIndex + 1) {
                append(tokens[functionIndex + 1])
            }
            if upperTokens.first == "DEF", tokens.count >= 2 {
                append(tokens[1])
            }
            if upperTokens.first == "CLASS", tokens.count >= 2 {
                append(tokens[1])
            }
            if upperTokens.first == "INTERFACE", tokens.count >= 2 {
                append(tokens[1])
            }
            if upperTokens.first == "TYPE", tokens.count >= 2 {
                append(tokens[1])
            }

            collectDeclaredVariables(from: tokens, upperTokens: upperTokens, append: append)
        }

        return words.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func collectDeclaredVariables(
        from tokens: [String],
        upperTokens: [String],
        append: (String) -> Void
    ) {
        guard let first = upperTokens.first else { return }
        if ["DIM", "GLOBAL", "LOCAL"].contains(first) {
            var index = 1
            while index < tokens.count {
                let upper = upperTokens[index]
                if upper == "AS" {
                    break
                }
                if upper != "," {
                    append(tokens[index])
                }
                index += 1
            }
        } else if first == "LET", tokens.count >= 2 {
            append(tokens[1])
        }
    }

    private static func basicCompletionTokens(from source: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inString = false

        for character in source {
            if character == "\"" {
                inString.toggle()
                continue
            }
            guard !inString else { continue }

            if character.isLetter || character.isNumber || "_$%#.".contains(character) {
                current.append(character)
            } else {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                if character == "," {
                    tokens.append(",")
                }
                if character == "'" {
                    break
                }
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func sanitizedBASICSymbol(_ raw: String) -> String {
        var symbol = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = symbol.last, "(),;:=+-*/<>".contains(last) {
            symbol.removeLast()
        }
        return isBASICIdentifier(symbol) ? symbol : ""
    }

    private static func isBASICIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first.isLetter || first == "_" else { return false }
        return value.allSatisfy { character in
            character.isLetter || character.isNumber || "_$%#.".contains(character)
        }
    }
}
