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
    let model: SemanticModel
    private var diagnostics: [Diagnostic] = []
    /// Which function each line belongs to (nil = main; `declaration` for
    /// the inside of a TYPE/CLASS/INTERFACE, which nothing executes).
    private(set) var owner: [String?] = []
    static let declaration = "$declaration"

    init(lines: [ParsedLine], model: SemanticModel = SemanticModel()) {
        self.lines = lines
        self.model = model
    }

    /// `map` for callers that hold a finished model (the builder).
    static func mapWithModel(_ model: SemanticModel, _ type: BASICType, for name: String, at line: ParsedLine) throws -> BIRType {
        try SemanticAnalyzer(lines: [], model: model).map(type, for: name, at: line)
    }

    /// Runs every pass; throws when anything is contradictory.
    mutating func run() throws -> SemanticModel {
        owner = Array(repeating: nil, count: lines.count)
        try collectTypeNames()
        try collectTypeMembers()
        try collectSignatures()
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
                case .typeField(let fieldName, let fieldType, _, let dimensions, let json, let metadata, let defaultValue),
                     .classField(let fieldName, let fieldType, _, let dimensions, let json, let metadata, let defaultValue):
                    var visibility = BASICMemberVisibility.public
                    if case .classField(_, _, let declared, _, _, _, _) = line.statement { visibility = declared }
                    var resolved = try map(fieldType, for: fieldName, at: line)
                    if !dimensions.isEmpty { resolved = .array(resolved, rank: dimensions.count) }
                    func literal(_ value: BASICLiteral) -> BIRDefault {
                        switch value {
                        case .number(let value): return .number(value)
                        case .boolean(let value): return .boolean(value)
                        case .string(let value): return .string(value)
                        case .null: return .null
                        case .empty: return .empty
                        }
                    }
                    let defaultLiteral = defaultValue.map(literal)
                    model.updateType(typeName) {
                        $0.fields.append(SemanticModel.Field(
                            name: fieldName.uppercased(), displayName: fieldName, type: resolved,
                            visibility: visibility, owner: typeName, dimensions: dimensions,
                            jsonName: json?.name, defaultValue: defaultLiteral,
                            isInteger: fieldType == .scalar(.integer),
                            metadata: metadata.mapValues(literal)
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

    /// `FUNCTION TYPE Name(params) AS type` declarations, anywhere at top level.
    private mutating func collectSignatures() throws {
        for (index, line) in lines.enumerated() where owner[index] == nil {
            guard case .functionTypeDeclaration(let name, let parameters, let returnType, let isAsync) = line.statement else { continue }
            guard !isAsync else { throw CompileError("ASYNC FUNCTION TYPE is not supported by basicc yet", at: Self.location(of: line)) }
            let parameterTypes = try parameters.map { try map($0.type, for: $0.variable.name, at: line) }
            let resolvedReturn: BIRType = returnType == .void ? .void : try map(returnType, for: name, at: line)
            model.addSignature(name: name.uppercased(), parameters: parameterTypes, returnType: resolvedReturn)
            owner[index] = Self.declaration
        }
    }

    /// The closure type of a closure literal, from its own declared shape.
    func closureType(parameters: [FunctionParameter], returnType: BASICType, at line: ParsedLine) throws -> BIRType {
        let parameterTypes = try parameters.map { try map($0.type, for: $0.variable.name, at: line) }
        guard returnType != .scalar(.variant) else {
            throw CompileError("a closure needs AS <type>; basicc cannot infer VARIANT", at: Self.location(of: line))
        }
        let resolvedReturn: BIRType = returnType == .void ? .void : try map(returnType, for: "closure", at: line)
        let canonical = SemanticModel.canonicalSignature(parameters: parameterTypes, returnType: resolvedReturn)
        model.addSignature(name: canonical, parameters: parameterTypes, returnType: resolvedReturn)
        return .closure(canonical)
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

    /// `LOCAL` declarations make a name local to its function — and under
    /// `OPTION LOCAL-LET` (anywhere in the program body; the interpreter's
    /// switch is global), so does every plain assignment, DIM, INPUT, READ,
    /// and FOR inside a function. `GLOBAL x = …` stays global either way.
    private mutating func collectLocals() {
        let localLet = lines.enumerated().contains { index, line in
            guard owner[index] == nil else { return false }
            var found = false
            Self.forEachStatement(in: line.statement) { if case .optionLetMode(.local) = $0 { found = true } }
            return found
        }
        model.usesLocalLet = localLet
        for (index, line) in lines.enumerated() {
            guard let function = owner[index], function != Self.declaration else { continue }
            Self.forEachStatement(in: line.statement) { statement in
                switch statement {
                case .assignment(.local, let name, _, _), .dim(.local, let name, _, _):
                    model.declareLocal(name.normalized, in: function)
                case .assignment(.bare, let name, _, _), .assignment(.letValue, let name, _, _),
                     .dim(.bare, let name, _, _), .dim(.letValue, let name, _, _), .forLoop(let name, _, _, _):
                    if localLet { model.declareLocal(name.normalized, in: function) }
                case .input(_, .variable(let name)), .lineInput(_, .variable(let name), _, _, _, _):
                    if localLet { model.declareLocal(name.normalized, in: function) }
                case .read(let targets):
                    if localLet {
                        for case .variable(let name) in targets { model.declareLocal(name.normalized, in: function) }
                    }
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
            if let function, model.functions[function]?.returnType != .void,
               name.normalized == function.split(separator: ".").last.map(String.init) {
                // `Name = value` inside FUNCTION Name sets the result, not a variable.
                if let value { try noteReferences(in: value, at: line, in: function, changed: &changed) }
                return
            }
            if let declared {
                try record(name, .scalar, try map(declared, for: name.name, at: line), at: line, in: function, changed: &changed)
                if declared == .scalar(.integer) { model.update(name.normalized, in: function) { $0.isInteger = true } }
            } else if let value, let type = try typeOf(value, in: function) {
                try record(name, .scalar, type, at: line, in: function, changed: &changed)
            } else {
                note(name, .scalar, at: line, in: function, changed: &changed)
            }
            if let value { try noteReferences(in: value, at: line, in: function, changed: &changed) }
        case .closureAssignment(_, let name, let declared, let parameters, let returnType, let captures, let body):
            if let declared {
                try record(name, .scalar, try map(declared, for: name.name, at: line), at: line, in: function, changed: &changed)
            } else {
                try record(name, .scalar, try closureType(parameters: parameters, returnType: returnType, at: line), at: line, in: function, changed: &changed)
            }
            noteClosureReferences(parameters: parameters, captures: captures, names: body.flatMap { Self.freeVariables(in: $0.statement, model: model) }, bodyLines: body, at: line, in: function, changed: &changed)
        case .referenceAssignment(let reference, let value):
            let knownBase = model.info(reference.base.normalized, in: function)?.type
            let indexesKeyed = knownBase == .dictionary || knownBase == .variant
            let storage: Storage = reference.indexes.isEmpty || indexesKeyed ? .scalar : .array(reference.indexes.count)
            if reference.fields.isEmpty, !indexesKeyed, let value, let type = try typeOf(value, in: function) {
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
                if declared == .scalar(.integer) { model.update(name.normalized, in: function) { $0.isInteger = true } }
            } else {
                note(name, storage, at: line, in: function, changed: &changed)
            }
            if !dimensions.isEmpty {
                model.update(name.normalized, in: function) { $0.wasDimensioned = true }
            }
        case .fieldFile(_, let fields):
            for field in fields {
                try record(field.variable, .scalar, .string, at: line, in: function, changed: &changed)
                if !model.fieldVariables.contains(field.variable.normalized) { model.fieldVariables.append(field.variable.normalized) }
            }
        case .setFieldString(.variable(let name), let value, _):
            try record(name, .scalar, .string, at: line, in: function, changed: &changed)
            try noteReferences(in: value, at: line, in: function, changed: &changed)
        case .input(_, let target):
            noteTarget(target, at: line, in: function, changed: &changed)
        case .lineInput(let prompt, let target, let exitTarget, let length, let maximum, let defaultText):
            noteTarget(target, at: line, in: function, changed: &changed)
            if let exitTarget { noteTarget(exitTarget, at: line, in: function, changed: &changed) }
            for expression in [prompt, length, maximum, defaultText].compactMap({ $0 }) { try noteReferences(in: expression, at: line, in: function, changed: &changed) }
        case .locate(let row, let column):
            try noteReferences(in: row, at: line, in: function, changed: &changed)
            try noteReferences(in: column, at: line, in: function, changed: &changed)
        case .screen(let mode), .draw(let mode):
            try noteReferences(in: mode, at: line, in: function, changed: &changed)
        case .color(let colors):
            for color in colors { try noteReferences(in: color, at: line, in: function, changed: &changed) }
        case .pset(let point, let color), .preset(let point, let color):
            for expression in [point.x, point.y] + (color.map { [$0] } ?? []) { try noteReferences(in: expression, at: line, in: function, changed: &changed) }
        case .line(let start, let end, let color):
            for expression in [start.x, start.y, end.x, end.y] + (color.map { [$0] } ?? []) { try noteReferences(in: expression, at: line, in: function, changed: &changed) }
        case .circle(let center, let radius, let color, let aspect):
            for expression in [center.x, center.y, radius] + [color, aspect].compactMap({ $0 }) { try noteReferences(in: expression, at: line, in: function, changed: &changed) }
        case .paint(let point, let color, let border):
            for expression in [point.x, point.y, color] + (border.map { [$0] } ?? []) { try noteReferences(in: expression, at: line, in: function, changed: &changed) }
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
        case .expression(let expression), .returnValue(let expression), .selectCase(let expression), .blockIf(let expression), .elseIf(let expression), .system(let expression):
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
            let knownBase = model.info(reference.base.normalized, in: function)?.type
            let indexesKeyed = knownBase == .dictionary || knownBase == .variant
            note(reference.base, reference.indexes.isEmpty || indexesKeyed ? .scalar : .array(reference.indexes.count), at: line, in: function, changed: &changed)
            for index in reference.indexes { try noteReferences(in: index, at: line, in: function, changed: &changed) }
            for index in reference.fieldIndexes.flatMap({ $0 }) { try noteReferences(in: index, at: line, in: function, changed: &changed) }
        case .methodCall(let reference, _, let arguments):
            // `File.X` names the shared file service unless a variable FILE exists.
            if reference.base.normalized != "FILE" || model.info("FILE", in: function) != nil {
                note(reference.base, reference.indexes.isEmpty ? .scalar : .array(reference.indexes.count), at: line, in: function, changed: &changed)
            }
            for argument in arguments { try noteReferences(in: argument, at: line, in: function, changed: &changed) }
        case .newObject(_, let arguments):
            for argument in arguments { try noteReferences(in: argument, at: line, in: function, changed: &changed) }
        case .interpolatedString(let template), .string(let template):
            for inner in Self.interpolatedExpressions(in: template) {
                try noteReferences(in: inner, at: line, in: function, changed: &changed)
            }
        case .callOrArray(let name, let arguments):
            let known = model.info(name.normalized, in: function)?.type
            if model.functions[name.normalized] == nil, BIRIntrinsic.lookup(name.normalized, argumentCount: arguments.count) == nil,
               !BASICKeywords.intrinsicFunctionNames.contains(name.normalized), !arguments.isEmpty, known?.isClosure != true,
               known != .dictionary, known != .variant,
               !(SemanticModel.systemClasses[name.normalized] != nil && known == nil) {
                note(name, .array(arguments.count), at: line, in: function, changed: &changed)
            }
            for argument in arguments { try noteReferences(in: argument, at: line, in: function, changed: &changed) }
        case .closure(let parameters, _, let captures, let body):
            noteClosureReferences(parameters: parameters, captures: captures, names: Self.freeVariables(in: body, model: model), bodyLines: [], at: line, in: function, changed: &changed)
        case .functionCall(_, let arguments):
            for argument in arguments { try noteReferences(in: argument, at: line, in: function, changed: &changed) }
        case .unaryMinus(let inner), .lenFunction(let inner), .chrFunction(let inner), .await(let inner), .systemFunction(let inner), .environmentFunction(let inner):
            try noteReferences(in: inner, at: line, in: function, changed: &changed)
        case .pointFunction(let point):
            try noteReferences(in: point.x, at: line, in: function, changed: &changed)
            try noteReferences(in: point.y, at: line, in: function, changed: &changed)
        case .binary(let left, _, let right):
            try noteReferences(in: left, at: line, in: function, changed: &changed)
            try noteReferences(in: right, at: line, in: function, changed: &changed)
        default:
            break
        }
    }

    /// A closure body's free names — captured or live — are variables of the
    /// creating scope; its parameters and LOCALs are not.
    private mutating func noteClosureReferences(parameters: [FunctionParameter], captures: [ClosureCaptureSpec], names: [String], bodyLines: [ClosureBodyLine], at line: ParsedLine, in function: String?, changed: inout Bool) {
        var excluded = Set(parameters.map { $0.variable.normalized })
        for bodyLine in bodyLines {
            Self.forEachStatement(in: bodyLine.statement) { statement in
                if case .assignment(.local, let name, _, _) = statement { excluded.insert(name.normalized) }
                if case .dim(.local, let name, _, _) = statement { excluded.insert(name.normalized) }
            }
        }
        for capture in captures where !excluded.contains(capture.variable.normalized) {
            note(capture.variable, .scalar, at: line, in: function, changed: &changed)
        }
        for name in names where !excluded.contains(name) {
            note(VariableName(name: name, column: 0), .scalar, at: line, in: function, changed: &changed)
        }
    }

    private mutating func note(_ name: VariableName, _ storage: Storage, at line: ParsedLine, in function: String?, changed: inout Bool) {
        let key = name.normalized
        if key == "ERR" || key == "ERL" { return }
        if SemanticModel.namedConstants.contains(key), case .scalar = storage, model.info(key, in: function) == nil { return }
        if SemanticModel.hostVariables[key] != nil, case .scalar = storage, model.info(key, in: function) == nil { return }
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
            // A VARIANT meeting a static type is a runtime coercion, not a
            // conflict: the slot keeps the type it had.
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
            if let known = model.info(name.normalized, in: function)?.type { return known }
            if SemanticModel.namedConstants.contains(name.normalized) { return .string }
            if let host = SemanticModel.hostVariables[name.normalized] { return host }
            return Self.suffixType(name.normalized)
        case .variableReference(let reference):
            guard var type = model.info(reference.base.normalized, in: function)?.type ?? Self.suffixType(reference.base.normalized) else { return nil }
            if !reference.indexes.isEmpty, type == .dictionary || type == .variant { return .variant }
            for (position, field) in reference.fields.enumerated() {
                if type == .variant { return .variant }
                if case .system(let typeName) = type { return SemanticModel.systemMember(field.uppercased(), of: typeName)?.returns }
                guard case .composite(let typeName) = type, let found = model.field(field.uppercased(), of: typeName) else { return nil }
                type = found.field.type
                if reference.fieldIndexes.indices.contains(position), !reference.fieldIndexes[position].isEmpty {
                    guard let element = type.elementType else { return nil }
                    type = element
                }
            }
            return type
        case .null: return .variant
        case .newObject(let name, _):
            if SemanticModel.systemClasses[name.uppercased()] != nil, model.types[name.uppercased()] == nil { return .system(name.uppercased() == "VTG" ? "VECTORTERMINAL" : name.uppercased()) }
            return model.types[name.uppercased()].map { _ in .composite(name.uppercased()) }
        case .methodCall(let reference, let method, let arguments):
            if reference.base.normalized == "FILE", model.info("FILE", in: function) == nil {
                switch method.normalized {
                case "CWD", "CWD$", "READTEXT", "READTEXT$", "READBYTES", "READBYTES$": return .string
                case "EXISTS", "ISDIR": return .boolean
                case "FILES", "FILES$", "READJSON": return .variant
                default: return .void
                }
            }
            guard let receiverType = try typeOf(.variableReference(reference), in: function) else { return nil }
            if receiverType == .variant { return .variant }
            if case .system(let typeName) = receiverType { return SemanticModel.systemMember(method.normalized, of: typeName)?.returns }
            guard case .composite(let typeName) = receiverType else { return nil }
            if let member = model.types[typeName]?.members[method.normalized] { return member.returnType }
            if let found = model.lookupMethod(method.normalized, in: typeName) { return found.returnType }
            if let field = model.field(method.normalized, of: typeName) {
                return arguments.isEmpty ? field.field.type : field.field.type.elementType
            }
            return nil
        case .unaryMinus: return .number
        case .await(let inner): return try typeOf(inner, in: function)
        case .binary(let left, let operation, let right):
            switch operation {
            case .add:
                guard let l = try typeOf(left, in: function), let r = try typeOf(right, in: function) else { return nil }
                if l == .variant || r == .variant { return .variant }
                return (l == .string && r == .string) ? .string : .number
            default:
                return .number
            }
        case .callOrArray(let name, let arguments), .functionCall(let name, let arguments):
            if let userFunction = model.functions[name.normalized] { return userFunction.returnType }
            if let intrinsic = BIRIntrinsic.lookup(name.normalized, argumentCount: arguments.count) { return intrinsic.returnType }
            if name.normalized == "USING$" || name.normalized == "TOJSONSTRING" { return .string }
            if name.normalized == "FROMJSONSTRING" { return .variant }
            if ["MKI$", "MKS$", "MKD$", "INPUT$", "INKEY$", "FIELDNAME$", "FIELDVALUE$"].contains(name.normalized) { return .string }
            if ["CVI", "CVS", "CVD", "SEEK", "FIELDCOUNT"].contains(name.normalized) { return .number }
            if ["FIELDMETA", "FIELDVALUE", "SETFIELD"].contains(name.normalized) { return .variant }
            if SemanticModel.systemClasses[name.normalized] != nil, model.info(name.normalized, in: function) == nil { return .system(name.normalized == "VTG" ? "VECTORTERMINAL" : name.normalized) }
            let variableType = model.info(name.normalized, in: function)?.type ?? Self.suffixType(name.normalized)
            if let variableType, let signature = model.signature(of: variableType) { return signature.returnType }
            if !arguments.isEmpty, variableType == .dictionary || variableType == .variant { return .variant }
            return variableType
        case .closure(let parameters, let returnType, _, _):
            return try? closureType(parameters: parameters, returnType: returnType, at: ParsedLine(number: nil, displayLineNumber: 0, fileName: nil, sourceLineNumber: 0, statementNumber: 0, isImported: false, statement: .empty))
        case .lenFunction, .pointFunction: return .number
        case .chrFunction, .systemFunction, .environmentFunction, .pwdFunction: return .string
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
        case .scalar(.variant): return .variant
        case .dictionary: return .dictionary
        case .void: return .void
        case .record(let typeName), .classType(let typeName), .interfaceType(let typeName):
            if model.signatures[typeName.uppercased()] != nil { return .closure(typeName.uppercased()) }
            if SemanticModel.systemClasses[typeName.uppercased()] != nil, model.types[typeName.uppercased()] == nil { return .system(typeName.uppercased()) }
            guard model.types[typeName.uppercased()] != nil else {
                throw CompileError("\(name) AS \(typeName): unknown TYPE, CLASS, or INTERFACE", at: Self.location(of: line))
            }
            return .composite(typeName.uppercased())
        case .functionType(let typeName):
            guard model.signatures[typeName.uppercased()] != nil else {
                throw CompileError("\(name) AS \(typeName): unknown FUNCTION TYPE", at: Self.location(of: line))
            }
            return .closure(typeName.uppercased())
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

    /// The variables an expression refers to, in first-reference order —
    /// the interpreter's `capturedVariableNames`.
    static func freeVariables(in expression: Expression, model: SemanticModel) -> [String] {
        var ordered: [String] = []
        func append(_ name: VariableName) {
            let key = name.normalized
            guard !ordered.contains(key),
                  !["READ", "WRITE", "BOTH", "RAW", "TEXT", "JSON", "NATIVE", "LITTLE", "BIG", "ERR", "ERL", "FILE"].contains(key) else { return }
            ordered.append(key)
        }
        func visit(_ expression: Expression) {
            switch expression {
            case .number, .string, .interpolatedString, .boolean, .null, .closure, .pwdFunction: return
            case .variable(let name): append(name)
            case .variableReference(let reference):
                append(reference.base); reference.indexes.forEach(visit); reference.fieldIndexes.flatMap { $0 }.forEach(visit)
            case .callOrArray(let name, let arguments):
                if model.functions[name.normalized] == nil, !BASICKeywords.intrinsicFunctionNames.contains(name.normalized), name.normalized != "USING$" { append(name) }
                arguments.forEach(visit)
            case .functionCall(_, let arguments), .newObject(_, let arguments): arguments.forEach(visit)
            case .methodCall(let receiver, _, let arguments):
                if receiver.base.normalized != "FILE" { append(receiver.base) }
                receiver.indexes.forEach(visit); arguments.forEach(visit)
            case .unaryMinus(let inner), .await(let inner), .chrFunction(let inner), .lenFunction(let inner),
                 .environmentFunction(let inner), .systemFunction(let inner): visit(inner)
            case .binary(let left, _, let right): visit(left); visit(right)
            case .pointFunction(let point): visit(point.x); visit(point.y)
            }
        }
        visit(expression)
        return ordered
    }

    /// The variables a statement refers to, for block closures.
    static func freeVariables(in statement: Statement, model: SemanticModel) -> [String] {
        var ordered: [String] = []
        func add(_ names: [String]) { for name in names where !ordered.contains(name) { ordered.append(name) } }
        SemanticAnalyzer.forEachStatement(in: statement) { statement in
            switch statement {
            case .assignment(.local, _, _, let value):
                if let value { add(freeVariables(in: value, model: model)) }
            case .assignment(_, let name, _, let value):
                add([name.normalized]); if let value { add(freeVariables(in: value, model: model)) }
            case .referenceAssignment(let reference, let value):
                add(freeVariables(in: .variableReference(reference), model: model)); if let value { add(freeVariables(in: value, model: model)) }
            case .print(let parts):
                for case .expression(let expression) in parts { add(freeVariables(in: expression, model: model)) }
            case .returnValue(let expression), .expression(let expression), .selectCase(let expression), .blockIf(let expression), .elseIf(let expression):
                add(freeVariables(in: expression, model: model))
            case .ifThen(let condition, _, _):
                add(freeVariables(in: condition, model: model))
            case .forLoop(let variable, let start, let end, let step):
                add([variable.normalized]); add(freeVariables(in: start, model: model)); add(freeVariables(in: end, model: model))
                if let step { add(freeVariables(in: step, model: model)) }
            case .caseClause(let clauses):
                for clause in clauses {
                    switch clause {
                    case .equals(let e), .comparison(_, let e): add(freeVariables(in: e, model: model))
                    case .range(let lower, let upper): add(freeVariables(in: lower, model: model)); add(freeVariables(in: upper, model: model))
                    }
                }
            default: break
            }
        }
        return ordered
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
