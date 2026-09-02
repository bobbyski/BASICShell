//
//  BASICHighlighter.swift
//  BASICShell
//
//  BASIC in the shell's editor: TUIKit's `SyntaxHighlighting`, over
//  ``BASICSyntaxTokenizer``.
//
//  Named and shaped after TUIKit's own `HTMLHighlighter`, `CSSHighlighter` and
//  `JavaScriptHighlighter`: one file per language. It does no tokenizing —
//  that moved to BASICCore when `RichSyntax` needed the same answer, and a
//  second tokenizer here would eventually disagree with that one about what a
//  label is. All this file decides is colour.
//

import BASICCore
import TUIKit

extension BASICSyntaxToken {
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
    /// The alternative was painting all four bold magenta, which throws away a
    /// distinction BASICCore draws and Studio shows.
    ///
    /// Confining the mismatch to one property is the point. Nothing else here
    /// mentions `.entity` or `.tag`, so when TUIKit gains `.function` and
    /// `.type` this table is the only thing that changes.
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

/// Colours a line of BASIC for TUIKit.
///
/// BASIC has no block comments and no multi-line strings, so every line is
/// independent and the threaded `state` never leaves `.initial`.
struct BASICHighlighter: SyntaxHighlighting {
    func highlight(line: String, state: inout HighlightState) -> [HighlightSpan] {
        BASICSyntaxTokenizer.spans(in: line).map { span in
            HighlightSpan(
                start: span.start,
                length: span.length,
                kind: span.token.highlightKind
            )
        }
    }
}
