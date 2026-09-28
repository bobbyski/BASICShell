//
//  BASICMidStatement.swift
//  BASICCore
//
//  The rule behind `MID$(target$, start [, count]) = replacement$`.
//

import Foundation

/// Overwriting part of a string in place, as GW-BASIC's `MID$` statement and
/// VB's `Mid` statement both do.
///
/// ```text
///   A$ = "The dog jumps"
///   MID$(A$, 5, 3) = "fox"               The fox jumps
///   MID$(A$, 5)    = "cow jumped over"   The cow jumpe    never longer
///   MID$(A$, 5, 3) = "duck"              The duc jumpe    at most count
/// ```
///
/// The length never changes. At most `count` characters are written (all of
/// the replacement when `count` is omitted), and never past the end.
///
/// A `start` below 1 or past the end, or a negative `count`, is Illegal
/// function call (ERR 5). VBA's reference does not say what a `start` past
/// the end does; VB's runtime raises error 5 there, and so does this.
///
/// The compiled runtime's copy is `rtMidReplacing` in BASICRT/RTStrings.swift.
enum BASICMidStatement {
    /// `target` with the replacement written over it from `start`.
    static func replacing(
        _ target: String,
        start: Int,
        count: Int?,
        with replacement: String
    ) throws -> String {
        var characters = Array(target)
        guard start >= 1, start <= characters.count else {
            throw BASICError.runtime("Illegal function call")
        }
        if let count, count < 0 {
            throw BASICError.runtime("Illegal function call")
        }
        let offset = start - 1
        let replacementCharacters = Array(replacement)
        let length = min(count ?? replacementCharacters.count, replacementCharacters.count, characters.count - offset)
        characters.replaceSubrange(offset..<offset + length, with: replacementCharacters.prefix(length))
        return String(characters)
    }
}
