import BASICSyntax
import Foundation

/// Decides the static type of every variable in a program.
///
/// BASIC never declares most variables, so the type comes from, in order:
/// an explicit `AS` type, the name's suffix (`$`, `%`, `#`), or the type of
/// what is assigned to it — iterated to a fixed point because `A = B` may
/// come before `B` is ever assigned. Anything still unknown at the end is a
/// number, which is what the interpreter's default value would make it.
///
/// A variable assigned both a string and a number is an error here; the
/// interpreter would allow it (variables can change type), but a compiled
/// program needs one slot type. `VARIANT` lowering lifts that later.
struct VariableTyper {
    /// The types found, keyed by normalized name.
    private(set) var types: [String: BIRType] = [:]
    /// Names seen without a decidable type yet, in first-seen order.
    private(set) var order: [String] = []
    private var diagnostics: [Diagnostic] = []

    /// Runs inference over the program.
    mutating func run(_ lines: [ParsedLine]) throws {
        var changed = true
        var pass = 0
        while changed {
            changed = false
            pass += 1
            for line in lines {
                try visit(line.statement, at: line, changed: &changed)
            }
            if pass > 100 { break }
        }
        for name in order where types[name] == nil {
            types[name] = .number
        }
        if !diagnostics.isEmpty {
            throw CompileError(diagnostics)
        }
    }

    /// The type of a variable by its normalized name; number when never seen.
    func type(of name: String) -> BIRType {
        types[name] ?? Self.suffixType(name) ?? .number
    }

    private mutating func visit(_ statement: Statement, at line: ParsedLine, changed: inout Bool) throws {
        switch statement {
        case .assignment(_, let name, let declared, let value):
            if let declared {
                try record(name, BIRTypeMapper.map(declared, for: name.name, at: line), at: line, changed: &changed)
            } else if let value, let type = try typeOf(value) {
                try record(name, type, at: line, changed: &changed)
            } else {
                note(name)
            }
        case .dim(_, let name, let dimensions, let declared) where dimensions.isEmpty:
            if let declared {
                try record(name, BIRTypeMapper.map(declared, for: name.name, at: line), at: line, changed: &changed)
            } else {
                note(name)
            }
        case .input(_, .variable(let name)):
            note(name)
        case .forLoop(let variable, _, _, _):
            try record(variable, .number, at: line, changed: &changed)
        case .ifThen(_, let thenAction, let elseAction):
            if case .statement(let inner) = thenAction { try visit(inner, at: line, changed: &changed) }
            if case .statement(let inner)? = elseAction { try visit(inner, at: line, changed: &changed) }
        case .labeled(_, let inner):
            try visit(inner, at: line, changed: &changed)
        case .sequence(let statements):
            for inner in statements { try visit(inner, at: line, changed: &changed) }
        default:
            break
        }
    }

    private mutating func note(_ name: VariableName) {
        let key = name.normalized
        if types[key] == nil, !order.contains(key) {
            order.append(key)
            if let suffix = Self.suffixType(key) { types[key] = suffix }
        }
    }

    private mutating func record(_ name: VariableName, _ type: BIRType, at line: ParsedLine, changed: inout Bool) throws {
        let key = name.normalized
        note(name)
        if let existing = types[key] {
            if existing != type {
                let location = BIRLocation(file: line.fileName, line: line.sourceLineNumber, statement: line.statementNumber, lineNumber: line.number)
                diagnostics.append(Diagnostic(
                    severity: .error, file: location.file, line: location.line,
                    message: "Type error: \(name.name) is used as both \(existing.rawValue) and \(type.rawValue); basicc needs one type per variable"
                ))
            }
            return
        }
        types[key] = type
        changed = true
    }

    /// The static type of an expression, or nil while it depends on a
    /// variable whose type is not known yet.
    func typeOf(_ expression: Expression) throws -> BIRType? {
        switch expression {
        case .number: return .number
        case .string, .interpolatedString: return .string
        case .boolean: return .boolean
        case .variable(let name):
            return types[name.normalized] ?? Self.suffixType(name.normalized)
        case .unaryMinus: return .number
        case .binary(let left, let operation, let right):
            switch operation {
            case .add:
                guard let l = try typeOf(left), let r = try typeOf(right) else { return nil }
                return (l == .string && r == .string) ? .string : .number
            case .subtract, .multiply, .divide, .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual, .and, .or:
                return .number
            }
        case .callOrArray(let name, let arguments), .functionCall(let name, let arguments):
            return BIRIntrinsic.lookup(name.normalized, argumentCount: arguments.count)?.returnType
        case .lenFunction: return .number
        case .chrFunction: return .string
        default: return nil
        }
    }

    /// The type a name's suffix dictates, if it has one.
    static func suffixType(_ normalizedName: String) -> BIRType? {
        switch normalizedName.last {
        case "$": return .string
        case "%", "#": return .number
        default: return nil
        }
    }
}

/// Maps BASIC's declared types onto BIR's.
enum BIRTypeMapper {
    static func map(_ type: BASICType, for name: String, at line: ParsedLine) throws -> BIRType {
        switch type {
        case .scalar(.integer), .scalar(.double): return .number
        case .scalar(.string): return .string
        case .scalar(.boolean): return .boolean
        default:
            throw CompileError(
                "\(name) AS \(type.name) is not supported by basicc yet",
                at: BIRLocation(file: line.fileName, line: line.sourceLineNumber, statement: line.statementNumber, lineNumber: line.number)
            )
        }
    }
}
