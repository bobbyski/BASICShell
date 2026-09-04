import Foundation

// The complexity rules, with CodeWatch's ids and thresholds.

/// A routine with too many paths through it.
public struct CyclomaticComplexityRule: BASICLintRule {
    public let id = "complexity.cyclomatic"
    public let name = "Cyclomatic complexity"
    public let rationale = "Every branch doubles what a reader has to hold, and the count is how many paths a test would have to cover to see all of it."
    public let defaultSeverity = LintSeverity.warning
    public var options: [String: LintOptionValue] { ["threshold": .number(10)] }
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        let threshold = context.option("threshold", default: 10)
        return Metrics.measure(tree).routines.compactMap { routine in
            guard routine.cyclomaticComplexity > threshold else { return nil }
            return context.finding(
                id,
                "\(routine.name ?? "the main program") has a cyclomatic complexity of \(routine.cyclomaticComplexity), over \(threshold)",
                at: LintRange(line: routine.line, column: 1)
            )
        }
    }
}

/// A routine longer than a screen.
public struct LongRoutineRule: BASICLintRule {
    public let id = "complexity.long_routine"
    public let name = "Long routine"
    public let rationale = "A routine nobody can see at once is a routine whose middle nobody reads."
    public let defaultSeverity = LintSeverity.note
    public var options: [String: LintOptionValue] { ["threshold": .number(60)] }
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        let threshold = context.option("threshold", default: 60)
        return Metrics.measure(tree).routines.compactMap { routine in
            guard routine.name != nil, routine.length > threshold else { return nil }
            return context.finding(
                id, "\(routine.name ?? "") is \(routine.length) statements, over \(threshold)",
                at: LintRange(line: routine.line, column: 1)
            )
        }
    }
}

/// Too many parameters.
public struct LongParameterListRule: BASICLintRule {
    public let id = "complexity.long_parameter_list"
    public let name = "Long parameter list"
    public let rationale = "Past a handful, the call site is a row of values nobody can check against the declaration without counting."
    public let defaultSeverity = LintSeverity.note
    public var options: [String: LintOptionValue] { ["threshold": .number(5)] }
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        let threshold = context.option("threshold", default: 5)
        return Metrics.measure(tree).routines.compactMap { routine in
            guard routine.parameterCount > threshold else { return nil }
            return context.finding(
                id, "\(routine.name ?? "") takes \(routine.parameterCount) parameters, over \(threshold)",
                at: LintRange(line: routine.line, column: 1)
            )
        }
    }
}

/// Blocks nested too deeply.
public struct NestedBlockDepthRule: BASICLintRule {
    public let id = "complexity.nested_block_depth"
    public let name = "Nested block depth"
    public let rationale = "Depth is the measure that predicts where a bug is: the code at the bottom runs under conditions nobody has all of in mind."
    public let defaultSeverity = LintSeverity.note
    public var options: [String: LintOptionValue] { ["threshold": .number(4)] }
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        let threshold = context.option("threshold", default: 4)
        return Metrics.measure(tree).routines.compactMap { routine in
            guard routine.nestingDepth > threshold else { return nil }
            return context.finding(
                id, "\(routine.name ?? "the main program") nests \(routine.nestingDepth) deep, over \(threshold)",
                at: LintRange(line: routine.line, column: 1)
            )
        }
    }
}

/// A type with too much in it.
public struct LargeTypeRule: BASICLintRule {
    public let id = "complexity.large_type"
    public let name = "Large type"
    public let rationale = "A type that holds everything is a type nothing can be said about."
    public let defaultSeverity = LintSeverity.note
    public var options: [String: LintOptionValue] { ["threshold": .number(20)] }
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        let threshold = context.option("threshold", default: 20)
        return Metrics.measure(tree).types.compactMap { type in
            let members = type.fieldCount + type.methodCount
            guard members > threshold else { return nil }
            return context.finding(id, "\(type.name) has \(members) members, over \(threshold)", at: LintRange(line: type.line, column: 1))
        }
    }
}

/// A type with too many fields.
public struct TooManyFieldsRule: BASICLintRule {
    public let id = "complexity.too_many_fields"
    public let name = "Too many fields"
    public let rationale = "Fields are state, and state is what a reader has to track through every method that touches it."
    public let defaultSeverity = LintSeverity.note
    public var options: [String: LintOptionValue] { ["threshold": .number(12)] }
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        let threshold = context.option("threshold", default: 12)
        return Metrics.measure(tree).types.compactMap { type in
            guard type.fieldCount > threshold else { return nil }
            return context.finding(id, "\(type.name) has \(type.fieldCount) fields, over \(threshold)", at: LintRange(line: type.line, column: 1))
        }
    }
}
