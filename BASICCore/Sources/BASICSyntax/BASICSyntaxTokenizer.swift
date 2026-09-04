//
//  BASICSyntaxTokenizer.swift
//  BASICCore
//
//  What a line of BASIC is made of, in the language's own terms.
//
//  ## Why this is in BASICCore rather than in an editor
//
//  It started in BASICShell, next to the TUIKit editor that wanted it. Then
//  `RichSyntax` needed the same answer, and RichSyntax is in BASICCore, and the
//  alternative was a second tokenizer that would disagree with the first about
//  what a label is.
//
//  So the *tokenizer* lives here, knows nothing about colour, and produces
//  spans in BASIC's vocabulary. Each renderer maps those onto whatever it can
//  actually paint — TUIKit's `HighlightKind` in the shell's editor, ANSI in
//  RichSyntax. Neither mapping is in this file, and neither tokenizes.
//
//  It also means `LIST`, the shell editor, Studio's Monaco and RichSyntax now
//  all agree, because all four are downstream of ``BASICKeywords`` and this.
//

import Foundation

/// What a stretch of BASIC source is.
public enum BASICSyntaxToken: Hashable, Sendable, CaseIterable {
    /// A statement, declaration, or control word: `PRINT`, `DIM`, `FOR`, `CLS`.
    case statement
    /// An intrinsic function: `LEN`, `MID$`, `SLEEP`, `HTTPGETASYNC`.
    case function
    /// A type name or literal: `INTEGER`, `STRING`, `TRUE`.
    case typeName
    /// A branch target at the head of a line: `Loop:`.
    case label
    /// A string literal.
    case string
    /// A numeric literal, including a leading line number.
    case number
    /// `REM`, `'`, `//`, or a `#` line.
    case comment
}

/// One coloured run: a character offset, a length, and what it is.
public struct BASICSyntaxSpan: Hashable, Sendable {
    /// Offset in characters from the start of the line.
    public let start: Int
    /// Length in characters.
    public let length: Int
    /// What the span is.
    public let token: BASICSyntaxToken

    public init(start: Int, length: Int, token: BASICSyntaxToken) {
        self.start = start
        self.length = length
        self.token = token
    }
}

/// Splits a line of BASIC into spans.
///
/// Every word comes from ``BASICKeywords``, never a list living here, so a
/// keyword the parser learns reaches every renderer at once.
///
/// ## One line at a time is enough
///
/// BASIC has no block comments and no multi-line strings, so every line is
/// independent. That is why this is a pure function of one line, and why
/// editing line 900 does not force a re-lex of the 899 above it.
public enum BASICSyntaxTokenizer {

