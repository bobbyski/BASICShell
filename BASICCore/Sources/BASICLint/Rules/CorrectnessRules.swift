import BASICSyntax
import Foundation

// Correctness rules: things that are probably bugs, in any profile.
//
// There is no corpus of BASIC lint data to learn from, so these are authored
// from the language — from what the interpreter actually does with a
// program, and from the mistakes the demos and the test suite made while
// they were being written.
//
// A rule the language already enforces is not here. `total$ AS INTEGER` was
// going to be one, until the parser turned out to refuse it: a linter that
// repeats a compile error adds a second voice saying the same thing.

/// A name read before anything assigns it.
public struct UseBeforeAssignmentRule: BASICLintRule {
    public let id = "correctness.use_before_assignment"
    public let name = "Variable used before it is assigned"
    public let rationale = "A BASIC variable read before it is assigned is 0 or \"\", so a misspelt name is not an error — it is a silent zero. This is the rule that catches the typo."
    public let defaultSeverity = LintSeverity.warning
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        let facts = context.facts
        // "Never assigned" can only be concluded about a file that holds the
        // whole program. A module, or a program that imports one, shares its
        // names with files this run cannot see.
        let isWholeProgram = facts.imports.isEmpty && tree.root.children.contains { node in
            switch node.kind {
            case .routineDeclaration, .typeDeclaration, .comment, .label, .importDirective, .optionStatement, .declaration:
                return false
            default:
                return true
            }
        }
        var assignedAt: [String: Int] = [:]
        for use in facts.assigned {
            let key = use.name.uppercased()
            assignedAt[key] = min(assignedAt[key] ?? Int.max, use.range.line)
        }
        var reported: Set<String> = []
        var findings: [LintFinding] = []
        for use in facts.read {
            let key = use.name.uppercased()
            guard !reported.contains(key), !ProgramFacts.isLanguageName(key) else { continue }
            // A parameter is assigned by its call, and a routine's name is
            // its result slot.
            guard !Self.isParameterOrRoutine(key, facts: facts) else { continue }
            guard let first = assignedAt[key] else {
                guard isWholeProgram else { continue }
                reported.insert(key)
                findings.append(context.finding(id, "\(use.name) is read but never assigned", at: use.range))
                continue
            }
            // Only a straight-line read *above* every assignment is a
            // finding: a loop legitimately reads what a later line assigns.
            if use.range.line < first, !Self.isInsideLoopOrRoutine(use, tree: tree) {
                reported.insert(key)
                findings.append(context.finding(id, "\(use.name) is read on line \(use.range.line), before it is assigned on line \(first)", at: use.range))
            }
        }
        return findings
    }

    static func isParameterOrRoutine(_ key: String, facts: ProgramFacts) -> Bool {
        if facts.routines[key] != nil { return true }
        return facts.parameters.values.contains { $0.contains { $0.name.uppercased() == key } }
    }

    static func isInsideLoopOrRoutine(_ use: NameUse, tree: LintTree) -> Bool {
        if use.routine != nil { return true }
        return tree.root.descendants.contains { node in
            (node.kind == .loop || node.kind == .routineDeclaration)
                && node.descendants.contains { $0.range.line == use.range.line }
        }
    }
}

/// A `DIM` that arrives after the array has already been used.
public struct DimAfterUseRule: BASICLintRule {
    public let id = "correctness.dim_after_use"
    public let name = "DIM after the array is used"
    public let rationale = "A BASIC array used before it is dimensioned gets the default bounds, and the later DIM then fails or silently re-shapes it. Whichever happens, the program does not mean what it reads as."
    public let defaultSeverity = LintSeverity.warning
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        var findings: [LintFinding] = []
        for dim in context.facts.dimensioned {
            let key = dim.name.uppercased()
            // Any earlier mention: `scores(1) = 5` is a use of the array
            // even though it is an assignment into it.
            let uses = context.facts.read + context.facts.assigned.filter { $0.range.line != dim.range.line }
            let earlier = uses.filter { $0.name.uppercased() == key && $0.range.line < dim.range.line }
                .min { $0.range.line < $1.range.line }
            if let earlier {
                findings.append(context.finding(id, "\(dim.name) is used on line \(earlier.range.line), before its DIM here", at: dim.range))
            }
        }
        return findings
    }
}

