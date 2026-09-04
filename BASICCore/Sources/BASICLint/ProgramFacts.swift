import BASICSyntax
import Foundation

/// The parser's expression, named to keep Foundation's out of the way.
typealias BASICExpression = BASICSyntax.Expression

// What a whole-program rule needs, worked out once.
//
// "Used before it was assigned" and "declared and never used" are not
// properties of a statement, so counting them per rule would mean walking
// the program once per rule and getting subtly different answers. This walks
// it once and hands every rule the same view.

/// One name the program mentions, and where.
public struct NameUse: Sendable, Equatable {
    public let name: String
    public let range: LintRange
    /// The routine it appeared in, or nil for the main program.
    public let routine: String?
}

/// Everything the rules count.
public struct ProgramFacts: Sendable {
    /// Assignments and `DIM`s, in order.
    public let assigned: [NameUse]
    /// Reads, in order.
    public let read: [NameUse]
    /// `DIM`s, in order.
    public let dimensioned: [NameUse]
    /// Routines declared, by normalized name.
    public let routines: [String: NameUse]
    /// Routine calls, by normalized name.
    public let called: [NameUse]
    /// Labels declared, in order.
    public let labels: [NameUse]
    /// Labels and line numbers branched to, in order.
    public let branchTargets: [NameUse]
    /// Line numbers declared, in order.
    public let lineNumbers: [(number: Int, range: LintRange)]
    /// Parameters, by routine then name.
    public let parameters: [String: [NameUse]]
    /// How many `DATA` items the program holds, and how many `READ`s it does.
    public let dataItemCount: Int
    public let readTargetCount: Int
    /// Whether the program has an `ON ERROR` and a `RESUME`.
    public let hasErrorHandler: Bool
    public let resumes: [LintRange]
    /// Whether it has any `GOSUB`, for `RETURN` outside one.
    public let hasGosub: Bool
    /// `IMPORT`ed paths, with their ranges.
    public let imports: [NameUse]
    /// Every string literal in the program, uppercased. A control names its
    /// handler with a string (`button.onclick("Greet")`), so a routine
    /// spelled in one is a routine something calls.
    public let stringLiterals: Set<String>

    /// Names that are the language rather than the program: intrinsics,
    /// pseudo classes, pseudo variables, and the named constants. A rule
    /// asking "was this ever assigned?" must not ask it of `LEN` or `RAW`.
    public static let languageNames: Set<String> = {
        var names = BASICKeywords.all
        names.formUnion(BASICKeywords.intrinsicFunctionNames)
        names.formUnion(BASICKeywords.pseudoClasses)
        names.formUnion(BASICKeywords.pseudoVariables)
        names.formUnion(["READ", "WRITE", "BOTH", "RAW", "TEXT", "JSON", "NATIVE", "LITTLE", "BIG"])
        names.formUnion(["SCREENWIDTH", "SCREENHEIGHT", "CURRENTDIR$", "ERR", "ERL"])
        return Set(names.map { $0.uppercased() })
    }()

    /// Whether a name belongs to the language rather than to the program.
    public static func isLanguageName(_ name: String) -> Bool {
        languageNames.contains(name.uppercased())
    }

    /// Names a `DIM` or an assignment gave an `AS` type to.
    public let declaredTypes: Set<String>

    /// Whether a name was declared with a type anywhere.
    public func hasDeclaredType(_ name: String) -> Bool {
        declaredTypes.contains(name.uppercased())
    }

    /// Whether a name is ever assigned, anywhere.
    public func isAssigned(_ name: String) -> Bool {
        let key = name.uppercased()
        return assigned.contains { $0.name.uppercased() == key }
    }

    /// Whether a name is ever read, anywhere.
    public func isRead(_ name: String) -> Bool {
        let key = name.uppercased()
        return read.contains { $0.name.uppercased() == key }
    }

