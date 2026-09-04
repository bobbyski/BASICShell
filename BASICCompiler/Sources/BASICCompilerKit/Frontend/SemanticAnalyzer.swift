import BASICSyntax
import Foundation

/// Builds the ``SemanticModel``: finds functions, decides scopes, and infers
/// every variable's type and storage.
///
/// Types come from, in order: an explicit `AS` type, the name's suffix
/// (`$`, `%`, `#`), or the type of what is assigned — iterated to a fixed
/// point because `A = B` may come before `B` is ever assigned. Anything
/// still unknown at the end is a number, which is what the interpreter's
/// default value would make it.
///
/// A variable used as two types, or as both a scalar and an array, is an
/// error here; the interpreter allows a variable to change type, but a
/// compiled program needs one slot type.
struct SemanticAnalyzer {
    let lines: [ParsedLine]
    let model = SemanticModel()
    private var diagnostics: [Diagnostic] = []
    /// Which function each line belongs to (nil = main); indexed by line.
    private(set) var owner: [String?] = []

    init(lines: [ParsedLine]) {
        self.lines = lines
    }

    /// Runs every pass; throws when anything is contradictory.
    mutating func run() throws -> SemanticModel {
        try collectFunctions()
        collectLocals()
        var changed = true
        var pass = 0
        while changed, pass < 100 {
            changed = false
            pass += 1
            for (index, line) in lines.enumerated() {
                try visit(line.statement, at: line, in: owner[index], changed: &changed)
            }
        }
        if !diagnostics.isEmpty { throw CompileError(diagnostics) }
        return model
    }

    // MARK: - Functions and scopes