/// A variable assigned and never read.
public struct UnusedVariableRule: BASICLintRule {
    public let id = "correctness.unused_variable"
    public let name = "Variable assigned and never read"
    public let rationale = "A value computed and never used is either dead work or a name that was meant to be read somewhere and was misspelt there instead."
    public let defaultSeverity = LintSeverity.note
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        var reported: Set<String> = []
        var findings: [LintFinding] = []
        // A module's names are read by whatever imports it.
        let isWholeProgram = context.facts.imports.isEmpty && tree.root.children.contains { node in
            switch node.kind {
            case .routineDeclaration, .typeDeclaration, .comment, .label, .importDirective, .optionStatement, .declaration:
                return false
            default:
                return true
            }
        }
        guard isWholeProgram else { return [] }
        for use in context.facts.assigned {
            let key = use.name.uppercased()
            guard !reported.contains(key), !context.facts.isRead(key), !ProgramFacts.isLanguageName(key) else { continue }
            // A FOR counter is read by the loop itself.
            guard !context.facts.routines.keys.contains(key) else { continue }
            reported.insert(key)
            findings.append(context.finding(id, "\(use.name) is assigned but never read", at: use.range))
        }
        return findings
    }
}

/// A `FUNCTION` nothing calls.
public struct UnusedRoutineRule: BASICLintRule {
    public let id = "correctness.unused_routine"
    public let name = "FUNCTION never called"
    public let rationale = "A routine nothing calls is either dead or the program meant to call it. Both are worth seeing."
    public let defaultSeverity = LintSeverity.note
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        // A module — a file that is all declarations — is called by whatever
        // imports it, which this file cannot see. Only a file with a main
        // body of its own can say a routine is unreached.
        let hasMainBody = tree.root.children.contains { node in
            switch node.kind {
            case .routineDeclaration, .typeDeclaration, .comment, .label, .importDirective, .optionStatement, .declaration:
                return false
            default:
                return true
            }
        }
        guard hasMainBody else { return [] }
        var findings: [LintFinding] = []
        for (key, routine) in context.facts.routines.sorted(by: { $0.value.range.line < $1.value.range.line }) {
            let called = context.facts.called.contains { $0.name.uppercased() == key }
                || context.facts.read.contains { $0.name.uppercased() == key }
                || context.facts.branchTargets.contains { $0.name.uppercased() == key }
                // A control names its handler with a string.
                || context.facts.stringLiterals.contains(key)
            if !called {
                findings.append(context.finding(id, "\(routine.name) is never called", at: routine.range))
            }
        }
        return findings
    }
}

/// A label nothing branches to.
public struct UnusedLabelRule: BASICLintRule {
    public let id = "correctness.unused_label"
    public let name = "Label never branched to"
    public let rationale = "A label nothing reaches is a comment that looks like control flow."
    public let defaultSeverity = LintSeverity.note
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        var findings: [LintFinding] = []
        for label in context.facts.labels {
            let key = label.name.uppercased()
            let reached = context.facts.branchTargets.contains { $0.name.uppercased() == key }
                || context.facts.routines[key] != nil
            if !reached {
                findings.append(context.finding(id, "nothing branches to \(label.name)", at: label.range))
            }
        }
        return findings
    }
}