    /// Builds the facts for a tree.
    public static func build(_ tree: LintTree) -> ProgramFacts {
        var assigned: [NameUse] = []
        var read: [NameUse] = []
        var dimensioned: [NameUse] = []
        var routines: [String: NameUse] = [:]
        var called: [NameUse] = []
        var labels: [NameUse] = []
        var branchTargets: [NameUse] = []
        var lineNumbers: [(number: Int, range: LintRange)] = []
        var parameters: [String: [NameUse]] = [:]
        var dataItemCount = 0
        var readTargetCount = 0
        var hasErrorHandler = false
        var resumes: [LintRange] = []
        var hasGosub = false
        var imports: [NameUse] = []
        var stringLiterals: Set<String> = []
        var declaredTypes: Set<String> = []
        var routine: String?

        /// Records what a read writes into.
        func assign(_ target: ReadTarget, _ range: LintRange) {
            switch target {
            case .variable(let name):
                assigned.append(NameUse(name: name.name, range: range, routine: routine))
            case .reference(let reference):
                assigned.append(NameUse(name: reference.base.name, range: range, routine: routine))
            }
        }

        func note(_ expression: BASICExpression, _ range: LintRange) {
            for text in Self.strings(in: expression) { stringLiterals.insert(text.uppercased()) }
            for name in Self.names(in: expression) {
                read.append(NameUse(name: name, range: range, routine: routine))
            }
            for call in Self.calls(in: expression) {
                called.append(NameUse(name: call, range: range, routine: routine))
            }
        }

        for node in tree.root.descendants {
            let range = node.range
            guard let statement = node.statement else { continue }
            switch statement {
            case .functionDeclaration(let name, let functionParameters, _, _, _, _, _):
                routine = name.normalized
                routines[name.normalized] = NameUse(name: name.name, range: range, routine: nil)
                parameters[name.normalized] = functionParameters.map {
                    NameUse(name: $0.variable.name, range: range, routine: name.normalized)
                }
            case .endFunction:
                routine = nil
            case .assignment(_, let name, let declared, let value):
                assigned.append(NameUse(name: name.name, range: range, routine: routine))
                if declared != nil { declaredTypes.insert(name.normalized) }
                if let value { note(value, range) }
            case .closureAssignment(_, let name, _, _, _, _, _):
                assigned.append(NameUse(name: name.name, range: range, routine: routine))
            case .referenceAssignment(let reference, let value):
                assigned.append(NameUse(name: reference.base.name, range: range, routine: routine))
                if let value { note(value, range) }
            case .dim(_, let name, let dimensions, let declared):
                dimensioned.append(NameUse(name: name.name, range: range, routine: routine))
                if declared != nil { declaredTypes.insert(name.normalized) }
                assigned.append(NameUse(name: name.name, range: range, routine: routine))
                for dimension in dimensions.compactMap({ $0 }) { note(dimension, range) }
            case .forLoop(let variable, let start, let end, let step):
                assigned.append(NameUse(name: variable.name, range: range, routine: routine))
                note(start, range); note(end, range)
                if let step { note(step, range) }
            case .label(let name):
                labels.append(NameUse(name: name, range: range, routine: routine))
            case .goto(let number):
                branchTargets.append(NameUse(name: "\(number)", range: range, routine: routine))
            case .gotoLabel(let name):
                branchTargets.append(NameUse(name: name, range: range, routine: routine))
            case .gosub(let target), .onErrorGoto(.some(let target)):
                hasGosub = hasGosub || Self.isGosub(statement)
                if case .onErrorGoto = statement { hasErrorHandler = true }
                branchTargets.append(NameUse(name: Self.targetName(target), range: range, routine: routine))
            case .onErrorGoto(nil):
                hasErrorHandler = true
            case .computedGoto(let targets, let selector), .computedGosub(let targets, let selector):
                if case .computedGosub = statement { hasGosub = true }
                for target in targets {
                    branchTargets.append(NameUse(name: Self.targetName(target), range: range, routine: routine))
                }
                note(selector, range)
            case .resumeNext:
                resumes.append(range)
            case .data(let literals):
                dataItemCount += literals.count
            case .read(let targets):
                readTargetCount += targets.count
                for target in targets { assign(target, range) }
            case .importDirective(let path):
                imports.append(NameUse(name: path, range: range, routine: routine))
            case .onEventCall(_, let handler):
                // `ON RESIZE CALL Handler` is a call, written the other way up.
                called.append(NameUse(name: handler.name, range: range, routine: routine))
            case .onTimerEvent(_, let ticks, let handler):
                called.append(NameUse(name: handler.name, range: range, routine: routine))
                if let ticks { note(ticks, range) }
            case .print(let parts), .printFile(_, let parts), .putFile(_, let parts), .log(_, let parts):
                for part in parts {
                    if case .expression(let expression) = part { note(expression, range) }
                }
            case .expression(let expression), .returnValue(let expression), .blockIf(let expression),
                 .elseIf(let expression), .selectCase(let expression), .system(let expression),
                 .error(let expression), .background(let expression), .join(let expression),
                 .cancelTask(let expression), .screen(let expression), .draw(let expression):
                note(expression, range)
            case .ifThen(let condition, _, _):
                note(condition, range)
            case .input(let prompt, let target), .lineInput(let prompt, let target, _, _, _, _):
                if let prompt { note(prompt, range) }
                assign(target, range)
            case .lineInputFile(_, let target), .setFieldString(let target, _, _):
                // Reading into a variable assigns it, however the read is
                // spelled — from a file, a field, or a command's output.
                assign(target, range)
            case .inputFile(_, let targets), .getFile(_, let targets):
                for target in targets { assign(target, range) }
            default:
                break
            }
            if let number = tree.lines.first(where: { $0.sourceLineNumber == range.line })?.number {
                if !lineNumbers.contains(where: { $0.number == number }) {
                    lineNumbers.append((number, range))
                }
            }
        }

        return ProgramFacts(
            assigned: assigned, read: read, dimensioned: dimensioned, routines: routines,
            called: called, labels: labels, branchTargets: branchTargets, lineNumbers: lineNumbers,
            parameters: parameters, dataItemCount: dataItemCount, readTargetCount: readTargetCount,
            hasErrorHandler: hasErrorHandler, resumes: resumes, hasGosub: hasGosub, imports: imports,
            stringLiterals: stringLiterals, declaredTypes: declaredTypes
        )
    }