    /// The spans in `line`, in order, non-overlapping. Gaps are plain text.
    public static func spans(in line: String) -> [BASICSyntaxSpan] {
        let characters = Array(line)
        var spans: [BASICSyntaxSpan] = []

        func emit(_ token: BASICSyntaxToken, at start: Int, length: Int) {
            guard length > 0 else { return }
            spans.append(BASICSyntaxSpan(start: start, length: length, token: token))
        }

        let firstNonBlank = characters.prefix { $0.isWhitespace }.count

        // `#!/usr/bin/env basicshell` and `# a note`. A shebang is the first
        // line of every runnable script in SHELL.md, and without this the
        // interpreter's own name lit up as if it were code.
        if firstNonBlank < characters.count, characters[firstNonBlank] == "#" {
            emit(.comment, at: firstNonBlank, length: characters.count - firstNonBlank)
            return spans
        }

        var index = 0

        // A leading line number, which is a number rather than an expression:
        // `10 PRINT` is line 10, but the `10` in `X = 10 + 1` is arithmetic.
        // Only a run of digits followed by whitespace or end-of-line counts.
        if firstNonBlank < characters.count, characters[firstNonBlank].isNumber {
            var end = firstNonBlank
            while end < characters.count, characters[end].isNumber { end += 1 }
            if end == characters.count || characters[end].isWhitespace {
                emit(.number, at: firstNonBlank, length: end - firstNonBlank)
                index = end
            }
        }

        if let label = labelRange(in: characters, from: index) {
            emit(.label, at: label.lowerBound, length: label.count)
            index = label.upperBound
        }

        while index < characters.count {
            let character = characters[index]

            // `'` and `//` both start a comment, as they do in Studio.
            if character == "'"
                || (character == "/" && index + 1 < characters.count && characters[index + 1] == "/") {
                emit(.comment, at: index, length: characters.count - index)
                break
            }

            if character == "\"" {
                // An unterminated string runs to end of line rather than being
                // dropped. Someone mid-way through typing `PRINT "hel` should
                // see it as the string it is about to be, not as plain text
                // that turns green a keystroke later.
                var end = index + 1
                while end < characters.count, characters[end] != "\"" { end += 1 }
                let stop = min(end + 1, characters.count)
                emit(.string, at: index, length: stop - index)
                index = stop
                continue
            }

            if character.isNumber {
                var end = index
                while end < characters.count,
                      characters[end].isNumber || characters[end] == "." {
                    end += 1
                }
                emit(.number, at: index, length: end - index)
                index = end
                continue
            }

            if character.isLetter || character == "_" {
                let end = wordEnd(in: characters, from: index)
                let word = String(characters[index..<end])
                if word.uppercased() == "REM" {
                    emit(.comment, at: index, length: characters.count - index)
                    break
                }
                // Matched without regard to case because BASIC is: `print`,
                // `Print` and `PRINT` are one keyword and all three should look
                // like one.
                if let category = BASICKeywords.category(of: word) {
                    emit(token(for: category), at: index, length: end - index)
                }
                index = end
                continue
            }

            index += 1
        }

        return spans
    }

    /// What a vocabulary category is, in this language's terms.
    ///
    /// The categories BASICCore draws that a *renderer* cannot usefully tell
    /// apart are folded here rather than in each renderer: `OPTION` modifiers
    /// read as statements, which is where a reader meets them.
    private static func token(for category: BASICKeywords.Category) -> BASICSyntaxToken {
        switch category {
        case .control, .declaration, .io, .graphics, .option:
            return .statement
        case .type:
            return .typeName
        case .function:
            return .function
        }
    }

    /// The end of the identifier starting at `start`.
    ///
    /// `$` is part of the word: BASIC's string-typed names end in one, and
    /// `MID$` and `TASKSTATUS$` are keywords. Stopping before it would match
    /// the *prefix* against the vocabulary and colour half an identifier.
    private static func wordEnd(in characters: [Character], from start: Int) -> Int {
        var end = start
        while end < characters.count,
              characters[end].isLetter || characters[end].isNumber
                || characters[end] == "_" || characters[end] == "$" {
            end += 1
        }
        return end
    }

    /// The range of a branch label at the head of a line, if there is one.
    ///
    /// An identifier followed by `:`, which is how `Loop:` in the bundled
    /// `hello.bas` marks a `GOTO` target.
    ///
    /// **A keyword is never a label.** `:` also separates statements, so a line
    /// beginning `PRINT: PRINT` would otherwise have its first `PRINT` painted
    /// as a label — the one case where the naive rule is visibly wrong, and one
    /// that costs a single lookup to exclude.
    private static func labelRange(in characters: [Character], from start: Int) -> Range<Int>? {
        var index = start
        while index < characters.count, characters[index].isWhitespace { index += 1 }
        guard index < characters.count,
              characters[index].isLetter || characters[index] == "_" else { return nil }

        let end = wordEnd(in: characters, from: index)
        guard !BASICKeywords.isKeyword(String(characters[index..<end])) else { return nil }

        var colon = end
        while colon < characters.count, characters[colon] == " " || characters[colon] == "\t" {
            colon += 1
        }
        guard colon < characters.count, characters[colon] == ":" else { return nil }
        return index..<end
    }
}
