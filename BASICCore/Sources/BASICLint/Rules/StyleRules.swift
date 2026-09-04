import BASICSyntax
import Foundation

// Style and structure rules.
//
// The first five are the legacy set: `GOTO`, `GOSUB`, line numbers, `LET`,
// and implicit types are how BASIC was written for thirty years, so they run
// in the `modern` profile only. A 1985 program is not badly written; it is
// written in 1985, and a linter that says otherwise on every line is a
// linter nobody runs twice.

/// `GOTO`.
public struct GotoRule: BASICLintRule {
    public let id = "style.goto"
    public let name = "GOTO"
    public let rationale = "A GOTO can leave a block, skip an initialization, or land in the middle of a loop, and nothing in the line says which. A named routine says where it goes."
    public let defaultSeverity = LintSeverity.note
    public let supportedProfiles: Set<LintProfile> = [.modern]
    public init() {}

    public func check(node: LintNode, context: LintContext) -> [LintFinding] {
        // A single-line `IF … THEN GOTO x` is a GOTO too, and it is the one
        // a program is most likely to have a lot of.
        if case .ifThen(_, let thenAction, let elseAction)? = node.statement {
            let branches = [thenAction, elseAction].compactMap { $0 }.filter {
                // `THEN 80` is a branch; `THEN GOTO 80` is a statement that
                // is one. Both are a GOTO to the person reading the line.
                switch $0 {
                case .branch: return true
                case .statement(.goto), .statement(.gotoLabel), .statement(.computedGoto): return true
                default: return false
                }
            }
            guard !branches.isEmpty else { return [] }
            return [context.finding(id, "GOTO; a FUNCTION or a block would say where this goes", at: node.range)]
        }
        guard node.kind == .gotoStatement else { return [] }
        return [context.finding(id, "GOTO; a FUNCTION or a block would say where this goes", at: node.range)]
    }
}

/// `GOSUB`.
public struct GosubRule: BASICLintRule {
    public let id = "style.gosub"
    public let name = "GOSUB"
    public let rationale = "A GOSUB is a call with no parameters, no result, and no scope: everything it touches is shared with the whole program."
    public let defaultSeverity = LintSeverity.note
    public let supportedProfiles: Set<LintProfile> = [.modern]
    public init() {}

    public func check(node: LintNode, context: LintContext) -> [LintFinding] {
        guard node.kind == .gosubStatement else { return [] }
        return [context.finding(id, "GOSUB; a FUNCTION takes arguments and returns a value", at: node.range)]
    }
}

/// Line numbers.
public struct LineNumberRule: BASICLintRule {
    public let id = "style.line_numbers"
    public let name = "Line numbers"
    public let rationale = "Line numbers are addresses, and a program that renumbers is a program whose comments about line 400 are now wrong. Labels do not move."
    public let defaultSeverity = LintSeverity.note
    public let supportedProfiles: Set<LintProfile> = [.modern]
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        guard let first = context.facts.lineNumbers.first else { return [] }
        return [context.finding(
            id, "the program is numbered (\(context.facts.lineNumbers.count) lines); labels do not move when it is edited", at: first.range
        )]
    }
}

/// The `LET` keyword.
public struct LetKeywordRule: BASICLintRule {
    public let id = "style.let_keyword"
    public let name = "LET"
    public let rationale = "LET says nothing the assignment does not. It is also the statement whose scope depends on OPTION, which is a second reason to write assignments without it."
    public let defaultSeverity = LintSeverity.note
    public let supportedProfiles: Set<LintProfile> = [.modern]
    public init() {}

    public func check(node: LintNode, context: LintContext) -> [LintFinding] {
        guard node.kind == .assignment else { return [] }
        let leading = node.text.trimmingCharacters(in: .whitespaces).uppercased()
        guard leading.hasPrefix("LET ") else { return [] }
        return [context.finding(id, "LET adds nothing here", at: node.range)]
    }
}

/// A variable with neither a suffix nor an `AS` type.
public struct ImplicitTypeRule: BASICLintRule {
    public let id = "style.implicit_type"
    public let name = "Variable with no declared type"
    public let rationale = "A name with no suffix and no AS is a number, whatever it was meant to be — which is how a string ends up as 0."
    public let defaultSeverity = LintSeverity.note
    public let supportedProfiles: Set<LintProfile> = [.modern]
    public init() {}

    public func check(node: LintNode, context: LintContext) -> [LintFinding] {
        guard case .assignment(_, let name, nil, _)? = node.statement else { return [] }
        guard let last = name.name.last, !"$%!#".contains(last) else { return [] }
        // A `DIM x AS INTEGER` elsewhere declares it; this line is only the
        // assignment, and repeating the type on it is not the language.
        guard !context.facts.hasDeclaredType(name.name) else { return [] }
        return [context.finding(id, "\(name.name) has no suffix and no AS type, so it is a number", at: node.range)]
    }
}

/// Two `OPTION LET` modes in one file.
public struct MixedLetModeRule: BASICLintRule {
    public let id = "style.mixed_let_mode"
    public let name = "OPTION LET changed mid-file"
    public let rationale = "Whether an assignment inside a FUNCTION is local or global changes with it, so a file with both has two halves that mean different things by the same line."
    public let defaultSeverity = LintSeverity.warning
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        var modes: [(mode: String, range: LintRange)] = []
        for node in tree.root.descendants {
            if case .optionLetMode(let mode)? = node.statement {
                modes.append(("\(mode)", node.range))
            }
        }
        guard modes.count > 1, Set(modes.map(\.mode)).count > 1, let second = modes.dropFirst().first else { return [] }
        return [context.finding(id, "OPTION LET is set more than one way in this file", at: second.range)]
    }
}