    private static func isGosub(_ statement: Statement) -> Bool {
        if case .gosub = statement { return true }
        return false
    }

    private static func targetName(_ target: BranchTarget) -> String {
        switch target {
        case .line(let number): return "\(number)"
        case .label(let name): return name
        }
    }

    /// Every variable an expression reads.
    static func names(in expression: BASICExpression) -> [String] {
        switch expression {
        case .variable(let name): return [name.name]
        case .variableReference(let reference): return [reference.base.name] + reference.indexes.flatMap(names(in:))
        case .unaryMinus(let inner), .await(let inner): return names(in: inner)
        case .binary(let left, _, let right): return names(in: left) + names(in: right)
        case .callOrArray(let name, let arguments), .functionCall(let name, let arguments):
            // `A(1)` is an array read or a call; both mention the name.
            return [name.name] + arguments.flatMap(names(in:))
        case .methodCall(let reference, _, let arguments):
            return [reference.base.name] + arguments.flatMap(names(in:))
        case .newObject(_, let arguments): return arguments.flatMap(names(in:))
        default: return []
        }
    }

    /// Every string literal in an expression.
    static func strings(in expression: BASICExpression) -> [String] {
        switch expression {
        case .string(let text), .interpolatedString(let text): return [text]
        case .unaryMinus(let inner), .await(let inner): return strings(in: inner)
        case .binary(let left, _, let right): return strings(in: left) + strings(in: right)
        case .callOrArray(_, let arguments), .functionCall(_, let arguments),
             .methodCall(_, _, let arguments), .newObject(_, let arguments):
            return arguments.flatMap(strings(in:))
        default: return []
        }
    }

    /// Every routine an expression calls.
    static func calls(in expression: BASICExpression) -> [String] {
        switch expression {
        case .callOrArray(let name, let arguments), .functionCall(let name, let arguments):
            return [name.name] + arguments.flatMap(calls(in:))
        case .unaryMinus(let inner), .await(let inner): return calls(in: inner)
        case .binary(let left, _, let right): return calls(in: left) + calls(in: right)
        case .methodCall(_, _, let arguments), .newObject(_, let arguments): return arguments.flatMap(calls(in:))
        case .variableReference(let reference): return reference.indexes.flatMap(calls(in:))
        default: return []
        }
    }
}
