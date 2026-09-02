//
//  BASICHighlighter.swift
//  BASICShell
//
//  The BASIC language's syntax definition — the one place that says what a
//  stretch of BASIC source *is*, and what colour that should be.
//
//  Named and shaped after TUIKit's own `HTMLHighlighter`, `CSSHighlighter` and
//  `JavaScriptHighlighter`: one file per language, conforming to
//  `SyntaxHighlighting`. It lives in BASICShell rather than in TUIKit because
//  BASIC is this program's language, not the toolkit's — and because it needs
//  ``BASICKeywords``, which lives in BASICCore.
//

import BASICCore
import TUIKit

// MARK: - What the language is made of

/// What a stretch of BASIC source is.
///
/// The language's own vocabulary, deliberately — not TUIKit's. Everything below
/// is written in terms of `BASICToken`, and exactly one function turns those
/// into something a terminal can paint. That indirection is worth its keep: see
/// ``BASICToken/highlightKind``.
enum BASICToken: Hashable {
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

extension BASICToken {
    /// The TUIKit kind that paints this token.
    ///
    /// ## Why some of these look wrong
    ///
    /// `HighlightKind` is TUIKit's vocabulary, built for markup: it has
    /// `keyword`, `string`, `number` and `comment`, and then `tag`,
    /// `attributeName` and `entity` — but no `function` and no `type`. There is
    /// also no way to override what a kind paints as: `SyntaxTextView` reads
    /// `span.kind.cellStyle`, and `cellStyle` is a fixed switch.
    ///
    /// So the kind is the only colour channel there is, and three of these are
    /// chosen for **what they render as** rather than for what they are called:
    ///
    /// | Token      | Kind            | Renders as        |
    /// |------------|-----------------|-------------------|
    /// | statement  | `.keyword`      | bold magenta      |
    /// | function   | `.entity`       | yellow            |
    /// | typeName   | `.tag`          | bold bright blue  |
    /// | label      | `.attributeName`| cyan              |
    ///
    /// The alternative was painting all four bold magenta, which is what the
    /// first version did and which throws away a distinction BASICCore already
    /// draws and Studio already shows.
    ///
    /// Confining the mismatch to this one property is the point of `BASICToken`
    /// existing at all. Nothing else in this file mentions `.entity` or `.tag`,
    /// so when TUIKit gains `.function` and `.type` cases this table is the
    /// only thing that changes — and until then, no reader of the tokenizer
    /// below has to wonder why a builtin is an HTML character entity.
    var highlightKind: HighlightKind {
        switch self {
        case .statement: return .keyword
        case .function: return .entity
        case .typeName: return .tag
        case .label: return .attributeName
        case .string: return .string
        case .number: return .number
        case .comment: return .comment
        }
    }
}

// MARK: - The tokenizer

/// Colours a line of BASIC.
///
/// Every word comes from ``BASICKeywords``, the language's one vocabulary —
/// never a list living here. A keyword the parser learns reaches this
/// highlighter, the completion menu, `LIST`, and Studio's editor together,
/// because a test in BASICCore fails until it does.
///
/// ## One line at a time is enough
///
/// BASIC has no block comments and no multi-line strings, so every line is
/// independent and the threaded `state` never leaves `.initial`. That is worth
/// saying out loud: it is why this can be a pure function of one line, and why
/// editing line 900 does not force a re-lex of the 899 above it.
struct BASICHighlighter: SyntaxHighlighting {

    func highlight(line: String, state: inout HighlightState) -> [HighlightSpan] {
        let characters = Array(line)
        var spans: [HighlightSpan] = []

        func emit(_ token: BASICToken, at start: Int, length: Int) {
            guard length > 0 else { return }
            spans.append(HighlightSpan(start: start, length: length, kind: token.highlightKind))
        }

        let firstNonBlank = characters.prefix { $0.isWhitespace }.count

        // `#!/usr/bin/env basicshell` and `# a note`. A shebang is the first
        // line of every runnable script in Docs/SHELL.md, and without this the
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
                // dropped. Someone in the middle of typing `PRINT "hel` should
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
                // `BASICKeywords.category(of:)` matches without regard to case
                // because BASIC does: `print`, `Print`, and `PRINT` are one
                // keyword and all three should look like one.
                if let category = BASICKeywords.category(of: word) {
                    emit(Self.token(for: category), at: index, length: end - index)
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
    /// The categories BASICCore draws that a terminal cannot usefully tell
    /// apart are folded here rather than at the colour table: `OPTION`
    /// modifiers read as statements, which is where a reader meets them.
    private static func token(for category: BASICKeywords.Category) -> BASICToken {
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
    private func wordEnd(in characters: [Character], from start: Int) -> Int {
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
    private func labelRange(in characters: [Character], from start: Int) -> Range<Int>? {
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
