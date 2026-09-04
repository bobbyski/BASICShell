import BASICSyntax
import Foundation

/// Builds the ``SemanticModel``: finds types, functions, and methods; decides
/// scopes; and infers every variable's type and storage.
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
    /// Which function each line belongs to (nil = main; `declaration` for
    /// the inside of a TYPE/CLASS/INTERFACE, which nothing executes).
    private(set) var owner: [String?] = []
    static let declaration = "$declaration"

    init(lines: [ParsedLine]) {
        self.lines = lines
    }

    /// Runs every pass; throws when anything is contradictory.
    mutating func run() throws -> SemanticModel {
        owner = Array(repeating: nil, count: lines.count)
        try collectTypeNames()
        try collectTypeMembers()
        try collectFunctions()
        collectLocals()
        var changed = true
        var pass = 0
        while changed, pass < 100 {
            changed = false
            pass += 1
            for (index, line) in lines.enumerated() where owner[index] != Self.declaration {
                try visit(line.statement, at: line, in: owner[index], changed: &changed)
            }
        }
        if !diagnostics.isEmpty { throw CompileError(diagnostics) }
        return model
    }

    // MARK: - Types

    /// First pass over TYPE/CLASS/INTERFACE: names and indexes only, so
    /// fields can name types declared later.
    private mutating func collectTypeNames() throws {
        var index = 0
        var typeIndex = 0
        while index < lines.count {
            let line = lines[index]
            let location = Self.location(of: line)
            let kind: SemanticModel.CompositeType.Kind
            let name: String
            switch line.statement {
            case .typeDeclaration(let typeName): kind = .record; name = typeName
            case .classDeclaration(let className): kind = .classType; name = className
            case .interfaceDeclaration(let interfaceName): kind = .interface; name = interfaceName
            default: index += 1; continue
            }
            guard let end = Self.matchingEnd(of: kind, after: index, in: lines) else {
                throw CompileError("\(Self.keyword(kind)) without END \(Self.keyword(kind))", at: location)
            }
            guard model.types[name.uppercased()] == nil else {
                throw CompileError("\(Self.keyword(kind)) \(name) is already defined", at: location)
            }
            model.addType(SemanticModel.CompositeType(
                name: name.uppercased(), displayName: name, kind: kind,
                index: kind == .interface ? -1 : typeIndex,
                fields: [], methods: [:], base: nil, interfaces: [], members: [:], location: location
            ))
            if kind != .interface { typeIndex += 1 }
            for bodyIndex in index...end { owner[bodyIndex] = Self.declaration }
            index = end + 1
        }
    }

    /// Second pass: fields, bases, interfaces, interface members, methods.
    private mutating func collectTypeMembers() throws {
        for typeName in model.typeOrder {
            let type = model.types[typeName]!
            guard let start = lines.firstIndex(where: { Self.location(of: $0) == type.location }) else { continue }
            var index = start + 1
            while index < lines.count {
                let line = lines[index]
                let location = Self.location(of: line)
                switch line.statement {
                case .endType, .endClass, .endInterface:
                    index = lines.count
                    continue
                case .typeField(let fieldName, let fieldType, _, let dimensions, _, _, let defaultValue),
                     .classField(let fieldName, let fieldType, _, let dimensions, _, _, let defaultValue):
                    guard dimensions.isEmpty else { throw CompileError("array fields in \(type.displayName) are not supported by basicc yet", at: location) }
                    var visibility = BASICMemberVisibility.public
                    if case .classField(_, _, let declared, _, _, _, _) = line.statement { visibility = declared }
                    let resolved = try map(fieldType, for: fieldName, at: line)
                    var defaultNumber: Double?
                    var defaultString: String?
                    switch defaultValue {
                    case .number(let value)?: defaultNumber = value
                    case .boolean(let value)?: defaultNumber = value ? 1 : 0
                    case .string(let value)?: defaultString = value
                    default: break
                    }
                    model.updateType(typeName) {
                        $0.fields.append(SemanticModel.Field(
                            name: fieldName.uppercased(), displayName: fieldName, type: resolved,
                            visibility: visibility, owner: typeName, defaultNumber: defaultNumber, defaultString: defaultString
                        ))
                    }
                case .inheritsDeclaration(let baseName):
                    guard model.types[baseName.uppercased()]?.kind == .classType else {
                        throw CompileError("CLASS \(type.displayName) inherits unknown CLASS \(baseName)", at: location)
                    }
                    model.updateType(typeName) { $0.base = baseName.uppercased() }
                case .implementsDeclaration(let interfaceName):
                    guard model.types[interfaceName.uppercased()]?.kind == .interface else {
                        throw CompileError("CLASS \(type.displayName) implements unknown INTERFACE \(interfaceName)", at: location)
                    }
                    model.updateType(typeName) { $0.interfaces.append(interfaceName.uppercased()) }
                case .interfaceFunctionSignature(let name, let parameters, let returnType):
                    let parameterTypes = try parameters.map { try map($0.type, for: $0.variable.name, at: line) }
                    let resolvedReturn: BIRType = returnType == .void ? .void : try map(returnType, for: name.name, at: line)
                    model.updateType(typeName) { $0.members[name.normalized] = (parameterTypes, resolvedReturn) }
                case .functionDeclaration(let name, let parameters, let returnType, _, _, _, _) where type.kind == .interface:
                    // The parser does not know it is inside an INTERFACE; a
                    // FUNCTION line there is a member signature.
                    let parameterTypes = try parameters.map { try map($0.type, for: $0.variable.name, at: line) }
                    let resolvedReturn: BIRType = returnType == .void ? .void : try map(returnType, for: name.name, at: line)
                    model.updateType(typeName) { $0.members[name.normalized] = (parameterTypes, resolvedReturn) }
                case .functionDeclaration(let name, let parameters, let returnType, let isAsync, let visibility, _, let explicit):
                    guard !isAsync else { throw CompileError("ASYNC FUNCTION is not supported by basicc yet", at: location) }
                    guard let end = Self.matchingEndFunction(after: index, in: lines) else {
                        throw CompileError("FUNCTION without END FUNCTION", at: location)
                    }
                    let functionName = "\(typeName).\(name.normalized)"
                    var birParameters = [BIRVariable(name: "ME", type: .composite(typeName), scope: .local)]
                    birParameters += try parameters.map {
                        BIRVariable(name: $0.variable.normalized, type: try map($0.type, for: $0.variable.name, at: line), scope: .local)
                    }
                    let birReturn: BIRType = returnType == .void ? .void : try map(returnType, for: name.name, at: line)
                    model.addFunction(SemanticModel.Function(
                        name: functionName, displayName: name.name, parameters: birParameters, returnType: birReturn,
                        body: (index + 1)..<end, expression: nil, location: location, owner: typeName,
                        visibility: visibility, explicitImplementations: explicit
                    ))
                    model.updateType(typeName) { $0.methods[name.normalized] = functionName }
                    for bodyIndex in index...end { owner[bodyIndex] = functionName }
                    index = end
                case .empty, .remark:
                    break
                default:
                    throw CompileError("Unexpected statement inside \(Self.keyword(type.kind)) \(type.displayName)", at: location)
                }
                index += 1
            }
        }
        // A method line is owned by its function; the declaration's own line
        // and END FUNCTION stay declaration-owned so main never runs them.
        for (index, line) in lines.enumerated() {
            if case .functionDeclaration = line.statement, let function = owner[index], model.functions[function]?.owner != nil {
                owner[index] = Self.declaration
            }
            if case .endFunction = line.statement, let function = owner[index], model.functions[function]?.owner != nil {
                owner[index] = Self.declaration
            }
        }
    }

    static func keyword(_ kind: SemanticModel.CompositeType.Kind) -> String {
        switch kind {
        case .record: return "TYPE"
        case .classType: return "CLASS"
        case .interface: return "INTERFACE"
        }
    }

    static func matchingEnd(of kind: SemanticModel.CompositeType.Kind, after start: Int, in lines: [ParsedLine]) -> Int? {
        var index = start + 1
        while index < lines.count {
            switch (kind, lines[index].statement) {
            case (.record, .endType), (.classType, .endClass), (.interface, .endInterface): return index
            case (.record, .typeDeclaration), (.classType, .classDeclaration), (.interface, .interfaceDeclaration): return nil
            default: index += 1
            }
        }
        return nil
    }

    // MARK: - Functions and scopes

    private mutating func collectFunctions() throws {
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let location = Self.location(of: line)
            guard owner[index] == nil else { index += 1; continue }
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
                    BIRVariable(name: $0.variable.normalized, type: try map($0.type, for: $0.variable.name, at: line), scope: .local)
                }
                let birReturn: BIRType = returnType == .void ? .void : try map(returnType, for: name.name, at: line)
                model.addFunction(SemanticModel.Function(
                    name: name.normalized, displayName: name.name, parameters: birParameters,
                    returnType: birReturn, body: (index + 1)..<end, expression: nil, location: location,
                    owner: nil, visibility: .public, explicitImplementations: []
                ))
                for bodyIndex in index...end { owner[bodyIndex] = name.normalized }
                index = end + 1
                continue
            case .defFunction(let name, let parameter, let returnType, let body):
                let parameters = [BIRVariable(name: parameter.variable.normalized, type: try map(parameter.type, for: parameter.variable.name, at: line), scope: .local)]
                model.addFunction(SemanticModel.Function(
                    name: name.normalized, displayName: name.name, parameters: parameters,
                    returnType: try map(returnType, for: name.name, at: line), body: index..<index,
                    expression: body, location: location, owner: nil, visibility: .public, explicitImplementations: []
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
            guard let function = owner[index], function != Self.declaration else { continue }
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
                try record(name, .scalar, try map(declared, for: name.name, at: line), at: line, in: function, changed: &changed)
            } else if let value, let type = try typeOf(value, in: function) {
                try record(name, .scalar, type, at: line, in: function, changed: &changed)
            } else {
                note(name, .scalar, at: line, in: function, changed: &changed)
            }
            if let value { try noteReferences(in: value, at: line, in: function, changed: &changed) }
        case .referenceAssignment(let reference, let value):
            let storage: Storage = reference.indexes.isEmpty ? .scalar : .array(reference.indexes.count)
            if reference.fields.isEmpty, let value, let type = try typeOf(value, in: function) {
                try record(reference.base, storage, type, at: line, in: function, changed: &changed)
            } else {
                note(reference.base, storage, at: line, in: function, changed: &changed)
            }
            for index in reference.indexes { try noteReferences(in: index, at: line, in: function, changed: &changed) }
            if let value { try noteReferences(in: value, at: line, in: function, changed: &changed) }
        case .dim(_, let name, let dimensions, let declared):
            let storage: Storage = dimensions.isEmpty ? .scalar : .array(dimensions.count)
            if let declared {
                try record(name, storage, try map(declared, for: name.name, at: line), at: line, in: function, changed: &changed)
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
        case .printUsing(let format, let values, _):
            for expression in [format] + values { try noteReferences(in: expression, at: line, in: function, changed: &changed) }
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
        case .variableReference(let reference):
            note(reference.base, reference.indexes.isEmpty ? .scalar : .array(reference.indexes.count), at: line, in: function, changed: &changed)
            for index in reference.indexes { try noteReferences(in: index, at: line, in: function, changed: &changed) }
        case .methodCall(let reference, _, let arguments):
            note(reference.base, reference.indexes.isEmpty ? .scalar : .array(reference.indexes.count), at: line, in: function, changed: &changed)
            for argument in arguments { try noteReferences(in: argument, at: line, in: function, changed: &changed) }
        case .newObject(_, let arguments):
            for argument in arguments { try noteReferences(in: argument, at: line, in: function, changed: &changed) }
        case .interpolatedString(let template), .string(let template):
            for inner in Self.interpolatedExpressions(in: template) {
                try noteReferences(in: inner, at: line, in: function, changed: &changed)
            }
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
        if key == "ERR" || key == "ERL" { return }
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
            if existing != type, !model.isAssignable(type, to: existing) {
                diagnostics.append(Diagnostic(severity: .error, file: line.fileName, line: line.sourceLineNumber,
                    message: "Type error: \(name.name) is used as both \(existing.name) and \(type.name); basicc needs one type per variable"))
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
            if name.normalized == "ERR" || name.normalized == "ERL" { return .number }
            return model.info(name.normalized, in: function)?.type ?? Self.suffixType(name.normalized)
        case .variableReference(let reference):
            guard var type = model.info(reference.base.normalized, in: function)?.type ?? Self.suffixType(reference.base.normalized) else { return nil }
            for field in reference.fields {
                guard case .composite(let typeName) = type, let found = model.field(field.uppercased(), of: typeName) else { return nil }
                type = found.field.type
            }
            return type
        case .newObject(let name, _):
            return model.types[name.uppercased()].map { _ in .composite(name.uppercased()) }
        case .methodCall(let reference, let method, _):
            guard let receiverType = try typeOf(.variableReference(reference), in: function),
                  case .composite(let typeName) = receiverType else { return nil }
            if let member = model.types[typeName]?.members[method.normalized] { return member.returnType }
            return model.lookupMethod(method.normalized, in: typeName)?.returnType
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

    /// Maps BASIC's declared types onto BIR's, resolving record, class, and
    /// interface names through the model.
    func map(_ type: BASICType, for name: String, at line: ParsedLine) throws -> BIRType {
        switch type {
        case .scalar(.integer), .scalar(.double): return .number
        case .scalar(.string): return .string
        case .scalar(.boolean): return .boolean
        case .void: return .void
        case .record(let typeName), .classType(let typeName), .interfaceType(let typeName):
            guard model.types[typeName.uppercased()] != nil else {
                throw CompileError("\(name) AS \(typeName): unknown TYPE, CLASS, or INTERFACE", at: Self.location(of: line))
            }
            return .composite(typeName.uppercased())
        default:
            throw CompileError("\(name) AS \(type.name) is not supported by basicc yet", at: Self.location(of: line))
        }
    }

    /// The expressions inside a template's `${…}` pieces that parse.
    static func interpolatedExpressions(in template: String) -> [Expression] {
        guard template.contains("${") else { return [] }
        var expressions: [Expression] = []
        var index = template.startIndex
        while let start = template[index...].range(of: "${") {
            guard let end = template[start.upperBound...].firstIndex(of: "}") else { break }
            let source = String(template[start.upperBound..<end])
            if var parser = try? Parser(source: source), let expression = try? parser.parseExpressionOnly() {
                expressions.append(expression)
            }
            index = template.index(after: end)
        }
        return expressions
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