/// A number in the middle of an expression.
public struct MagicNumberRule: BASICLintRule {
    public let id = "style.magic_number"
    public let name = "Magic number"
    public let rationale = "A number nobody named is a number nobody can change safely: the same 80 appears three times and only two of them meant the screen width."
    public let defaultSeverity = LintSeverity.note
    public var options: [String: LintOptionValue] { ["allowed": .string("0,1,2,-1,100")] }
    public init() {}

    public func check(node: LintNode, context: LintContext) -> [LintFinding] {
        guard node.kind == .branch || node.kind == .assignment else { return [] }
        var allowed: Set<Double> = [0, 1, 2, -1, 100]
        if case .string(let list)? = context.options["allowed"] {
            allowed = Set(list.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) })
        }
        let numbers = Self.numbers(in: node.statement).filter { !allowed.contains($0) }
        guard let first = numbers.first else { return [] }
        return [context.finding(id, "\(Self.render(first)) has no name; a named constant says what it is", at: node.range)]
    }

    static func render(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    static func numbers(in statement: Statement?) -> [Double] {
        switch statement {
        case .assignment(_, _, _, .some(let value)): return numbers(in: value)
        case .blockIf(let condition), .elseIf(let condition): return numbers(in: condition)
        case .ifThen(let condition, _, _): return numbers(in: condition)
        default: return []
        }
    }

    static func numbers(in expression: BASICSyntax.Expression) -> [Double] {
        switch expression {
        case .number(let value): return [value]
        case .unaryMinus(let inner): return numbers(in: inner).map { -$0 }
        case .binary(let left, _, let right): return numbers(in: left) + numbers(in: right)
        case .callOrArray(_, let arguments), .functionCall(_, let arguments): return arguments.flatMap(numbers(in:))
        default: return []
        }
    }
}

/// A line longer than it needs to be.
public struct LineLengthRule: BASICLintRule {
    public let id = "style.line_length"
    public let name = "Long line"
    public let rationale = "A line nobody can see the end of is a line nobody reviews."
    public let defaultSeverity = LintSeverity.note
    public var options: [String: LintOptionValue] { ["limit": .number(120)] }
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        let limit = context.option("limit", default: 120)
        return tree.sourceLines.enumerated().compactMap { offset, line in
            guard line.count > limit else { return nil }
            return context.finding(id, "line is \(line.count) characters, over \(limit)", at: LintRange(line: offset + 1, column: limit + 1))
        }
    }
}

/// Trailing whitespace.
public struct TrailingWhitespaceRule: BASICLintRule {
    public let id = "style.trailing_whitespace"
    public let name = "Trailing whitespace"
    public let rationale = "It is invisible, it makes diffs about nothing, and in a language with line continuations it is occasionally load-bearing by accident."
    public let defaultSeverity = LintSeverity.note
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        tree.sourceLines.enumerated().compactMap { offset, line in
            guard !line.isEmpty, line.last == " " || line.last == "\t" else { return nil }
            let trimmed = line.reversed().prefix { $0 == " " || $0 == "\t" }.count
            return context.finding(id, "trailing whitespace", at: LintRange(line: offset + 1, column: line.count - trimmed + 1))
        }
    }
}

/// An `IF` arm with nothing in it.
public struct EmptyBranchRule: BASICLintRule {
    public let id = "style.empty_branch"
    public let name = "Empty IF arm"
    public let rationale = "An arm with nothing in it is either a condition nobody finished or one that should have been written the other way round."
    public let defaultSeverity = LintSeverity.warning
    public init() {}

    public func check(node: LintNode, context: LintContext) -> [LintFinding] {
        guard node.kind == .branch, case .blockIf? = node.statement else { return [] }
        let body = node.children.filter { $0.kind != .comment && $0.kind != .branch && $0.kind != .blockEnd }
        guard body.isEmpty else { return [] }
        return [context.finding(id, "this IF does nothing", at: node.range)]
    }
}

/// Nested `IF`s deep enough to be a `SELECT CASE`.
public struct DeeplyNestedIfRule: BASICLintRule {
    public let id = "style.nested_if"
    public let name = "Deeply nested IF"
    public let rationale = "Three IFs inside each other testing one value is a SELECT CASE written the long way, and the long way is the one where an arm goes missing."
    public let defaultSeverity = LintSeverity.note
    public var options: [String: LintOptionValue] { ["depth": .number(3)] }
    public init() {}

    public func check(node: LintNode, context: LintContext) -> [LintFinding] {
        guard node.kind == .branch, case .blockIf? = node.statement else { return [] }
        let limit = context.option("depth", default: 3)
        var depth = 1
        var parent = node.parent
        while let current = parent {
            if current.kind == .branch { depth += 1 }
            parent = current.parent
        }
        guard depth >= limit else { return [] }
        return [context.finding(id, "IF nested \(depth) deep; SELECT CASE reads flatter", at: node.range)]
    }
}