    private mutating func collectFunctions() throws {
        owner = Array(repeating: nil, count: lines.count)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let location = Self.location(of: line)
            switch line.statement {
            case .functionDeclaration(let name, let parameters, let returnType, let isAsync, _, _, _):
                guard !isAsync else { throw CompileError("ASYNC FUNCTION is not supported by basicc yet", at: location) }
                guard let end = Self.matchingEndFunction(after: index, in: lines) else {
                    throw CompileError("FUNCTION without END FUNCTION", at: location)
                }
                guard model.functions[name.normalized] == nil else {
                    throw CompileError("Function \(name.name) is already defined", at: location)
                }
                let birParameters = try parameters.map {
                    BIRVariable(name: $0.variable.normalized, type: try Self.map($0.type, for: $0.variable.name, at: line), scope: .local)
                }
                let birReturn: BIRType = returnType == .void ? .void : try Self.map(returnType, for: name.name, at: line)
                model.addFunction(SemanticModel.Function(
                    name: name.normalized, displayName: name.name, parameters: birParameters,
                    returnType: birReturn, body: (index + 1)..<end, expression: nil, location: location
                ))
                for bodyIndex in index...end { owner[bodyIndex] = name.normalized }
                index = end + 1
                continue
            case .defFunction(let name, let parameter, let returnType, let body):
                let parameters = [BIRVariable(name: parameter.variable.normalized, type: try Self.map(parameter.type, for: parameter.variable.name, at: line), scope: .local)]
                model.addFunction(SemanticModel.Function(
                    name: name.normalized, displayName: name.name, parameters: parameters,
                    returnType: try Self.map(returnType, for: name.name, at: line), body: index..<index,
                    expression: body, location: location
                ))
                owner[index] = name.normalized
            case .endFunction:
                throw CompileError("END FUNCTION without FUNCTION", at: location)
            default:
                break
            }
            index += 1
        }
    }

    /// `LOCAL` declarations make a name local to its function.
    private mutating func collectLocals() {
        for (index, line) in lines.enumerated() {
            guard let function = owner[index] else { continue }
            Self.forEachStatement(in: line.statement) { statement in
                switch statement {
                case .assignment(.local, let name, _, _), .dim(.local, let name, _, _):
                    model.declareLocal(name.normalized, in: function)
                default:
                    break
                }
            }
        }
    }

    static func matchingEndFunction(after start: Int, in lines: [ParsedLine]) -> Int? {
        var index = start + 1
        while index < lines.count {
            if case .endFunction = lines[index].statement { return index }
            if case .functionDeclaration = lines[index].statement { return nil }
            index += 1
        }
        return nil
    }

    // MARK: - Typing

    private mutating func visit(_ statement: Statement, at line: ParsedLine, in function: String?, changed: inout Bool) throws {
        switch statement {
        case .assignment(_, let name, let declared, let value):
            if let declared {
                try record(name, .scalar, try Self.map(declared, for: name.name, at: line), at: line, in: function, changed: &changed)
            } else if let value, let type = try typeOf(value, in: function) {
                try record(name, .scalar, type, at: line, in: function, changed: &changed)
            } else {
                note(name, .scalar, at: line, in: function, changed: &changed)
            }
        case .referenceAssignment(let reference, let value):
            let storage: Storage = reference.indexes.isEmpty ? .scalar : .array(reference.indexes.count)
            if let value, let type = try typeOf(value, in: function) {
                try record(reference.base, storage, type, at: line, in: function, changed: &changed)
            } else {
                note(reference.base, storage, at: line, in: function, changed: &changed)
            }
        case .dim(_, let name, let dimensions, let declared):
            let storage: Storage = dimensions.isEmpty ? .scalar : .array(dimensions.count)
            if let declared {
                try record(name, storage, try Self.map(declared, for: name.name, at: line), at: line, in: function, changed: &changed)
            } else {
                note(name, storage, at: line, in: function, changed: &changed)
            }
            if !dimensions.isEmpty {
                model.update(name.normalized, in: function) { $0.wasDimensioned = true }
            }
        case .input(_, let target), .lineInput(_, let target, _, _, _, _):
            noteTarget(target, at: line, in: function, changed: &changed)
        case .read(let targets):
            for target in targets { noteTarget(target, at: line, in: function, changed: &changed) }
        case .forLoop(let variable, let start, let end, let step):
            try record(variable, .scalar, .number, at: line, in: function, changed: &changed)
            for expression in [start, end] + (step.map { [$0] } ?? []) { try noteReferences(in: expression, at: line, in: function, changed: &changed) }
        case .ifThen(let condition, let thenAction, let elseAction):
            try noteReferences(in: condition, at: line, in: function, changed: &changed)
            if case .statement(let inner) = thenAction { try visit(inner, at: line, in: function, changed: &changed) }
            if case .statement(let inner)? = elseAction { try visit(inner, at: line, in: function, changed: &changed) }
        case .labeled(_, let inner):
            try visit(inner, at: line, in: function, changed: &changed)
        case .sequence(let statements):
            for inner in statements { try visit(inner, at: line, in: function, changed: &changed) }
        case .print(let parts):
            for part in parts {
                if case .expression(let expression) = part { try noteReferences(in: expression, at: line, in: function, changed: &changed) }
            }
        case .expression(let expression), .returnValue(let expression), .selectCase(let expression), .blockIf(let expression), .elseIf(let expression):
            try noteReferences(in: expression, at: line, in: function, changed: &changed)
        case .caseClause(let clauses):
            for clause in clauses {
                switch clause {
                case .equals(let e), .comparison(_, let e): try noteReferences(in: e, at: line, in: function, changed: &changed)
                case .range(let lower, let upper):
                    try noteReferences(in: lower, at: line, in: function, changed: &changed)
                    try noteReferences(in: upper, at: line, in: function, changed: &changed)
                }
            }
        default:
            break
        }
    }

    private enum Storage { case scalar, array(Int) }

    private mutating func noteTarget(_ target: ReadTarget, at line: ParsedLine, in function: String?, changed: inout Bool) {
        switch target {
        case .variable(let name): note(name, .scalar, at: line, in: function, changed: &changed)
        case .reference(let reference):
            note(reference.base, reference.indexes.isEmpty ? .scalar : .array(reference.indexes.count), at: line, in: function, changed: &changed)
        }
    }

    /// Array references inside expressions decide that a name is an array.
    private mutating func noteReferences(in expression: Expression, at line: ParsedLine, in function: String?, changed: inout Bool) throws {
        switch expression {
        case .variable(let name):
            note(name, .scalar, at: line, in: function, changed: &changed)
        case .callOrArray(let name, let arguments):
            if model.functions[name.normalized] == nil, BIRIntrinsic.lookup(name.normalized, argumentCount: arguments.count) == nil,
               !BASICKeywords.intrinsicFunctionNames.contains(name.normalized), !arguments.isEmpty {
                note(name, .array(arguments.count), at: line, in: function, changed: &changed)
            }
            for argument in arguments { try noteReferences(in: argument, at: line, in: function, changed: &changed) }
        case .functionCall(_, let arguments):
            for argument in arguments { try noteReferences(in: argument, at: line, in: function, changed: &changed) }
        case .unaryMinus(let inner), .lenFunction(let inner), .chrFunction(let inner), .await(let inner):
            try noteReferences(in: inner, at: line, in: function, changed: &changed)
        case .binary(let left, _, let right):
            try noteReferences(in: left, at: line, in: function, changed: &changed)
            try noteReferences(in: right, at: line, in: function, changed: &changed)
        default:
            break
        }
    }

    private mutating func note(_ name: VariableName, _ storage: Storage, at line: ParsedLine, in function: String?, changed: inout Bool) {
        let key = name.normalized
        let before = model.info(key, in: function)
        model.update(key, in: function) { info in
            if case .array(let rank) = storage, info.rank == nil { info.rank = rank }
        }
        if before == nil || before?.rank != model.info(key, in: function)?.rank { changed = true }
        if case .array(let rank) = storage, let existing = before?.rank, existing != rank {
            diagnostics.append(Diagnostic(severity: .error, file: line.fileName, line: line.sourceLineNumber,
                message: "\(name.name) is used with \(existing) and \(rank) indexes"))
        }
    }

    private mutating func record(_ name: VariableName, _ storage: Storage, _ type: BIRType, at line: ParsedLine, in function: String?, changed: inout Bool) throws {
        note(name, storage, at: line, in: function, changed: &changed)
        let key = name.normalized
        if let existing = model.info(key, in: function)?.type {
            if existing != type {
                diagnostics.append(Diagnostic(severity: .error, file: line.fileName, line: line.sourceLineNumber,
                    message: "Type error: \(name.name) is used as both \(existing.rawValue) and \(type.rawValue); basicc needs one type per variable"))
            }
            return
        }
        model.update(key, in: function) { $0.type = type }
        changed = true
    }

    /// The static type of an expression, or nil while it depends on a
    /// variable whose type is not known yet.
    func typeOf(_ expression: Expression, in function: String?) throws -> BIRType? {
        switch expression {
        case .number: return .number
        case .string, .interpolatedString: return .string
        case .boolean: return .boolean
        case .variable(let name):
            return model.info(name.normalized, in: function)?.type ?? Self.suffixType(name.normalized)
        case .unaryMinus: return .number
        case .binary(let left, let operation, let right):
            switch operation {
            case .add:
                guard let l = try typeOf(left, in: function), let r = try typeOf(right, in: function) else { return nil }
                return (l == .string && r == .string) ? .string : .number
            default:
                return .number
            }
        case .callOrArray(let name, let arguments), .functionCall(let name, let arguments):
            if let userFunction = model.functions[name.normalized] { return userFunction.returnType }
            if let intrinsic = BIRIntrinsic.lookup(name.normalized, argumentCount: arguments.count) { return intrinsic.returnType }
            return model.info(name.normalized, in: function)?.type ?? Self.suffixType(name.normalized)
        case .lenFunction: return .number
        case .chrFunction: return .string
        default: return nil
        }
    }

    // MARK: - Helpers

    /// The type a name's suffix dictates, if it has one.
    static func suffixType(_ normalizedName: String) -> BIRType? {
        switch normalizedName.last {
        case "$": return .string
        case "%", "#": return .number
        default: return nil
        }
    }

    static func location(of line: ParsedLine) -> BIRLocation {
        BIRLocation(file: line.fileName, line: line.sourceLineNumber, statement: line.statementNumber, lineNumber: line.number)
    }

    /// Maps BASIC's declared types onto BIR's.
    static func map(_ type: BASICType, for name: String, at line: ParsedLine) throws -> BIRType {
        switch type {
        case .scalar(.integer), .scalar(.double): return .number
        case .scalar(.string): return .string
        case .scalar(.boolean): return .boolean
        case .void: return .void
        default:
            throw CompileError("\(name) AS \(type.name) is not supported by basicc yet", at: location(of: line))
        }
    }

    /// Visits a statement and the statements nested in it.
    static func forEachStatement(in statement: Statement, _ body: (Statement) -> Void) {
        body(statement)
        switch statement {
        case .labeled(_, let inner): forEachStatement(in: inner, body)
        case .sequence(let statements): statements.forEach { forEachStatement(in: $0, body) }
        case .ifThen(_, let thenAction, let elseAction):
            if case .statement(let inner) = thenAction { forEachStatement(in: inner, body) }
            if case .statement(let inner)? = elseAction { forEachStatement(in: inner, body) }
        default: break
        }
    }
}