/// A branch to a label or line that does not exist.
public struct MissingBranchTargetRule: BASICLintRule {
    public let id = "correctness.missing_branch_target"
    public let name = "Branch to a label or line that does not exist"
    public let rationale = "The interpreter finds this at run time, when the branch is taken — which may be the one path a test never covers."
    public let defaultSeverity = LintSeverity.error
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        let labels = Set(context.facts.labels.map { $0.name.uppercased() })
        let numbers = Set(context.facts.lineNumbers.map { "\($0.number)" })
        let routines = Set(context.facts.routines.keys)
        var findings: [LintFinding] = []
        for target in context.facts.branchTargets {
            let key = target.name.uppercased()
            if !labels.contains(key), !numbers.contains(target.name), !routines.contains(key) {
                findings.append(context.finding(id, "nothing here is called \(target.name)", at: target.range))
            }
        }
        return findings
    }
}

/// Assigning to a `FOR` variable inside its own loop.
public struct ForVariableAssignedRule: BASICLintRule {
    public let id = "correctness.for_variable_assigned"
    public let name = "FOR variable assigned inside its loop"
    public let rationale = "The loop counts it, so assigning it changes how many times the loop runs — which is almost never what the line reads as."
    public let defaultSeverity = LintSeverity.warning
    public init() {}

    public func check(node: LintNode, context: LintContext) -> [LintFinding] {
        guard node.kind == .loop, case .forLoop(let variable, _, _, _)? = node.statement else { return [] }
        let key = variable.normalized
        return node.descendants.compactMap { inner in
            guard inner.kind == .assignment, let name = inner.name, name.uppercased() == key else { return nil }
            return context.finding(id, "\(variable.name) is the FOR counter; assigning it here changes the loop", at: inner.range)
        }
    }
}

/// `NEXT x` naming something other than the loop it closes.
public struct LoopVariableMismatchRule: BASICLintRule {
    public let id = "correctness.loop_variable_mismatch"
    public let name = "NEXT names a different variable"
    public let rationale = "A NEXT that names the wrong counter is a loop closed in the wrong place, and the interpreter says so only when it runs."
    public let defaultSeverity = LintSeverity.error
    public init() {}

    public func check(node: LintNode, context: LintContext) -> [LintFinding] {
        guard node.kind == .loop, case .forLoop(let variable, _, _, _)? = node.statement else { return [] }
        // The NEXT closes the loop, so it is the loop's last child.
        guard let closing = node.children.last(where: {
            if case .nextLoop = $0.statement { return true }
            return false
        }), case .nextLoop(let names)? = closing.statement, let named = names.first else { return [] }
        guard named.normalized != variable.normalized else { return [] }
        return [context.finding(id, "NEXT \(named.name) closes FOR \(variable.name)", at: closing.range)]
    }
}

/// `RESUME` with no `ON ERROR` anywhere.
public struct ResumeWithoutHandlerRule: BASICLintRule {
    public let id = "correctness.resume_without_handler"
    public let name = "RESUME without ON ERROR"
    public let rationale = "RESUME outside an error handler is a runtime error in the interpreter, and there is nothing at run time that could make it not be."
    public let defaultSeverity = LintSeverity.error
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        guard !context.facts.hasErrorHandler else { return [] }
        return context.facts.resumes.map { context.finding(id, "RESUME with no ON ERROR in the program", at: $0) }
    }
}

/// Duplicate labels or line numbers.
public struct DuplicateTargetRule: BASICLintRule {
    public let id = "correctness.duplicate_target"
    public let name = "Duplicate label or line number"
    public let rationale = "Two places with one name: a branch reaches one of them, and which one is not written down anywhere."
    public let defaultSeverity = LintSeverity.error
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        var seen: Set<String> = []
        var findings: [LintFinding] = []
        for label in context.facts.labels {
            let key = label.name.uppercased()
            if !seen.insert(key).inserted {
                findings.append(context.finding(id, "\(label.name) is already a label", at: label.range))
            }
        }
        var numbers: Set<Int> = []
        for entry in context.facts.lineNumbers where !numbers.insert(entry.number).inserted {
            findings.append(context.finding(id, "line \(entry.number) appears more than once", at: entry.range))
        }
        return findings
    }
}

