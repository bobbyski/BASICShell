import BASICSyntax
import Foundation

// Documentation comments (`///`, read by Swift's rules — see
// BASICDocumentation.swift).
//
// These are the checks Swift's documentation compiler makes, for the same
// reason it makes them: documentation that disagrees with its declaration is
// worse than none, because it is believed. Each rule compares a comment
// with the declaration under it; none asks that anything be documented.

extension LintTree {
    /// Every declaration and the documentation above it.
    var documentedSymbols: [BASICDocumentedSymbol] {
        BASICDocumentation.symbols(in: sourceLines.joined(separator: "\n"))
    }
}

/// The line a documented parameter is written on, so a finding lands on the
/// callout rather than on the top of the comment.
private func line(of parameter: BASICDocComment.Parameter, in symbol: BASICDocumentedSymbol) -> Int {
    (symbol.documentationLine ?? symbol.line) + parameter.line
}

/// A `///` block that documents nothing.
public struct DetachedDocCommentRule: BASICLintRule {
    public let id = "doc.detached"
    public let name = "Detached documentation comment"
    public let rationale = "A `///` comment documents the declaration on the very next line. With a blank line or other code in between it documents nothing, and every tool that shows documentation will silently show none."
    public let defaultSeverity = LintSeverity.warning
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        BASICDocumentation.detachedComments(in: tree.sourceLines.joined(separator: "\n")).map {
            context.finding(id, "documentation comment documents nothing: \($0.reason)", at: LintRange(line: $0.line, column: 1))
        }
    }
}

/// `- Parameter x:` where there is no `x`.
public struct UnknownDocParameterRule: BASICLintRule {
    public let id = "doc.unknown_parameter"
    public let name = "Documented parameter that does not exist"
    public let rationale = "A parameter renamed or removed leaves its documentation behind, describing an argument nobody can pass."
    public let defaultSeverity = LintSeverity.warning
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        tree.documentedSymbols.flatMap { symbol -> [LintFinding] in
            guard let doc = symbol.documentation else { return [] }
            let declared = Set(symbol.parameters.map { $0.uppercased() })
            return doc.parameters.filter { !declared.contains($0.name.uppercased()) }.map {
                let has = symbol.parameters.isEmpty ? "takes no parameters" : "has no parameter \($0.name)"
                return context.finding(id, "\(symbol.qualifiedName) \(has)", at: LintRange(line: line(of: $0, in: symbol), column: 1))
            }
        }
    }
}

/// Some parameters documented, and not all of them.
public struct MissingDocParameterRule: BASICLintRule {
    public let id = "doc.missing_parameter"
    public let name = "Parameter left out of the documentation"
    public let rationale = "Documenting some parameters and not others reads as though the rest were forgotten. Undocumented routines are fine; half-documented ones are not."
    public let defaultSeverity = LintSeverity.note
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        tree.documentedSymbols.flatMap { symbol -> [LintFinding] in
            // Only once the comment documents a parameter: a routine whose
            // comment is a summary alone has chosen not to, which is allowed.
            guard let doc = symbol.documentation, !doc.parameters.isEmpty else { return [] }
            let documented = Set(doc.parameters.map { $0.name.uppercased() })
            return symbol.parameters.filter { !documented.contains($0.uppercased()) }.map {
                context.finding(id, "\(symbol.qualifiedName) documents its other parameters but not \($0)",
                                at: LintRange(line: symbol.documentationLine ?? symbol.line, column: 1))
            }
        }
    }
}

/// `- Returns:` on something that returns nothing.
public struct ReturnsWithoutValueRule: BASICLintRule {
    public let id = "doc.returns_without_value"
    public let name = "Returns documented for no value"
    public let rationale = "A `- Returns:` callout on a routine with no result describes a value no caller will ever get."
    public let defaultSeverity = LintSeverity.warning
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        tree.documentedSymbols.compactMap { symbol -> LintFinding? in
            guard symbol.documentation?.returns != nil, !symbol.returnsValue else { return nil }
            return context.finding(id, "\(symbol.qualifiedName) documents a result but returns nothing",
                                   at: LintRange(line: symbol.documentationLine ?? symbol.line, column: 1))
        }
    }
}