/// `DATA` with no `READ`, or `READ` with no `DATA`.
public struct DataWithoutReadRule: BASICLintRule {
    public let id = "correctness.data_without_read"
    public let name = "DATA and READ do not match"
    public let rationale = "DATA nothing reads is dead, and READ with nothing to read is a runtime error the moment it runs."
    public let defaultSeverity = LintSeverity.warning
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        let facts = context.facts
        var findings: [LintFinding] = []
        let firstData = tree.root.descendants.first { $0.kind == .dataStatement }
        let firstRead = tree.root.descendants.first {
            if case .read? = $0.statement { return true }
            return false
        }
        if facts.dataItemCount > 0, facts.readTargetCount == 0, let node = firstData {
            findings.append(context.finding(id, "the program has DATA and never READs it", at: node.range))
        }
        if facts.readTargetCount > 0, facts.dataItemCount == 0, let node = firstRead {
            findings.append(context.finding(id, "the program READs and has no DATA", at: node.range))
        }
        if facts.dataItemCount > 0, facts.readTargetCount > facts.dataItemCount, let node = firstRead {
            findings.append(context.finding(
                id, "the program READs \(facts.readTargetCount) values and has \(facts.dataItemCount)", at: node.range
            ))
        }
        return findings
    }
}

/// Code after something that always leaves.
public struct UnreachableCodeRule: BASICLintRule {
    public let id = "correctness.unreachable_code"
    public let name = "Code after END, GOTO, or RETURN"
    public let rationale = "A statement that nothing can reach is either a mistake or a line that used to be reached and is not any more."
    public let defaultSeverity = LintSeverity.warning
    public init() {}

    public func check(node: LintNode, context: LintContext) -> [LintFinding] {
        var findings: [LintFinding] = []
        var leaving: LintNode?
        for child in node.children {
            if let left = leaving, child.kind != .label, child.kind != .comment,
               child.kind != .routineDeclaration, child.kind != .typeDeclaration {
                findings.append(context.finding(id, "nothing reaches this: line \(left.range.line) always leaves", at: child.range))
                leaving = nil
                continue
            }
            switch child.statement {
            case .end?, .goto?, .gotoLabel?, .returnFromSubroutine?:
                leaving = child
            default:
                leaving = nil
            }
        }
        return findings
    }
}

/// An `OPTION` after the program has started doing things.
public struct OptionAfterCodeRule: BASICLintRule {
    public let id = "correctness.option_after_code"
    public let name = "OPTION after code"
    public let rationale = "An OPTION changes how the lines around it are read, so one in the middle means the file has two halves that read differently."
    public let defaultSeverity = LintSeverity.warning
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        var sawCode = false
        var findings: [LintFinding] = []
        for node in tree.root.children {
            if node.kind == .optionStatement {
                if sawCode {
                    findings.append(context.finding(id, "this OPTION comes after code, so it does not apply to it", at: node.range))
                }
                continue
            }
            switch node.kind {
            case .comment, .label, .importDirective, .declaration, .typeDeclaration:
                continue
            default:
                sawCode = true
            }
        }
        return findings
    }
}

/// An `IMPORT` of a file that is not there.
public struct MissingImportRule: BASICLintRule {
    public let id = "correctness.missing_import"
    public let name = "IMPORT of a file that does not exist"
    public let rationale = "The program cannot run at all, and the linter can say so without running it."
    public let defaultSeverity = LintSeverity.error
    public init() {}

    public func check(program tree: LintTree, context: LintContext) -> [LintFinding] {
        let directory = (context.path as NSString).deletingLastPathComponent
        return context.facts.imports.compactMap { imported in
            // A bare name may be a library, which the linter cannot resolve.
            guard imported.name.contains("/") || imported.name.lowercased().hasSuffix(".bas") else { return nil }
            let path = (imported.name as NSString).isAbsolutePath
                ? imported.name
                : (directory as NSString).appendingPathComponent(imported.name)
            guard !FileManager.default.fileExists(atPath: path) else { return nil }
            return context.finding(id, "IMPORT cannot find \(imported.name)", at: imported.range)
        }
    }
}
