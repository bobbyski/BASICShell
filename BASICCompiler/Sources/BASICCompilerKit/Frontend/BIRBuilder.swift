import BASICSyntax
import Foundation

/// Turns parsed statements into a ``BIRModule``.
///
/// ```text
///   [ParsedLine] ──► SemanticAnalyzer ──► FunctionBuilder (main) ──► BIRModule
///                    functions, scopes,    FunctionBuilder (each FUNCTION)
///                    types, arrays         │
///                                          ├─ a line that is a GOTO/GOSUB target
///                                          │  starts a block
///                                          ├─ IF / FOR / SELECT are matched
///                                          │  lexically with a frame stack
///                                          └─ anything the compiler cannot do
///                                             yet is a CompileError, never a
///                                             silent difference
/// ```
public struct BIRBuilder {
    private let defaultStringSubstitution: Bool

    /// Creates a builder; `defaultStringSubstitution` is how OPTION
    /// STRING-SUB starts (the shell's default is on).
    public init(defaultStringSubstitution: Bool = true) {
        self.defaultStringSubstitution = defaultStringSubstitution
    }

    /// Builds the module for a program.
    public func build(_ lines: [ParsedLine], moduleName: String) throws -> BIRModule {
        var analyzer = SemanticAnalyzer(lines: lines)
        let model = try analyzer.run()
        var module = BIRModule(name: moduleName)
        module.globals = model.globalVariables
        module.data = Self.collectData(lines)
        module.types = model.typeOrder.compactMap { name -> BIRCompositeType? in
            let type = model.types[name]!
            guard type.kind != .interface else { return nil }
            return BIRCompositeType(
                name: name, displayName: type.displayName, index: type.index,
                fields: model.allFields(of: name).map {
                    BIRField(name: $0.name, displayName: $0.displayName, type: $0.type, dimensions: $0.dimensions, jsonName: $0.jsonName, defaultValue: $0.defaultValue, isInteger: $0.isInteger, metadata: $0.metadata)
                },
                isClass: type.kind == .classType,
                base: type.base.flatMap { model.types[$0]?.index }
            )
        }

        let closures = ClosureContext(firstTypeIndex: module.types.count)
        let main = FunctionBuilder(lines: lines, model: model, function: nil, owner: analyzer.owner, closures: closures)
        main.substitutesStrings = defaultStringSubstitution
        main.entryLabels = Self.labelsGosubbedFromFunctions(lines, owner: analyzer.owner)
        try main.run()
        module.main = main.function

        let mainLabels = main.labels
        for name in model.functionOrder {
            let builder = FunctionBuilder(lines: lines, model: model, function: name, owner: analyzer.owner, closures: closures)
            builder.outerLabels = mainLabels
            try builder.run()
            module.functions.append(builder.function)
        }
        // Each main subroutine a function reaches becomes a function whose
        // body is the main body entered at that label: a RETURN with no
        // GOSUB of its own pending returns to the caller, which is what the
        // interpreter's one GOSUB stack does.
        for label in closures.subroutineLabels.sorted() {
            guard let entry = main.blockForLabel(label) else { continue }
            var subroutine = BIRFunction(name: FunctionBuilder.subroutineName(label))
            subroutine.blocks = main.function.blocks
            subroutine.locals = main.function.locals
            subroutine.externalEntryBlocks = []
            var start = BIRBlock(id: 0, label: "entry")
            start.terminator = .jump(entry)
            subroutine.blocks[0] = start
            subroutine.pruneUnreachableBlocks()
            module.functions.append(subroutine)
        }
        for index in module.functions.indices where model.eventHandlers.contains(module.functions[index].name) {
            module.functions[index].isEventHandler = true
        }
        // A TUI control names its handler with a string, so a program that
        // builds one registers every function such a string could reach.
        if Self.usesTUI(lines) {
            for index in module.functions.indices where module.functions[index].parameters.count <= 1 && !module.functions[index].isAsync {
                module.functions[index].isEventHandler = true
                let name = module.functions[index].name
                module.namedHandlers.append((name: model.functions[name]?.displayName ?? name, function: name))
            }
        }
        module.functions.append(contentsOf: closures.functions)
        module.types.append(contentsOf: closures.environmentTypes)
        module.signatures = model.signatures
        module.fieldVariables = model.fieldVariables
        for name in model.functionOrder where model.functions[name]?.isAsync == true {
            module.asyncDisplayNames[name] = model.functions[name]?.displayName
        }
        return module
    }

    /// Whether the program constructs a TUI object anywhere.
    private static func usesTUI(_ lines: [ParsedLine]) -> Bool {
        var found = false
        func note(_ expression: Expression) {
            guard !found else { return }
            if case .callOrArray(let name, _) = expression, SemanticModel.supportedTUIClasses.contains(name.normalized) { found = true }
            if case .functionCall(let name, _) = expression, SemanticModel.supportedTUIClasses.contains(name.normalized) { found = true }
        }
        for line in lines {
            for expression in Self.expressions(in: line.statement) { note(expression) }
            if found { return true }
        }
        return false
    }

    /// The top-level expressions of a statement, for a shallow scan.
    private static func expressions(in statement: Statement) -> [Expression] {
        switch statement {
        case .assignment(_, _, _, let value): return value.map { [$0] } ?? []
        case .referenceAssignment(_, let value): return value.map { [$0] } ?? []
        case .labeled(_, let inner): return expressions(in: inner)
        case .sequence(let statements): return statements.flatMap(expressions(in:))
        case .expression(let expression): return [expression]
        default: return []
        }
    }

    /// The labels a GOSUB inside a FUNCTION names, uppercased. The main body
    /// gives each one a block so it can be entered from outside.
    private static func labelsGosubbedFromFunctions(_ lines: [ParsedLine], owner: [String?]) -> Set<String> {
        var found: Set<String> = []
        func note(_ statement: Statement) {
            switch statement {
            case .gosub(.label(let name)): found.insert(name.uppercased())
            case .labeled(_, let inner): note(inner)
            case .sequence(let statements): statements.forEach(note)
            case .ifThen(_, let thenAction, let elseAction):
                if case .statement(let inner) = thenAction { note(inner) }
                if case .statement(let inner)? = elseAction { note(inner) }
            default: break
            }
        }
        for (index, line) in lines.enumerated() where index < owner.count && owner[index] != nil {
            note(line.statement)
        }
        return found
    }

    /// Every DATA item in source order, as the interpreter collects them.
    private static func collectData(_ lines: [ParsedLine]) -> [BIRDataItem] {
        lines.filter { !$0.isImported }.flatMap { line -> [BIRDataItem] in
            guard case .data(let literals) = line.statement else { return [] }
            return literals.map { literal in
                switch literal {
                case .number(let value): return .number(value)
                case .string(let value): return .string(value)
                case .boolean(let value): return .number(value ? 1 : 0)
                case .null, .empty: return .string("")
                }
            }
        }
    }
}

/// What every function builder in a module shares about closures: the
/// bodies and environment types they synthesize.
final class ClosureContext {
    /// Top-level labels a FUNCTION reaches with GOSUB, uppercased. The
    /// interpreter's GOSUB stack is the program's, not a frame's, so a
    /// handler can call a subroutine written beside the main body; each one
    /// named here is emitted as a function of its own.
    var subroutineLabels: Set<String> = []
    /// Closure body functions, in creation order.
    var functions: [BIRFunction] = []
    /// Environment record types, one per closure literal with captures.
    var environmentTypes: [BIRCompositeType] = []
    private var counter = 0
    private let firstTypeIndex: Int

    init(firstTypeIndex: Int) {
        self.firstTypeIndex = firstTypeIndex
    }

    /// A fresh closure number.
    func next() -> Int {
        counter += 1
        return counter
    }

    /// Registers an environment type and returns its name.
    func addEnvironment(fields: [BIRField], number: Int) -> String {
        let name = "$ENV.\(number)"
        environmentTypes.append(BIRCompositeType(name: name, displayName: name, index: firstTypeIndex + environmentTypes.count, fields: fields))
        return name
    }
}

/// Builds one function's blocks — `main`, a `FUNCTION`, or a closure body.
/// A class so the many helpers can share mutable state without `inout`
/// threading.
final class FunctionBuilder {
    private let lines: [ParsedLine]
    private let model: SemanticModel
    /// The function being built; nil for the program body.
    private let functionName: String?
    private let signature: SemanticModel.Function?
    private let owner: [String?]
    /// The class whose method this is, for PRIVATE/PROTECTED checks.
    private let ownerClass: String?
    private let closures: ClosureContext
    /// For a closure body: the names that are its locals (parameters,
    /// captures, LOCALs), with their types. Every other name is global.
    var closureLocals: [String: BIRVariable]?
    /// For a closure body: the statements to build, replacing `lines`.
    var closureLines: [ParsedLine]?
    /// For a closure body: the declared return type, so RETURN checks it.
    var closureSignatureReturn: BIRType?
    var function: BIRFunction

    /// The block instructions are currently appended to.
    private var current: BIRBlockID = 0
    /// Blocks that begin at a parsed line, because something jumps there.
    private var blockForLine: [Int: BIRBlockID] = [:]
    private var lineIndexByNumber: [Int: Int] = [:]
    private var lineIndexByLabel: [String: Int] = [:]
    var location = BIRLocation(file: nil, line: 0, statement: 0, lineNumber: nil)
    private var frames: [Frame] = []
    private var hiddenCounter = 0
    /// True when main uses ON ERROR: every statement then starts a block and
    /// is marked, so the runtime can report ERL and RESUME NEXT.
    private var tracksStatements = false
    /// `OPTION STRING-SUB`: whether plain strings interpolate `${…}` too.
    /// BASICShell turns this on for every program it runs, so a compiled
    /// program starts the same way; tracked in program order from there.
    var substitutesStrings = true
    /// The function's result slot: `Name = value` inside `FUNCTION Name`
    /// sets the value the function returns when it falls off the end (the
    /// interpreter's frame `returnValue`).
    private var resultSlot: BIRVariable?
    /// The bare (class-less) normalized name of the function being built.
    private var shortFunctionName: String? {
        guard let signature else { return nil }
        return signature.name.split(separator: ".").last.map(String.init)
    }

    /// The value a fall-off return yields: the result slot when the body
    /// assigned to the function's name, else the type's default.
    private func fallOffReturn() -> BIRTerminator {
        if let resultSlot { return .ret(.load(resultSlot)) }
        return .ret(nil)
    }

    /// One open IF / FOR / SELECT.
    private enum Frame {
        case ifBlock(elseBlock: BIRBlockID?, join: BIRBlockID)
        case forLoop(variable: BIRVariable, mirror: BIRVariable?, end: BIRVariable, step: BIRVariable, body: BIRBlockID, exit: BIRBlockID)
        case select(subject: BIRVariable, next: BIRBlockID, elseBlock: BIRBlockID?, end: BIRBlockID)
    }

    /// The labels of the main body, uppercased — a GOSUB from inside a
    /// FUNCTION may name one.
    var outerLabels: Set<String> = []
    /// Labels that need a block of their own even when nothing in this body
    /// branches to them: a FUNCTION reaches them with GOSUB.
    var entryLabels: Set<String> = []

    init(lines: [ParsedLine], model: SemanticModel, function: String?, owner: [String?], closures: ClosureContext) {
        self.lines = lines
        self.model = model
        self.functionName = function
        self.signature = function.flatMap { model.functions[$0] }
        self.owner = owner
        self.closures = closures
        self.ownerClass = self.signature?.owner
        if let signature = self.signature {
            self.function = BIRFunction(name: signature.name, parameters: signature.parameters, returnType: signature.returnType)
            self.function.locals = model.localVariables(of: signature.name)
            self.function.isAsync = signature.isAsync
        } else {
            self.function = BIRFunction(name: "main")
        }
    }

    /// The parsed-line indexes this function executes. Imported files
    /// contribute their declarations only; the interpreter skips their
    /// top-level statements.
    private var ownedLines: [Int] {
        if closureLines != nil { return Array(sourceLines.indices) }
        if let signature {
            return Array(signature.body)
        }
        return lines.indices.filter { owner[$0] == nil && !lines[$0].isImported }
    }

    /// Whether the program registers any event handler at all.
    private lazy var programUsesEvents: Bool = lines.contains { line in
        switch line.statement {
        case .onEventCall, .onTimerEvent: return true
        default: return false
        }
    }

    /// The statements being built: the program's, or a closure body's.
    private var sourceLines: [ParsedLine] { closureLines ?? lines }

    /// A closure body starts by taking its captures out of the environment.
    private func emitEnvironmentPrologue() {
        guard let environment = function.environment else { return }
        let env = function.parameters[0]
        for (index, local) in environment.locals.enumerated() {
            emit(.store(local, .field(.load(env), index: index, type: local.type)))
        }
    }

    func run() throws {
        emitEnvironmentPrologue()
        if let signature, let expression = signature.expression {
            location = signature.location
            terminate(.ret(try lowerExpression(expression, expecting: signature.returnType, context: "DEF \(signature.displayName)")))
            function.pruneUnreachableBlocks()
            return
        }
        try indexTargets()
        emitImplicitDimensions()
        if signature == nil {
            tracksStatements = ownedLines.contains { index in
                if case .onErrorGoto = lines[index].statement { return true }
                return false
            }
        }
        if tracksStatements {
            // Every statement gets a block so RESUME NEXT has somewhere to go.
            for index in ownedLines where blockForLine[index] == nil {
                blockForLine[index] = newBlock("s\(index)")
            }
        }
        let owned = ownedLines
        for (position, index) in owned.enumerated() {
            let line = sourceLines[index]
            location = SemanticAnalyzer.location(of: line)
            if let block = blockForLine[index] {
                terminate(.jump(block))
                current = block
            }
            if tracksStatements {
                let next = position + 1 < owned.count ? blockForLine[owned[position + 1]]! : endBlock()
                function.statementResumeBlocks.append(next)
                emit(.markStatement(id: position, line: line.displayLineNumber))
            }
            try lower(line.statement)
            // The interpreter runs up to sixteen queued events after every
            // statement. A program with no handler has nothing to run.
            if programUsesEvents { emit(.drainEvents(limit: 16)) }
        }
        terminate(signature == nil && closureLines == nil ? .end : fallOffReturn())
        guard frames.isEmpty else {
            throw CompileError(unterminatedFrameMessage(), at: location)
        }
        function.pruneUnreachableBlocks()
    }

    private var endBlockID: BIRBlockID?

    /// A block that ends the program, for RESUME NEXT after the last statement.
    private func endBlock() -> BIRBlockID {
        if let endBlockID { return endBlockID }
        let block = newBlock("program.end")
        function.blocks[block].terminator = .end
        endBlockID = block
        return block
    }

    /// Arrays the interpreter would create on first use (0...10 per
    /// dimension) are created up front instead, and record/object variables
    /// start as default instances.
    private func emitImplicitDimensions() {
        let variables = (signature == nil && closureLines == nil) ? model.globalVariables : function.locals.filter { !function.parameters.contains($0) }
        for variable in variables {
            if let rank = variable.rank {
                if signature == nil, model.globals[variable.name]?.wasDimensioned == false {
                    emit(.dim(variable, Array(repeating: .number(10), count: rank)))
                }
            } else if case .composite(let typeName) = variable.type, model.types[typeName] != nil, model.types[typeName]?.kind != .interface {
                emit(.store(variable, .construct(typeName)))
            } else if variable.type == .dictionary {
                emit(.store(variable, .newDictionary))
            }
        }
    }

    // MARK: - Targets

    private func indexTargets() throws {
        for index in ownedLines {
            let line = sourceLines[index]
            if let number = line.number { lineIndexByNumber[number] = index }
            if let label = line.statement.label { lineIndexByLabel[label.uppercased()] = index }
        }
        for label in entryLabels.sorted() where lineIndexByLabel[label] != nil {
            function.externalEntryBlocks.append(try blockForTarget(.label(label)))
        }
        for index in ownedLines {
            location = SemanticAnalyzer.location(of: sourceLines[index])
            try collectTargets(in: sourceLines[index].statement)
        }
    }

    private func collectTargets(in statement: Statement) throws {
        switch statement {
        case .goto(let number): _ = try blockForTarget(.line(number))
        case .gotoLabel(let label): _ = try blockForTarget(.label(label))
        case .gosub(let target):
            if case .label(let name) = target, lineIndexByLabel[name.uppercased()] == nil, outerLabels.contains(name.uppercased()) { return }
            _ = try blockForTarget(target)
        case .computedGoto(let targets, _), .computedGosub(let targets, _):
            for target in targets { _ = try blockForTarget(target) }
        case .ifThen(_, let thenAction, let elseAction):
            if case .branch(let target) = thenAction { _ = try blockForTarget(target) }
            if case .statement(let inner) = thenAction { try collectTargets(in: inner) }
            if case .branch(let target)? = elseAction { _ = try blockForTarget(target) }
            if case .statement(let inner)? = elseAction { try collectTargets(in: inner) }
        case .labeled(_, let inner): try collectTargets(in: inner)
        case .sequence(let statements): for inner in statements { try collectTargets(in: inner) }
        default: break
        }
    }

    /// Blocks that raise "Missing line N" for targets that do not exist.
    private var missingTargetBlocks: [String: BIRBlockID] = [:]

    /// A block that fails the way the interpreter does when a jump names a
    /// line or label the program lacks — at the jump, not at compile time.
    private func missingTargetBlock(_ message: String) -> BIRBlockID {
        if let existing = missingTargetBlocks[message] { return existing }
        let block = newBlock("missing")
        function.blocks[block].instructions.append(BIRInstruction(.failMissing(message), at: location))
        function.blocks[block].terminator = .end
        missingTargetBlocks[message] = block
        return block
    }

    /// The function name an outlined main subroutine is emitted under.
    static func subroutineName(_ label: String) -> String { "$SUB.\(label)" }

    /// The block a main label begins, once this builder has run. Pruning
    /// renumbers the blocks, so the block is found by its name.
    func blockForLabel(_ label: String) -> BIRBlockID? {
        function.blocks.first { $0.label == "label.\(label.uppercased())" }?.id
    }

    /// Every label of this body, uppercased.
    var labels: Set<String> { Set(lineIndexByLabel.keys) }

    private func blockForTarget(_ target: BranchTarget) throws -> BIRBlockID {
        let index: Int
        let label: String
        switch target {
        case .line(let number):
            guard let found = lineIndexByNumber[number] else { return missingTargetBlock("Missing line \(number)") }
            index = found
            label = "L\(number)"
        case .label(let name):
            guard let found = lineIndexByLabel[name.uppercased()] else { return missingTargetBlock("Missing label \(name)") }
            index = found
            label = "label.\(name.uppercased())"
        }
        if let existing = blockForLine[index] { return existing }
        let block = newBlock(label)
        blockForLine[index] = block
        return block
    }

    // MARK: - Blocks

    private func newBlock(_ label: String) -> BIRBlockID {
        let id = function.blocks.count
        function.blocks.append(BIRBlock(id: id, label: uniqueLabel(label)))
        return id
    }

    private func uniqueLabel(_ label: String) -> String {
        var candidate = label
        var suffix = 1
        while function.blocks.contains(where: { $0.label == candidate }) {
            suffix += 1
            candidate = "\(label).\(suffix)"
        }
        return candidate
    }

    private func emit(_ operation: BIROperation) {
        function.blocks[current].instructions.append(BIRInstruction(operation, at: location))
    }

    /// Ends the current block. If it already ended (a GOTO, say), the
    /// terminator is dropped and a fresh, unreachable block absorbs whatever
    /// follows — exactly the code the interpreter would never reach either.
    func terminate(_ terminator: BIRTerminator) {
        if case .unterminated = function.blocks[current].terminator {
            function.blocks[current].terminator = terminator
        }
        current = newBlock("after")
    }

    private func hidden(_ purpose: String, _ type: BIRType) -> BIRVariable {
        hiddenCounter += 1
        let variable = BIRVariable(name: "$\(purpose).\(hiddenCounter)", type: type, scope: .local)
        function.locals.append(variable)
        return variable
    }

    private func variable(_ name: VariableName) -> BIRVariable {
        if let closureLocals {
            if let local = closureLocals[name.normalized] { return local }
            return model.variable(name.normalized, in: nil)
        }
        return model.variable(name.normalized, in: functionName)
    }

    private func unsupported(_ what: String) -> CompileError {
        CompileError("\(what) is not supported by basicc yet", at: location)
    }

    // MARK: - Statements

    private func lower(_ statement: Statement) throws {
        switch statement {
        case .empty, .remark, .label, .data:
            break
        case .labeled(_, let inner):
            try lower(inner)
        case .sequence(let statements):
            for inner in statements { try lower(inner) }

        case .print(let parts):
            // `;` only suppresses spacing and the newline; it renders nothing.
            var items = try parts
                .filter { if case .separator(.semicolon) = $0 { return false } else { return true } }
                .map(lowerPrintPart)
            // The interpreter renders the whole PRINT before writing it, so
            // anything an item's code prints comes out first: evaluate every
            // item into a temporary when one of them may run code.
            func expression(of item: BIRPrintItem) -> BIRExpression? {
                switch item {
                case .value(let e), .tab(let e), .spc(let e): return e
                case .comma: return nil
                }
            }
            if items.contains(where: { expression(of: $0)?.mayRunCode == true }) {
                items = items.map { item in
                    guard let e = expression(of: item), e.type != .void, !e.type.isArray else { return item }
                    let temp = hidden("print", e.type)
                    emit(.store(temp, e))
                    switch item {
                    case .value: return .value(.load(temp))
                    case .tab: return .tab(.load(temp))
                    case .spc: return .spc(.load(temp))
                    case .comma: return item
                    }
                }
            }
            emit(.print(items, newline: !(parts.last?.suppressesNewline ?? false)))

        case .assignment(let kind, let name, let declared, let value):
            if SemanticModel.namedConstants.contains(name.normalized) {
                // `RAW = "x"` changes nothing: the interpreter reads the
                // constant back whatever was assigned. The value is still
                // worked out, in case working it out was the point.
                if let value { emit(.discard(boxed(try lowerExpression(value)))) }
                return
            }
            if let signature, kind != .global, name.normalized == shortFunctionName, signature.returnType != .void {
                // `Name = value` inside FUNCTION Name sets the result.
                guard declared == nil else { throw CompileError("Type error: Cannot redeclare function return \(name.name)", at: location) }
                if resultSlot == nil { resultSlot = hidden("result", signature.returnType) }
                guard let value, let stored = try lowerAssigned(value, to: signature.returnType, name: signature.displayName) else { return }
                emit(.store(resultSlot!, stored))
                return
            }
            var target = variable(name)
            if kind == .global, signature != nil {
                target = model.variable(name.normalized, in: nil)
            }
            if target.rank != nil {
                // `a = value` for a whole array: the interpreter's coerceArray.
                guard let value else { return }
                emit(.assignArray(.variable(target), boxed(try lowerExpression(value))))
                return
            }
            if value == nil, isInterface(target.type) || target.type.isClosure { return }
            guard let stored = try value.map({ try lowerAssigned($0, to: target.type, name: name.name) }) ?? defaultValue(for: target.type) else { return }
            emit(.store(target, stored))
        case .referenceAssignment(let reference, let value):
            guard !reference.hasEmptyIndexList else { throw unsupported("assigning a whole array") }
            if case .system = variable(reference.base).type, reference.fields.count == 1, reference.indexes.isEmpty {
                guard let value else { return }
                emit(.systemSet(.load(variable(reference.base)), property: reference.fields[0], boxed(try lowerExpression(value))))
                return
            }
            let place = try lowerPlace(reference)
            if place.type.isArray {
                guard let value else { return }
                emit(.assignArray(place, boxed(try lowerExpression(value))))
                return
            }
            guard let stored = try value.map({ try lowerAssigned($0, to: place.type, name: reference.base.name) }) ?? defaultValue(for: place.type) else { return }
            emitStore(place, stored)
        case .dim(_, let name, let dimensions, _):
            let target = variable(name)
            if dimensions.isEmpty {
                // An interface- or closure-typed slot starts empty, like the interpreter's.
                if !isInterface(target.type), !target.type.isClosure { emit(.store(target, defaultValue(for: target.type))) }
            } else {
                let bounds = try dimensions.map { dimension -> BIRExpression? in
                    try dimension.map { try lowerExpression($0, expecting: .number, context: "DIM \(name.name)") }
                }
                emit(.dim(target, bounds))
            }

        case .input(let prompt, .variable(let name)):
            let promptValue = try prompt.map { try lowerExpression($0, expecting: .string, context: "INPUT prompt") }
            emit(.input(prompt: promptValue, into: variable(name), displayName: name.name))
        case .input(let prompt, .reference(let reference)):
            // INPUT into an element or field: read into a temporary of the
            // place's type, then store it there.
            let promptValue = try prompt.map { try lowerExpression($0, expecting: .string, context: "INPUT prompt") }
            let place = try lowerPlace(reference)
            let slotType: BIRType = [.number, .string, .boolean].contains(place.type) ? place.type : .string
            let slot = hidden("input", slotType)
            emit(.input(prompt: promptValue, into: slot, displayName: ([reference.base.name] + reference.fields).joined(separator: ".")))
            emitStore(place, convert(.load(slot), to: place.type, name: reference.base.name))
        case .lineInput(let prompt, .variable(let name), nil, nil, nil, nil):
            let target = variable(name)
            guard target.type == .string, target.rank == nil else {
                throw CompileError("Type error: LINE INPUT needs a string variable, got \(name.name)", at: location)
            }
            emit(.lineInput(prompt: try prompt.map { try lowerExpression($0, expecting: .string, context: "LINE INPUT prompt") }, into: target))
        case .lineInput(let prompt, let target, let exitTarget, let length, let maximum, let defaultText):
            let promptValue = try prompt.map { try lowerExpression($0, expecting: .string, context: "LINE INPUT prompt") }
            let slot = hidden("line", .string)
            var exitSlot: BIRVariable?
            if exitTarget != nil { exitSlot = hidden("exit", .string) }
            emit(.lineInputField(
                prompt: promptValue, into: slot, exitInto: exitSlot,
                length: try length.map { try lowerExpression($0, expecting: .number, context: "LINE INPUT LENGTH") },
                max: try maximum.map { try lowerExpression($0, expecting: .number, context: "LINE INPUT MAX") },
                defaultText: try defaultText.map { try lowerExpression($0, expecting: .string, context: "LINE INPUT DEFAULT") }
            ))
            let place = try lowerPlace(readTargetReference(target))
            emitStore(place, convert(.load(slot), to: place.type, name: readTargetReference(target).base.name))
            if let exitTarget, let exitSlot {
                let exitPlace = try lowerPlace(readTargetReference(exitTarget))
                emitStore(exitPlace, convert(.load(exitSlot), to: exitPlace.type, name: readTargetReference(exitTarget).base.name))
            }
        case .locate(let row, let column):
            emit(.locate(try lowerExpression(row, expecting: .number, context: "LOCATE"), try lowerExpression(column, expecting: .number, context: "LOCATE")))
        case .screen(let mode):
            emit(.screen(try lowerExpression(mode, expecting: .number, context: "SCREEN")))
        case .color(let colors):
            guard !colors.isEmpty, colors.count <= 2 else { throw CompileError("COLOR expects foreground and optional background", at: location) }
            emit(.color(boxed(try lowerExpression(colors[0])), colors.count == 2 ? boxed(try lowerExpression(colors[1])) : nil))
        case .pset(let point, let color), .preset(let point, let color):
            var reset = false
            if case .preset = statement { reset = true }
            emit(.pset(x: try lowerExpression(point.x, expecting: .number, context: "PSET"), y: try lowerExpression(point.y, expecting: .number, context: "PSET"),
                       color: try color.map { boxed(try lowerExpression($0)) }, reset: reset))
        case .line(let start, let end, let color):
            emit(.gline(x1: try lowerExpression(start.x, expecting: .number, context: "LINE"), y1: try lowerExpression(start.y, expecting: .number, context: "LINE"),
                        x2: try lowerExpression(end.x, expecting: .number, context: "LINE"), y2: try lowerExpression(end.y, expecting: .number, context: "LINE"),
                        color: try color.map { boxed(try lowerExpression($0)) }))
        case .circle(let center, let radius, let color, let aspect):
            emit(.circle(x: try lowerExpression(center.x, expecting: .number, context: "CIRCLE"), y: try lowerExpression(center.y, expecting: .number, context: "CIRCLE"),
                         radius: try lowerExpression(radius, expecting: .number, context: "CIRCLE"),
                         color: try color.map { boxed(try lowerExpression($0)) },
                         aspect: try aspect.map { try lowerExpression($0, expecting: .number, context: "CIRCLE aspect") }))
        case .paint(let point, let color, let border):
            emit(.paint(x: try lowerExpression(point.x, expecting: .number, context: "PAINT"), y: try lowerExpression(point.y, expecting: .number, context: "PAINT"),
                        color: boxed(try lowerExpression(color)), border: try border.map { boxed(try lowerExpression($0)) }))
        case .draw(let program):
            emit(.draw(try lowerExpression(program, expecting: .string, context: "DRAW")))
        case .printUsing(let format, let values, let trailingSeparator):
            emit(.printUsing(
                format: try lowerExpression(format, expecting: .string, context: "PRINT USING"),
                values: try values.map { try lowerExpression($0) },
                newline: trailingSeparator == nil
            ))
        case .optionStringSubstitution(let enabled):
            substitutesStrings = enabled
        case .optionLetMode:
            break  // Resolved by the analyzer for the whole program.
        case .optionKeyMode(let mode):
            emit(.keyMode(mode == .ibm ? 1 : 0))
        case .optionShellMode, .optionEventInput:
            // Host-facing options: key encoding for INKEY$, shell-mode
            // command dispatch, and mouse/gamepad gating. A compiled console
            // program has none of those surfaces yet (Phase 5.2), so the
            // options are accepted and change nothing, as they would in the
            // interpreter with no such host.
            break
        case .read(let targets):
            emit(.read(try targets.map(lowerReadTarget)))
        case .restore:
            emit(.restore)
        case .cls:
            emit(.cls)

        case .openFile(let path, let mode, let number, let recordLength):
            let modeCode: Int
            switch mode {
            case .input: modeCode = 0
            case .output: modeCode = 1
            case .append: modeCode = 2
            case .binary: modeCode = 3
            case .random: modeCode = 4
            }
            emit(.openFile(
                path: try lowerExpression(path, expecting: .string, context: "OPEN"),
                mode: modeCode,
                number: try lowerExpression(number, expecting: .number, context: "OPEN AS"),
                recordLength: try recordLength.map { try lowerExpression($0, expecting: .number, context: "OPEN LEN") }
            ))
        case .fieldFile(let number, let fields):
            emit(.fieldFile(
                number: try lowerExpression(number, expecting: .number, context: "FIELD"),
                fields: try fields.map { BIRFieldSpec(width: try lowerExpression($0.width, expecting: .number, context: "FIELD width"), variable: variable($0.variable)) }
            ))
        case .setFieldString(let target, let value, let rightAligned):
            guard case .variable(let name) = target else { throw CompileError("LSET and RSET require a FIELD string variable", at: location) }
            emit(.setFieldString(variable(name), try lowerExpression(value, expecting: .string, context: rightAligned ? "RSET" : "LSET"), rightAligned: rightAligned))
        case .putFile(let number, let parts):
            var record: BIRExpression?
            if parts.count == 1, case .expression(let expression) = parts[0] {
                record = try lowerExpression(expression, expecting: .number, context: "PUT")
            } else if !parts.isEmpty {
                throw CompileError("PUT expects an optional record number in RANDOM mode", at: location)
            }
            emit(.putRecord(number: try lowerExpression(number, expecting: .number, context: "PUT"), record: record))
        case .getRecordFile(let number, let record):
            emit(.getRecord(
                number: try lowerExpression(number, expecting: .number, context: "GET"),
                record: try record.map { try lowerExpression($0, expecting: .number, context: "GET") }
            ))
        case .getFile(let number, let targets):
            emit(.inputFile(
                number: try lowerExpression(number, expecting: .number, context: "GET #"),
                targets: try targets.map(lowerReadTarget)
            ))
        case .seekFile(let number, let position):
            emit(.seekFile(
                number: try lowerExpression(number, expecting: .number, context: "SEEK"),
                position: try lowerExpression(position, expecting: .number, context: "SEEK")
            ))
        case .resetFile(let number):
            emit(.resetFile(try lowerExpression(number, expecting: .number, context: "RESET")))
        case .closeFile(let number):
            emit(.closeFile(try number.map { try lowerExpression($0, expecting: .number, context: "CLOSE") }))
        case .printFile(let number, let parts):
            let items = try parts
                .filter { if case .separator(.semicolon) = $0 { return false } else { return true } }
                .map(lowerPrintPart)
            emit(.printFile(
                number: try lowerExpression(number, expecting: .number, context: "PRINT #"),
                items: items, newline: !(parts.last?.suppressesNewline ?? false)
            ))
        case .printFileUsing(let number, let format, let values, let trailingSeparator):
            emit(.printFileUsing(
                number: try lowerExpression(number, expecting: .number, context: "PRINT #"),
                format: try lowerExpression(format, expecting: .string, context: "PRINT # USING"),
                values: try values.map { try lowerExpression($0) },
                newline: trailingSeparator == nil
            ))
        case .writeFile(let number, let values):
            emit(.writeFile(
                number: try lowerExpression(number, expecting: .number, context: "WRITE #"),
                values: try values.map { try lowerExpression($0) }
            ))
        case .inputFile(let number, let targets):
            emit(.inputFile(
                number: try lowerExpression(number, expecting: .number, context: "INPUT #"),
                targets: try targets.map(lowerReadTarget)
            ))
        case .lineInputFile(let number, .variable(let name)):
            let target = variable(name)
            guard target.type == .string, target.rank == nil else {
                throw CompileError("Type error: LINE INPUT # needs a string variable, got \(name.name)", at: location)
            }
            emit(.lineInputFile(number: try lowerExpression(number, expecting: .number, context: "LINE INPUT #"), into: target))
        case .lineInputFile:
            throw unsupported("LINE INPUT # into an array element or field")

        case .goto(let number):
            terminate(.jump(try blockForTarget(.line(number))))
        case .gotoLabel(let label):
            terminate(.jump(try blockForTarget(.label(label))))
        case .gosub(let target):
            if case .label(let name) = target, lineIndexByLabel[name.uppercased()] == nil, outerLabels.contains(name.uppercased()) {
                // A subroutine of the main body, reached from a function.
                closures.subroutineLabels.insert(name.uppercased())
                emit(.call(Self.subroutineName(name.uppercased()), []))
                return
            }
            let resume = newBlock("gosub.resume")
            terminate(.gosub(try blockForTarget(target), resume: resume))
            current = resume
        case .returnFromSubroutine:
            terminate(.returnFromGosub)
        case .computedGoto(let targets, let selector):
            try lowerComputedJump(targets: targets, selector: selector, isGosub: false)
        case .computedGosub(let targets, let selector):
            try lowerComputedJump(targets: targets, selector: selector, isGosub: true)
        case .end:
            terminate(signature != nil ? fallOffReturn() : .end)

        case .returnValue(let expression):
            if closureLines != nil, let closureReturn = closureSignatureReturn {
                guard closureReturn != .void else { throw CompileError("Type error: VOID closure cannot return a value", at: location) }
                terminate(.ret(try lowerExpression(expression, expecting: closureReturn, context: "RETURN")))
                return
            }
            guard let signature else { emit(.fail("RETURN value outside FUNCTION")); return }
            guard signature.returnType != .void else {
                throw CompileError("Type error: VOID function \(signature.displayName) cannot return a value", at: location)
            }
            terminate(.ret(try lowerExpression(expression, expecting: signature.returnType, context: "RETURN")))
        case .exitFunction:
            guard signature != nil || closureLines != nil else { emit(.fail("EXIT FUNCTION outside FUNCTION")); return }
            terminate(fallOffReturn())
        case .expression(let expression):
            try lowerExpressionStatement(expression)

        case .ifThen(let condition, let thenAction, let elseAction):
            try lowerSingleLineIf(condition, thenAction, elseAction)
        case .blockIf(let condition):
            let thenBlock = newBlock("if.then")
            let elseBlock = newBlock("if.else")
            let join = newBlock("if.end")
            terminate(.branch(try lowerCondition(condition), then: thenBlock, else: elseBlock))
            current = thenBlock
            frames.append(.ifBlock(elseBlock: elseBlock, join: join))
        case .elseIf(let condition):
            guard case .ifBlock(let elseBlock?, let join)? = frames.last else {
                throw CompileError("ELSEIF without IF", at: location)
            }
            terminate(.jump(join))
            current = elseBlock
            let thenBlock = newBlock("elseif.then")
            let nextElse = newBlock("elseif.else")
            terminate(.branch(try lowerCondition(condition), then: thenBlock, else: nextElse))
            current = thenBlock
            frames[frames.count - 1] = .ifBlock(elseBlock: nextElse, join: join)
        case .elseBlock:
            guard case .ifBlock(let elseBlock?, let join)? = frames.last else {
                throw CompileError("ELSE without IF", at: location)
            }
            terminate(.jump(join))
            current = elseBlock
            frames[frames.count - 1] = .ifBlock(elseBlock: nil, join: join)
        case .endIf:
            guard case .ifBlock(let elseBlock, let join)? = frames.popLast() else {
                throw CompileError("END IF without IF", at: location)
            }
            terminate(.jump(join))
            if let elseBlock {
                current = elseBlock
                terminate(.jump(join))
            }
            current = join

        case .forLoop(let name, let start, let end, let step):
            try lowerFor(name, start, end, step)
        case .nextLoop(let names):
            if names.isEmpty {
                try lowerNext(nil)
            } else {
                for name in names { try lowerNext(name) }
            }

        case .selectCase(let subject):
            let value = try lowerExpression(subject, expecting: nil, context: "SELECT CASE")
            let slot = hidden("select", value.type)
            emit(.store(slot, value))
            let firstTest = newBlock("case.test")
            let end = newBlock("select.end")
            terminate(.jump(firstTest))
            frames.append(.select(subject: slot, next: firstTest, elseBlock: nil, end: end))
        case .caseClause(let clauses):
            guard case .select(let subject, let test, let elseBlock, let end)? = frames.last else {
                throw CompileError("CASE without SELECT", at: location)
            }
            terminate(.jump(end))
            current = test
            let body = newBlock("case.body")
            let next = newBlock("case.test")
            let condition = try clauses
                .map { try lowerCaseClause($0, subject: subject) }
                .reduce(nil) { (folded: BIRExpression?, clause) in
                    folded.map { .logical(.or, $0, clause) } ?? clause
                }!
            terminate(.branch(condition, then: body, else: next))
            current = body
            frames[frames.count - 1] = .select(subject: subject, next: next, elseBlock: elseBlock, end: end)
        case .caseElse:
            guard case .select(let subject, let next, nil, let end)? = frames.last else {
                throw CompileError("CASE ELSE without SELECT", at: location)
            }
            terminate(.jump(end))
            let elseBlock = newBlock("case.else")
            current = elseBlock
            frames[frames.count - 1] = .select(subject: subject, next: next, elseBlock: elseBlock, end: end)
        case .endSelect:
            guard case .select(_, let next, let elseBlock, let end)? = frames.popLast() else {
                throw CompileError("END SELECT without SELECT", at: location)
            }
            terminate(.jump(end))
            current = next
            terminate(.jump(elseBlock ?? end))
            current = end
        case .exitSelect:
            guard let frame = frames.last(where: { if case .select = $0 { return true } else { return false } }),
                  case .select(_, _, _, let end) = frame else {
                throw CompileError("EXIT SELECT without SELECT", at: location)
            }
            terminate(.jump(end))

        case .randomize(let seed):
            emit(.randomize(try seed.map { try lowerExpression($0, expecting: .number, context: "RANDOMIZE") }))

        case .functionDeclaration, .endFunction, .defFunction, .functionTypeDeclaration:
            // Declarations are hoisted by the analyzer; the body is built as
            // its own function and never runs inline.
            break
        case .closureAssignment(_, let name, _, let parameters, let returnType, let captures, let body):
            let target = variable(name)
            let made = try makeClosure(parameters: parameters, returnType: returnType, captures: captures, body: .block(body))
            guard model.isAssignable(made.type, to: target.type) else {
                throw CompileError("Type error: Cannot assign this closure to \(name.name) (\(target.type.name))", at: location)
            }
            emit(.store(target, made))
        case .typeDeclaration, .typeField, .endType, .classDeclaration, .classField, .endClass,
             .interfaceDeclaration, .interfaceFunctionSignature, .endInterface, .implementsDeclaration, .inheritsDeclaration:
            // Declarations are hoisted by the analyzer and never run.
            break
        case .importDirective:
            break  // Expanded by SourceLoader before the builder sees the program.
        case .onErrorGoto(let target):
            guard signature == nil else { throw unsupported("ON ERROR inside a FUNCTION") }
            guard let target else { emit(.onError(handler: nil)); return }
            let block = try blockForTarget(target)
            if let existing = function.errorHandlerBlocks.firstIndex(of: block) {
                emit(.onError(handler: existing))
            } else {
                function.errorHandlerBlocks.append(block)
                emit(.onError(handler: function.errorHandlerBlocks.count - 1))
            }
        case .error(let number):
            emit(.raise(try lowerExpression(number, expecting: .number, context: "ERROR")))
        case .resumeNext:
            guard signature == nil else { throw unsupported("RESUME inside a FUNCTION") }
            terminate(.resumeNext)
        case .files:
            emit(.filesList)
        case .system(let command):
            emit(.systemCommand(try lowerExpression(command, expecting: .string, context: "SYSTEM")))
        case .yield:
            // A yield is where the interpreter runs up to eight queued events.
            emit(.drainEvents(limit: 8))
        case .onEventCall(let selector, let handler):
            let (name, payload) = try eventHandler(handler)
            emit(.onEvent(type: selector.type, subtype: selector.subtype ?? "", handler: name, payloadType: payload))
        case .onTimerEvent(let timer, let ticks, let handler):
            let (name, payload) = try eventHandler(handler)
            let object = BIRExpression.load(variable(timer))
            guard case .system("SECONDSTIMER") = object.type else {
                throw CompileError("\(timer.name) is not a SecondsTimer", at: location)
            }
            let count = try ticks.map { try lowerExpression($0, expecting: .number, context: "ON TIMER") } ?? .number(1)
            emit(.onTimer(object, ticks: count, handler: name, payloadType: payload))
        case .join(let expression):
            emit(.discard(.hostCall("basic_rt_task_join", [boxed(try lowerExpression(expression))], returns: .void)))
        case .cancelTask(let expression):
            emit(.discard(.hostCall("basic_rt_task_cancel", [boxed(try lowerExpression(expression))], returns: .void)))
        case .background(let expression):
            emit(.discard(.hostCall("basic_rt_task_background", [boxed(try lowerExpression(expression))], returns: .void)))
        case .load, .save, .cd, .pwd:
            throw CompileError("\(describe(statement)) is a direct-mode command and cannot be compiled", at: location)
        default:
            throw unsupported(describe(statement))
        }
    }

    private func describe(_ statement: Statement) -> String {
        let text = String(describing: statement)
        return String(text.prefix { $0 != "(" }).uppercased()
    }

    private func describe(_ expression: Expression) -> String {
        let text = String(describing: expression)
        return String(text.prefix { $0 != "(" })
    }

    /// Lowers the right-hand side of an assignment. A value of the wrong
    /// kind is the interpreter's *runtime* type error — which ON ERROR can
    /// trap — so it compiles to that failure rather than being refused.
    /// Returns nil when the statement became the failure.
    private func lowerAssigned(_ expression: Expression, to type: BIRType, name: String) throws -> BIRExpression? {
        let lowered = try lowerExpression(expression)
        if lowered.type == type { return lowered }
        if type == .variant || lowered.type == .variant { return convert(lowered, to: type, name: name) }
        if model.isAssignable(lowered.type, to: type) { return lowered }
        let message: String
        switch type {
        case .number: message = "Cannot assign non-numeric value to \(name)"
        case .string: message = "Cannot assign non-string value to \(name)"
        case .boolean: message = "Boolean \(name) must be FALSE, TRUE, 0, or 1"
        case .composite(let typeName): message = "Cannot assign non-\(model.types[typeName]?.displayName ?? typeName) value to \(name)"
        case .dictionary: message = "Cannot assign non-dictionary value to \(name)"
        case .closure, .array: message = "Type Mismatch"
        case .system: message = "Type Mismatch"
        case .void, .variant: message = "Cannot assign to \(name)"
        }
        emit(.failType(message))
        return nil
    }

    /// A value as a VARIANT: itself when it already is one, else boxed.
    private func boxed(_ value: BIRExpression) -> BIRExpression {
        value.type == .variant ? value : .box(value)
    }

    /// Converts across the VARIANT boundary: boxes into it, unboxes out of
    /// it (checked at runtime). `name` makes the failure the assignment's
    /// type error; nil makes it the expression's runtime error.
    private func convert(_ value: BIRExpression, to type: BIRType, name: String?) -> BIRExpression {
        if value.type == type { return value }
        if type == .variant { return .box(value) }
        if value.type == .variant { return .unbox(value, type, name: name) }
        return value
    }

    /// `object.Method(args)` on a host-implemented object: typed from the
    /// class's member table; the runtime does the rest.
    private func lowerSystemCall(_ receiver: BIRExpression, _ typeName: String, _ method: VariableName, _ arguments: [Expression]) throws -> BIRExpression {
        guard let member = SemanticModel.systemMember(method.normalized, of: typeName) else {
            throw CompileError("\(typeName.capitalized) has no method \(method.name)", at: location)
        }
        if let count = member.parameters, count != arguments.count {
            throw CompileError("\(method.name.lowercased()) expects \(count) argument\(count == 1 ? "" : "s")", at: location)
        }
        return .systemCall(receiver, method: method.normalized, try arguments.map { try lowerExpression($0) }, returns: member.returns)
    }

    /// Stores into any place with the operation its shape needs.
    private func emitStore(_ place: BIRPlace, _ value: BIRExpression) {
        switch place {
        case .variable(let target): emit(.store(target, value))
        case .element(let target, let indexes): emit(.storeElement(target, indexes, value))
        case .field: emit(.storeField(place, value))
        case .arrayElement, .dictionaryEntry, .valueEntry, .valueField: emit(.storePlace(place, value))
        }
    }

    private func isInterface(_ type: BIRType) -> Bool {
        if case .composite(let name) = type { return model.types[name]?.kind == .interface }
        return false
    }

    private func defaultValue(for type: BIRType) -> BIRExpression {
        switch type {
        case .number, .void: return .number(0)
        case .string: return .string("")
        case .boolean: return .boolean(false)
        case .composite(let name): return .construct(name)
        case .closure: return .number(0)  // never stored: closure slots start empty
        case .variant, .array, .system: return .emptyValue
        case .dictionary: return .newDictionary
        }
    }

    /// The storage a reference names: its base variable or element, then
    /// each `.field` in turn, with the interpreter's access checks.
    private func lowerPlace(_ reference: VariableReference) throws -> BIRPlace {
        let base = variable(reference.base)
        var place: BIRPlace
        if reference.indexes.isEmpty {
            place = .variable(base)
        } else if base.rank == nil, base.type == .dictionary {
            guard reference.indexes.count == 1 else { throw CompileError("\(reference.base.name) expects 1 key", at: location) }
            place = .dictionaryEntry(.variable(base), key: try lowerExpression(reference.indexes[0]), name: reference.base.name)
        } else if base.rank == nil, base.type == .variant {
            place = .valueEntry(.variable(base), try reference.indexes.map { try lowerExpression($0) }, name: reference.base.name)
        } else {
            guard let rank = base.rank else { throw CompileError("\(reference.base.name) is not an array", at: location) }
            guard rank == reference.indexes.count else { throw CompileError("\(reference.base.name) expects \(rank) indexes", at: location) }
            place = .element(base, try reference.indexes.map { try lowerExpression($0, expecting: .number, context: "\(reference.base.name) index") })
        }
        for (position, fieldName) in reference.fields.enumerated() {
            let indexes = reference.fieldIndexes.indices.contains(position) ? reference.fieldIndexes[position] : []
            if place.type == .variant {
                place = .valueField(place, field: fieldName, name: reference.base.name)
                if !indexes.isEmpty {
                    place = .valueEntry(place, try indexes.map { try lowerExpression($0) }, name: fieldName)
                }
                continue
            }
            let found = try resolveField(fieldName, on: place.type, baseName: reference.base.name)
            place = .field(place, index: found.index, type: found.field.type)
            if !indexes.isEmpty {
                guard case .array(_, let rank) = found.field.type else {
                    throw CompileError("\(fieldName) is not an array", at: location)
                }
                guard rank == indexes.count else { throw CompileError("\(fieldName) expects \(rank) indexes", at: location) }
                place = .arrayElement(place, try indexes.map { try lowerExpression($0, expecting: .number, context: "\(fieldName) index") }, name: found.field.displayName)
            }
        }
        return place
    }

    /// Finds a field by name on a composite type, checking visibility.
    private func resolveField(_ fieldName: String, on type: BIRType, baseName: String) throws -> (index: Int, field: SemanticModel.Field) {
        guard case .composite(let typeName) = type else {
            throw CompileError("\(baseName) has no field \(fieldName)", at: location)
        }
        guard let found = model.field(fieldName.uppercased(), of: typeName) else {
            throw CompileError("\(model.types[typeName]?.displayName ?? typeName) has no field \(fieldName)", at: location)
        }
        try checkAccess(found.field.visibility, owner: found.field.owner, what: fieldName)
        return found
    }

    /// The interpreter's PRIVATE/PROTECTED rules, applied at compile time.
    private func checkAccess(_ visibility: BASICMemberVisibility, owner: String, what: String) throws {
        switch visibility {
        case .public:
            return
        case .private:
            guard ownerClass == owner else { throw CompileError("Type error: \(what) is PRIVATE", at: location) }
        case .protected:
            guard let ownerClass, ownerClass == owner || model.isClass(ownerClass, subclassOf: owner) else {
                throw CompileError("Type error: \(what) is PROTECTED", at: location)
            }
        }
    }

    /// A place as a value: loads, element reads, and field reads.
    private func load(_ place: BIRPlace) -> BIRExpression {
        switch place {
        case .variable(let variable): return variable.rank == nil ? .load(variable) : .loadArray(variable)
        case .element(let variable, let indexes): return .element(variable, indexes)
        case .field(let base, let index, let type): return .field(load(base), index: index, type: type)
        case .arrayElement(let base, let indexes, let name): return .elementOf(load(base), indexes, name: name)
        case .dictionaryEntry(let base, let key, let name): return .dictionaryGet(load(base), key: key, name: name)
        case .valueEntry(let base, let indexes, let name): return .valueIndex(load(base), indexes, name: name)
        case .valueField(let base, let field, let name): return .valueField(load(base), field: field, name: name)
        }
    }

    /// The implementations a method call may reach, by runtime type — one
    /// when nothing overrides it, several for a virtual or interface call.
    private func candidates(for method: VariableName, on type: BIRType) throws -> (candidates: [BIRMethodCandidate], signature: SemanticModel.Function) {
        guard case .composite(let typeName) = type, let composite = model.types[typeName] else {
            throw CompileError("\(type.name) has no method \(method.name)", at: location)
        }
        var candidates: [BIRMethodCandidate] = []
        var signature: SemanticModel.Function?
        switch composite.kind {
        case .record:
            throw CompileError("\(composite.displayName) has no method \(method.name)", at: location)
        case .classType:
            guard let resolved = model.lookupMethod(method.normalized, in: typeName) else {
                throw CompileError("\(composite.displayName) has no method \(method.name)", at: location)
            }
            try checkAccess(resolved.visibility, owner: resolved.owner!, what: method.name)
            signature = resolved
            for className in model.classFamily(of: typeName) {
                if let implementation = model.lookupMethod(method.normalized, in: className) {
                    candidates.append(BIRMethodCandidate(typeIndex: model.types[className]!.index, function: implementation.name))
                }
            }
        case .interface:
            guard composite.members[method.normalized] != nil else {
                throw CompileError("\(composite.displayName) has no method \(method.name)", at: location)
            }
            for className in model.classes(conformingTo: typeName) {
                guard let implementation = model.implementation(of: method.normalized, interface: typeName, in: className) else {
                    throw CompileError("CLASS \(model.types[className]!.displayName) does not implement \(composite.displayName).\(method.name)", at: location)
                }
                signature = signature ?? implementation
                candidates.append(BIRMethodCandidate(typeIndex: model.types[className]!.index, function: implementation.name))
            }
            guard let found = signature else {
                throw CompileError("No CLASS implements \(composite.displayName)", at: location)
            }
            signature = found
        }
        // Collapse to one candidate when every runtime type lands on the same
        // function.
        if Set(candidates.map(\.function)).count == 1 { candidates = [candidates[0]] }
        return (candidates, signature!)
    }

    /// Lowers a method call; the receiver is copied in and written back.
    private func lowerMethodCall(_ reference: VariableReference, _ method: VariableName, _ arguments: [Expression], wantsValue: Bool) throws -> BIRExpression? {
        let place = try lowerPlace(reference)
        // `rec.Items(i)` parses as a method call; when no such method exists
        // but a field does, it is the field (indexed when it is an array) —
        // the interpreter's fallback in callMethod.
        if case .composite(let typeName) = place.type, let composite = model.types[typeName],
           (composite.kind == .record || model.lookupMethod(method.normalized, in: typeName) == nil),
           let found = model.field(method.normalized, of: typeName) {
            try checkAccess(found.field.visibility, owner: found.field.owner, what: method.name)
            var fieldPlace = BIRPlace.field(place, index: found.index, type: found.field.type)
            if !arguments.isEmpty {
                guard case .array(_, let rank) = found.field.type else { throw CompileError("\(method.name) is not an array", at: location) }
                guard rank == arguments.count else { throw CompileError("\(method.name) expects \(rank) indexes", at: location) }
                fieldPlace = .arrayElement(fieldPlace, try arguments.map { try lowerExpression($0, expecting: .number, context: "\(method.name) index") }, name: found.field.displayName)
            }
            return load(fieldPlace)
        }
        if place.type == .variant {
            // What this means is only known at run time: an object takes it
            // as a method, a record as a field. The runtime decides, as the
            // interpreter does.
            let call = BIRExpression.valueCall(load(place), method: method.name, try arguments.map { boxed(try lowerExpression($0)) }, name: reference.base.name)
            if wantsValue { return call }
            emit(.discard(call))
            return nil
        }
        let (candidates, signature) = try candidates(for: method, on: place.type)
        let parameters = Array(signature.parameters.dropFirst())
        guard arguments.count == parameters.count else {
            throw CompileError("Function \(signature.displayName) expects \(parameters.count) arguments, got \(arguments.count)", at: location)
        }
        let lowered = try zip(arguments, parameters).map { argument, parameter in
            try lowerExpression(argument, expecting: parameter.type, context: "\(signature.displayName) parameter \(parameter.name)")
        }
        if wantsValue {
            guard signature.returnType != .void else {
                throw CompileError("VOID function \(signature.displayName) cannot be used in an expression", at: location)
            }
            return .callMethod(receiver: place, candidates: candidates, arguments: lowered, returns: signature.returnType)
        }
        emit(.callMethod(receiver: place, candidates: candidates, arguments: lowered, result: nil))
        return nil
    }

    /// `File.Method(...)` on the shared file service — when no variable of
    /// that name exists, as the interpreter decides it.
    private func isFileService(_ reference: VariableReference) -> Bool {
        reference.base.normalized == "FILE" && reference.indexes.isEmpty && reference.fields.isEmpty
            && model.info("FILE", in: functionName) == nil
    }

    /// The service members basicc compiles, with their signatures.
    private static let fileServiceMembers: [String: (name: String, parameters: [BIRType], returns: BIRType, minimum: Int, defaults: [BIRExpression])] = [
        "CWD": ("CWD", [], .string, 0, []), "CWD$": ("CWD", [], .string, 0, []),
        "CHDIR": ("CHDIR", [.string], .void, 1, []),
        "MKDIR": ("MKDIR", [.string], .void, 1, []),
        "RM": ("RM", [.string], .void, 1, []),
        "RENAME": ("RENAME", [.string, .string], .void, 2, []),
        "EXISTS": ("EXISTS", [.string], .boolean, 1, []),
        "ISDIR": ("ISDIR", [.string], .boolean, 1, []),
        "READTEXT": ("READTEXT", [.string], .string, 1, []), "READTEXT$": ("READTEXT", [.string], .string, 1, []),
        "WRITETEXT": ("WRITETEXT", [.string, .string], .void, 2, []),
        "READBYTES": ("READBYTES", [.string], .string, 1, []), "READBYTES$": ("READBYTES", [.string], .string, 1, []),
        "WRITEBYTES": ("WRITEBYTES", [.string, .string], .void, 2, []),
        "APPENDBYTES": ("APPENDBYTES", [.string, .string], .void, 2, []),
        "READJSON": ("READJSON", [.string, .boolean], .variant, 1, [.boolean(true)]),
        "WRITEJSON": ("WRITEJSON", [.string, .variant, .boolean], .void, 2, [.boolean(false)]),
        "FILES": ("FILES", [.string], .variant, 0, []), "FILES$": ("FILES", [.string], .variant, 0, []),
    ]

    private func lowerFileService(_ method: VariableName, _ arguments: [Expression]) throws -> (String, [BIRExpression], BIRType) {
        guard let member = Self.fileServiceMembers[method.normalized] else {
            throw CompileError("File has no shared method \(method.name)", at: location)
        }
        guard (member.minimum...member.parameters.count).contains(arguments.count) else {
            if member.minimum == member.parameters.count {
                throw CompileError("File.\(method.name) expects \(member.parameters.count) argument\(member.parameters.count == 1 ? "" : "s")", at: location)
            }
            throw CompileError("File.\(method.name) expects \(member.minimum) to \(member.parameters.count) arguments", at: location)
        }
        var lowered = try zip(arguments, member.parameters).map { argument, type in
            try lowerExpression(argument, expecting: type, context: "File.\(method.name)")
        }
        // Trailing optional arguments take their defaults (FILES$ with no
        // directory stays empty: the runtime uses the current directory).
        let missing = member.parameters.count - arguments.count
        if missing > 0, member.defaults.count >= missing {
            lowered.append(contentsOf: member.defaults.suffix(missing))
        }
        return (member.name, lowered, member.returns)
    }

    /// `NEW Class(args)`: a default instance, then its NEW method if any.
    private func lowerNew(_ className: String, _ arguments: [Expression]) throws -> BIRExpression {
        let typeName = className.uppercased()
        guard let type = model.types[typeName], type.kind == .classType else {
            throw CompileError("Unknown CLASS \(className)", at: location)
        }
        guard let constructor = model.lookupMethod("NEW", in: typeName) else {
            guard arguments.isEmpty else { throw CompileError("CLASS \(type.displayName) has no constructor", at: location) }
            return .construct(typeName)
        }
        let instance = hidden("new", .composite(typeName))
        emit(.store(instance, .construct(typeName)))
        let parameters = Array(constructor.parameters.dropFirst())
        guard arguments.count == parameters.count else {
            throw CompileError("Function \(constructor.displayName) expects \(parameters.count) arguments, got \(arguments.count)", at: location)
        }
        let lowered = try zip(arguments, parameters).map { argument, parameter in
            try lowerExpression(argument, expecting: parameter.type, context: "NEW parameter \(parameter.name)")
        }
        emit(.callMethod(receiver: .variable(instance), candidates: [BIRMethodCandidate(typeIndex: type.index, function: constructor.name)], arguments: lowered, result: nil))
        return .load(instance)
    }

    /// A read target as a reference, so it can become a place.
    private func readTargetReference(_ target: ReadTarget) -> VariableReference {
        switch target {
        case .variable(let name): return VariableReference(base: name)
        case .reference(let reference): return reference
        }
    }

    private func lowerReadTarget(_ target: ReadTarget) throws -> BIRReadTarget {
        switch target {
        case .variable(let name):
            return .variable(variable(name))
        case .reference(let reference):
            guard reference.fields.isEmpty else { throw unsupported("READ into a field") }
            let indexes = try reference.indexes.map { try lowerExpression($0, expecting: .number, context: "\(reference.base.name) index") }
            return indexes.isEmpty ? .variable(variable(reference.base)) : .element(variable(reference.base), indexes)
        }
    }

    /// A call used as a statement runs for its effect; anything else is
    /// evaluated and dropped, as the interpreter does.
    /// The function an `ON …` names, and the type index of the event object
    /// its parameter asks for (-1 for a VARIANT or DICTIONARY).
    private func eventHandler(_ handler: VariableName) throws -> (name: String, payloadType: Int) {
        guard let function = model.functions[handler.normalized] else {
            throw CompileError("Function \(handler.name) is not defined", at: location)
        }
        guard !function.isAsync else {
            throw CompileError("Event handler \(handler.name) must be synchronous", at: location)
        }
        model.noteEventHandler(function.name)
        guard let parameter = function.parameters.first else { return (function.name, -1) }
        guard case .composite(let typeName) = parameter.type, let type = model.types[typeName] else {
            return (function.name, -1)
        }
        return (function.name, type.index)
    }

    private func lowerExpressionStatement(_ expression: Expression) throws {
        switch expression {
        case .callOrArray(let name, let arguments), .functionCall(let name, let arguments):
            if let userFunction = model.functions[name.normalized] {
                if userFunction.isAsync {
                    // A task nobody keeps: the interpreter's error.
                    let launch = BIRExpression.asyncLaunch(userFunction.name, try lowerArguments(arguments, for: userFunction))
                    emit(.discard(.hostCall("basic_rt_task_discard", [launch], returns: .void)))
                    return
                }
                emit(.call(userFunction.name, try lowerArguments(arguments, for: userFunction)))
                return
            }
            if BIRIntrinsic.lookup(name.normalized, argumentCount: arguments.count) == nil,
               let signature = model.signature(of: variable(name).type) {
                if case .callClosure(let closure, let lowered, _) = try lowerClosureCall(.load(variable(name)), signature: signature, arguments, name: name.name) {
                    emit(.callClosure(closure, lowered))
                }
                return
            }
        case .methodCall(let reference, let method, let arguments):
            if isFileService(reference) {
                let (member, lowered, _) = try lowerFileService(method, arguments)
                emit(.fileService(method: member, arguments: lowered))
                return
            }
            if case .system(let typeName) = variable(reference.base).type, reference.indexes.isEmpty, reference.fields.isEmpty {
                emit(.discard(try lowerSystemCall(.load(variable(reference.base)), typeName, method, arguments)))
                return
            }
            _ = try lowerMethodCall(reference, method, arguments, wantsValue: false)
            return
        default:
            break
        }
        _ = try lowerExpression(expression)
    }

    // MARK: - Control flow helpers

    private func lowerSingleLineIf(_ condition: Expression, _ thenAction: ConditionalAction, _ elseAction: ConditionalAction?) throws {
        let thenBlock = newBlock("if.then")
        let elseBlock = newBlock("if.else")
        let join = newBlock("if.end")
        terminate(.branch(try lowerCondition(condition), then: thenBlock, else: elseBlock))
        current = thenBlock
        try lowerAction(thenAction, join: join)
        current = elseBlock
        if let elseAction {
            try lowerAction(elseAction, join: join)
        } else {
            terminate(.jump(join))
        }
        current = join
    }

    private func lowerAction(_ action: ConditionalAction, join: BIRBlockID) throws {
        switch action {
        case .branch(let target):
            terminate(.jump(try blockForTarget(target)))
        case .statement(let statement):
            try lower(statement)
            terminate(.jump(join))
        }
    }

    private func lowerComputedJump(targets: [BranchTarget], selector: Expression, isGosub: Bool) throws {
        let selected = hidden("on", .number)
        emit(.store(selected, .intrinsic(.cint, [try lowerExpression(selector, expecting: .number, context: "ON")])))
        let afterOn = newBlock("on.next")
        for (index, target) in targets.enumerated() {
            let matched = newBlock("on.\(index + 1)")
            let next = newBlock("on.test")
            terminate(.branch(.compare(.equal, .load(selected), .number(Double(index + 1))), then: matched, else: next))
            current = matched
            let block = try blockForTarget(target)
            if isGosub {
                terminate(.gosub(block, resume: afterOn))
            } else {
                terminate(.jump(block))
            }
            current = next
        }
        terminate(.jump(afterOn))
        current = afterOn
    }

    private func lowerFor(_ name: VariableName, _ start: Expression, _ end: Expression, _ step: Expression?) throws {
        let declared = variable(name)
        // A VARIANT counter is counted in a number of its own and written
        // back each time round, so the body sees the value the interpreter
        // would have put there. The interpreter has no type here at all, and
        // a program that read a number out of a control into the variable it
        // later counts with is ordinary BASIC.
        let isVariant = declared.type == .variant && declared.rank == nil
        let counter = isVariant ? hidden("for.counter", .number) : declared
        let mirror: BIRVariable? = isVariant ? declared : nil
        guard counter.type == .number, counter.rank == nil else {
            throw CompileError("Type error: FOR variable \(name.name) must be numeric", at: location)
        }
        let endSlot = hidden("for.end", .number)
        let stepSlot = hidden("for.step", .number)
        emit(.store(counter, try lowerExpression(start, expecting: .number, context: "FOR start")))
        emit(.store(endSlot, try lowerExpression(end, expecting: .number, context: "FOR end")))
        emit(.store(stepSlot, try step.map { try lowerExpression($0, expecting: .number, context: "FOR STEP") } ?? .number(1)))

        let zeroStep = newBlock("for.zerostep")
        let check = newBlock("for.check")
        terminate(.branch(.compare(.equal, .load(stepSlot), .number(0)), then: zeroStep, else: check))
        current = zeroStep
        emit(.fail("FOR STEP cannot be 0"))
        terminate(.end)

        current = check
        let body = newBlock("for.body")
        let exit = newBlock("for.end")
        terminate(.branch(loopContinues(counter, endSlot, stepSlot), then: body, else: exit))
        current = body
        if let mirror { emit(.store(mirror, convert(.load(counter), to: .variant, name: nil))) }
        frames.append(.forLoop(variable: counter, mirror: mirror, end: endSlot, step: stepSlot, body: body, exit: exit))
    }

    /// `(step > 0 AND counter <= end) OR (step <= 0 AND counter >= end)`.
    private func loopContinues(_ counter: BIRVariable, _ end: BIRVariable, _ step: BIRVariable) -> BIRExpression {
        .logical(.or,
            .logical(.and, .compare(.greater, .load(step), .number(0)), .compare(.lessEqual, .load(counter), .load(end))),
            .logical(.and, .compare(.lessEqual, .load(step), .number(0)), .compare(.greaterEqual, .load(counter), .load(end))))
    }

    private func lowerNext(_ name: VariableName?) throws {
        guard case .forLoop(let counter, let mirror, let end, let step, let body, let exit)? = frames.last else {
            throw CompileError("NEXT without FOR", at: location)
        }
        let loopName = mirror?.name ?? counter.name
        if let name, name.normalized != loopName {
            throw CompileError("NEXT \(name.name) does not match FOR \(loopName)", at: location)
        }
        frames.removeLast()
        // A VARIANT counter may have been assigned inside the body, as the
        // interpreter's would have been, so it is read back before it counts.
        if let mirror { emit(.store(counter, convert(.load(mirror), to: .number, name: mirror.name))) }
        emit(.store(counter, .arithmetic(.add, .load(counter), .load(step))))
        if let mirror { emit(.store(mirror, convert(.load(counter), to: .variant, name: nil))) }
        terminate(.branch(loopContinues(counter, end, step), then: body, else: exit))
        current = exit
    }

    private func lowerCaseClause(_ clause: CaseClause, subject: BIRVariable) throws -> BIRExpression {
        if subject.type == .variant {
            switch clause {
            case .equals(let expression):
                return .valueEqual(.load(subject), boxed(try lowerExpression(expression)))
            case .range(let lower, let upper):
                let value = BIRExpression.unbox(.load(subject), .number, name: nil)
                return .logical(.and,
                    .compare(.greaterEqual, value, try lowerExpression(lower, expecting: .number, context: "CASE")),
                    .compare(.lessEqual, value, try lowerExpression(upper, expecting: .number, context: "CASE")))
            case .comparison(let operation, let expression):
                guard let comparison = Self.comparison(for: operation) else { throw CompileError("Invalid CASE comparison", at: location) }
                return .compare(comparison, .unbox(.load(subject), .number, name: nil), try lowerExpression(expression, expecting: .number, context: "CASE IS"))
            }
        }
        switch clause {
        case .equals(let expression):
            return .compare(.equal, .load(subject), try lowerExpression(expression, expecting: subject.type, context: "CASE"))
        case .range(let lower, let upper):
            return .logical(.and,
                .compare(.greaterEqual, .load(subject), try lowerExpression(lower, expecting: subject.type, context: "CASE")),
                .compare(.lessEqual, .load(subject), try lowerExpression(upper, expecting: subject.type, context: "CASE")))
        case .comparison(let operation, let expression):
            guard let comparison = Self.comparison(for: operation) else {
                throw CompileError("Invalid CASE comparison", at: location)
            }
            return .compare(comparison, .load(subject), try lowerExpression(expression, expecting: subject.type, context: "CASE IS"))
        }
    }

    private func unterminatedFrameMessage() -> String {
        switch frames.last! {
        case .ifBlock: return "IF without END IF"
        case .forLoop(let variable, let mirror, _, _, _, _): return "FOR \(mirror?.name ?? variable.name) without NEXT"
        case .select: return "SELECT CASE without END SELECT"
        }
    }

    // MARK: - Expressions

    private func lowerPrintPart(_ part: PrintPart) throws -> BIRPrintItem {
        switch part {
        case .separator:
            return .comma
        case .expression(let expression):
            if case .callOrArray(let name, let arguments) = expression, arguments.count == 1 {
                if name.normalized == "TAB" { return .tab(try lowerExpression(arguments[0], expecting: .number, context: "TAB")) }
                if name.normalized == "SPC" { return .spc(try lowerExpression(arguments[0], expecting: .number, context: "SPC")) }
            }
            return .value(try lowerExpression(expression, expecting: nil, context: "PRINT"))
        }
    }

    /// The truthiness test the interpreter applies to IF conditions.
    private func lowerCondition(_ expression: Expression) throws -> BIRExpression {
        try lowerExpression(expression, expecting: nil, context: "IF")
    }

    /// Lowers an expression, checking it against the type the context needs.
    func lowerExpression(_ expression: Expression, expecting: BIRType?, context: String) throws -> BIRExpression {
        let lowered = try lowerExpression(expression)
        guard let expecting, lowered.type != expecting else { return lowered }
        if expecting == .variant || lowered.type == .variant { return convert(lowered, to: expecting, name: nil) }
        if !model.isAssignable(lowered.type, to: expecting) {
            throw CompileError(
                "Type error: \(context) expects \(expecting.name), got \(lowered.type.name)",
                at: location
            )
        }
        return lowered
    }

    private func lowerExpression(_ expression: Expression) throws -> BIRExpression {
        switch expression {
        case .number(let value): return .number(value)
        case .string(let value):
            return substitutesStrings ? try lowerInterpolated(value) : .string(value)
        case .interpolatedString(let value):
            return try lowerInterpolated(value)
        case .boolean(let value): return .boolean(value)
        case .variable(let name):
            if name.normalized == "ERR" { return .intrinsic(.err, []) }
            if name.normalized == "ERL" { return .intrinsic(.erl, []) }
            if SemanticModel.namedConstants.contains(name.normalized), model.info(name.normalized, in: functionName) == nil, closureLocals?[name.normalized] == nil {
                return .string(name.normalized)
            }
            if let host = SemanticModel.hostVariables[name.normalized], model.info(name.normalized, in: functionName) == nil, closureLocals?[name.normalized] == nil {
                let symbol = ["SCREENWIDTH": "basic_rt_screen_width", "SCREENHEIGHT": "basic_rt_screen_height", "CURRENTDIR$": "basic_rt_current_dir"][name.normalized]!
                return .hostCall(symbol, [], returns: host)
            }
            let resolved = variable(name)
            if resolved.rank != nil { return .loadArray(resolved) }
            return .load(resolved)
        case .unaryMinus(let inner):
            return .negate(try lowerExpression(inner, expecting: .number, context: "unary minus"))
        case .binary(let left, let operation, let right):
            return try lowerBinary(left, operation, right)
        case .callOrArray(let name, let arguments), .functionCall(let name, let arguments):
            return try lowerCall(name, arguments)
        case .variableReference(let reference):
            if case .system(let typeName) = variable(reference.base).type, reference.indexes.isEmpty, reference.fields.count == 1 {
                return try lowerSystemCall(.load(variable(reference.base)), typeName, VariableName(name: reference.fields[0], column: reference.base.column), [])
            }
            return load(try lowerPlace(reference))
        case .closure(let parameters, let returnType, let captures, let body):
            return try makeClosure(parameters: parameters, returnType: returnType, captures: captures, body: .expression(body))
        case .newObject(let className, let arguments):
            if SemanticModel.isSystemClass(className.uppercased()), model.types[className.uppercased()] == nil {
                let systemClass = className.uppercased() == "VTG" ? "VECTORTERMINAL" : className.uppercased()
                return .systemNew(systemClass, try arguments.map { try lowerExpression($0) }, type: SemanticModel.systemTypeName(systemClass))
            }
            return try lowerNew(className, arguments)
        case .methodCall(let reference, let method, let arguments):
            if isFileService(reference) {
                let (member, lowered, returns) = try lowerFileService(method, arguments)
                guard returns != .void else {
                    throw CompileError("VOID function File.\(method.name) cannot be used in an expression", at: location)
                }
                return .fileService(method: member, arguments: lowered, returns: returns)
            }
            if case .system(let typeName) = variable(reference.base).type, reference.indexes.isEmpty, reference.fields.isEmpty {
                let call = try lowerSystemCall(.load(variable(reference.base)), typeName, method, arguments)
                guard call.type != .void else { throw CompileError("VOID function \(method.name) cannot be used in an expression", at: location) }
                return call
            }
            return try lowerMethodCall(reference, method, arguments, wantsValue: true)!
        case .lenFunction(let inner):
            let value = try lowerExpression(inner)
            switch value.type {
            case .string: return .intrinsic(.len, [value])
            case .variant: return .valueLen(value)
            case .array: return .arrayLen(value, name: describe(inner))
            default: throw CompileError("Type error: LEN requires a string or array", at: location)
            }
        case .chrFunction(let inner):
            return .intrinsic(.chr, [try lowerExpression(inner, expecting: .number, context: "CHR$")])
        case .null:
            return .nullValue
        case .systemFunction(let inner):
            return .hostCall("basic_rt_system", [try lowerExpression(inner, expecting: .string, context: "SYSTEM$")], returns: .string)
        case .pointFunction(let point):
            return .hostCall("basic_rt_gfx_point", [try lowerExpression(point.x, expecting: .number, context: "POINT"), try lowerExpression(point.y, expecting: .number, context: "POINT")], returns: .number)
        case .await(let inner):
            // AWAIT runs the task (if it has not run) and yields its value;
            // a non-task value passes through, the interpreter's rule.
            let value = try lowerExpression(inner)
            guard value.type == .variant else { return value }
            let awaited = BIRExpression.hostCall("basic_rt_task_await", [value], returns: .variant)
            if case .callOrArray(let name, _) = inner, let userFunction = model.functions[name.normalized], userFunction.isAsync, userFunction.returnType != .void {
                return convert(awaited, to: userFunction.returnType, name: nil)
            }
            return awaited
        default:
            throw unsupported(describe(expression))
        }
    }

    /// `"Hello ${name}"`: the `${…}` pieces are parsed with the interpreter's
    /// parser at compile time and joined with the text between them.
    private func lowerInterpolated(_ template: String) throws -> BIRExpression {
        var pieces: [BIRExpression] = []
        var literal = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "$", template.index(after: index) < template.endIndex, template[template.index(after: index)] == "{" {
                let expressionStart = template.index(index, offsetBy: 2)
                guard let expressionEnd = template[expressionStart...].firstIndex(of: "}") else {
                    throw CompileError("Unterminated string interpolation", at: location)
                }
                let source = String(template[expressionStart..<expressionEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.isEmpty else { throw CompileError("Empty string interpolation", at: location) }
                if !literal.isEmpty { pieces.append(.string(literal)); literal = "" }
                var parser: Parser
                let parsed: Expression
                do {
                    parser = try Parser(source: source)
                    parsed = try parser.parseExpressionOnly()
                } catch let error as BASICError {
                    throw CompileError(error.description, at: location)
                }
                let value = try lowerExpression(parsed)
                pieces.append(value.type == .string ? value : .text(value))
                index = template.index(after: expressionEnd)
            } else {
                literal.append(template[index])
                index = template.index(after: index)
            }
        }
        if !literal.isEmpty || pieces.isEmpty { pieces.append(.string(literal)) }
        return pieces.dropFirst().reduce(pieces[0]) { .concat($0, $1) }
    }

    private func lowerBinary(_ left: Expression, _ operation: BinaryOperation, _ right: Expression) throws -> BIRExpression {
        var l = try lowerExpression(left)
        var r = try lowerExpression(right)
        // With a VARIANT on either side the kind is only known at runtime;
        // the runtime then applies the interpreter's rules.
        let dynamic = l.type == .variant || r.type == .variant
        switch operation {
        case .add:
            if l.type == .string && r.type == .string { return .concat(l, r) }
            if dynamic { return .valueAdd(boxed(l), boxed(r)) }
            try requireNumbers(l, r, "+")
            return .arithmetic(.add, l, r)
        case .subtract, .multiply, .divide:
            if dynamic { l = convert(l, to: .number, name: nil); r = convert(r, to: .number, name: nil) }
            let symbol = ["subtract": "-", "multiply": "*", "divide": "/"][String(describing: operation)] ?? "?"
            try requireNumbers(l, r, symbol)
            let op: BIRArithmetic = operation == .subtract ? .subtract : operation == .multiply ? .multiply : .divide
            return .arithmetic(op, l, r)
        case .equal, .notEqual:
            if dynamic || l.type.isComposite || l.type == .dictionary || l.type.isArray || r.type.isComposite || r.type == .dictionary || r.type.isArray {
                let equal = BIRExpression.valueEqual(boxed(l), boxed(r))
                return operation == .equal ? equal : .arithmetic(.subtract, .number(1), equal)
            }
            // The interpreter compares values of different kinds as simply unequal.
            if l.type != r.type { return .number(operation == .equal ? 0 : 1) }
            return .compare(Self.comparison(for: operation)!, l, r)
        case .less, .lessEqual, .greater, .greaterEqual:
            if dynamic { l = convert(l, to: .number, name: nil); r = convert(r, to: .number, name: nil) }
            // The interpreter orders numbers only; anything else is its
            // "Expected a number" runtime error, reported here instead.
            guard l.type == .number, r.type == .number else {
                throw CompileError("Type error: Expected a number", at: location)
            }
            return .compare(Self.comparison(for: operation)!, l, r)
        case .and:
            return .logical(.and, l, r)
        case .or:
            return .logical(.or, l, r)
        }
    }

    private func requireNumbers(_ l: BIRExpression, _ r: BIRExpression, _ symbol: String) throws {
        guard l.type == .number, r.type == .number else {
            throw CompileError("Type error: Expected a number on both sides of \(symbol)", at: location)
        }
    }

    private static func comparison(for operation: BinaryOperation) -> BIRComparison? {
        switch operation {
        case .equal: return .equal
        case .notEqual: return .notEqual
        case .less: return .less
        case .lessEqual: return .lessEqual
        case .greater: return .greater
        case .greaterEqual: return .greaterEqual
        default: return nil
        }
    }

    /// A closure literal's body: an expression, or the block's lines.
    private enum ClosureBody {
        case expression(Expression)
        case block([ClosureBodyLine])
    }

    /// Builds a closure literal: decides the captures, synthesizes the body
    /// function and its environment type, and returns the make expression.
    ///
    /// The interpreter's rule: with no capture list, every variable the body
    /// refers to (that is not a parameter, function, or builtin) is captured
    /// by snapshot; with one, only the listed names are, and the rest resolve
    /// live. Captures become locals of each call.
    private func makeClosure(parameters: [FunctionParameter], returnType: BASICType, captures: [ClosureCaptureSpec], body: ClosureBody) throws -> BIRExpression {
        let number = closures.next()
        let line = ParsedLine(number: location.lineNumber, displayLineNumber: location.line, fileName: location.file, sourceLineNumber: location.line, statementNumber: location.statement, isImported: false, statement: .empty)
        let parameterVariables = try parameters.map {
            BIRVariable(name: $0.variable.normalized, type: try SemanticAnalyzer.mapWithModel(model, $0.type, for: $0.variable.name, at: line), scope: .local)
        }
        guard returnType != .scalar(.variant) else {
            throw CompileError("a closure needs AS <type>; basicc cannot infer VARIANT", at: location)
        }
        let resolvedReturn: BIRType = returnType == .void ? .void : try SemanticAnalyzer.mapWithModel(model, returnType, for: "closure", at: line)
        let parameterNames = Set(parameterVariables.map(\.name))

        // Captures, in first-reference order, typed as the creating scope sees them.
        let captureNames: [String]
        if captures.isEmpty {
            switch body {
            case .expression(let expression):
                captureNames = SemanticAnalyzer.freeVariables(in: expression, model: model)
            case .block(let bodyLines):
                captureNames = bodyLines.flatMap { SemanticAnalyzer.freeVariables(in: $0.statement, model: model) }
                    .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            }
        } else {
            captureNames = captures.map { $0.variable.normalized }
        }
        var declaredLocals = Set<String>()
        if case .block(let bodyLines) = body {
            for bodyLine in bodyLines {
                SemanticAnalyzer.forEachStatement(in: bodyLine.statement) { statement in
                    if case .assignment(.local, let name, _, _) = statement { declaredLocals.insert(name.normalized) }
                    if case .dim(.local, let name, _, _) = statement { declaredLocals.insert(name.normalized) }
                }
            }
        }
        let captured = captureNames.filter { !parameterNames.contains($0) && !declaredLocals.contains($0) }.map { name -> BIRVariable in
            let outer = variable(VariableName(name: name, column: 0))
            return BIRVariable(name: name, type: outer.type, scope: .local)
        }
        for capture in captured where variable(VariableName(name: capture.name, column: 0)).rank != nil || capture.type.isComposite {
            throw unsupported("capturing arrays or records in a closure")
        }

        let canonical = SemanticModel.canonicalSignature(parameters: parameterVariables.map(\.type), returnType: resolvedReturn)
        model.addSignature(name: canonical, parameters: parameterVariables.map(\.type), returnType: resolvedReturn)

        let bodyName = "closure$\(number)"
        var environmentName: String?
        var bodyFunction: BIRFunction
        if captured.isEmpty {
            bodyFunction = BIRFunction(name: bodyName, parameters: [BIRVariable(name: "$ENV", type: .composite("$NONE"), scope: .local)] + parameterVariables, returnType: resolvedReturn)
        } else {
            let name = closures.addEnvironment(fields: captured.map { BIRField(name: $0.name, type: $0.type) }, number: number)
            environmentName = name
            bodyFunction = BIRFunction(name: bodyName, parameters: [BIRVariable(name: "$ENV", type: .composite(name), scope: .local)] + parameterVariables, returnType: resolvedReturn)
            bodyFunction.locals += captured
            bodyFunction.environment = (name, captured)
        }

        // Build the body with its own builder, in a scope of parameters + captures + LOCALs.
        let bodyBuilder = FunctionBuilder(lines: lines, model: model, function: nil, owner: owner, closures: closures)
        bodyBuilder.function = bodyFunction
        var locals: [String: BIRVariable] = [:]
        for parameter in parameterVariables { locals[parameter.name] = parameter }
        for capture in captured { locals[capture.name] = capture }
        bodyBuilder.closureSignatureReturn = resolvedReturn
        switch body {
        case .expression(let expression):
            bodyBuilder.closureLines = []
            bodyBuilder.closureLocals = locals
            bodyBuilder.location = location
            bodyBuilder.emitEnvironmentPrologue()
            let value = try bodyBuilder.lowerExpression(expression, expecting: resolvedReturn == .void ? nil : resolvedReturn, context: "closure result")
            bodyBuilder.terminate(.ret(resolvedReturn == .void ? nil : value))
            bodyBuilder.function.pruneUnreachableBlocks()
        case .block(let bodyLines):
            let parsed = bodyLines.enumerated().map { index, bodyLine in
                ParsedLine(number: nil, displayLineNumber: bodyLine.sourceLineNumber, fileName: bodyLine.fileName, sourceLineNumber: bodyLine.sourceLineNumber, statementNumber: index, isImported: false, statement: bodyLine.statement)
            }
            // LOCALs declared in the body are locals too.
            for parsedLine in parsed {
                SemanticAnalyzer.forEachStatement(in: parsedLine.statement) { statement in
                    if case .assignment(.local, let name, let declared, let value) = statement, locals[name.normalized] == nil {
                        var type: BIRType = SemanticAnalyzer.suffixType(name.normalized) ?? .number
                        if let declared, let mapped = try? SemanticAnalyzer.mapWithModel(self.model, declared, for: name.name, at: parsedLine) {
                            type = mapped
                        } else if let value, let inferred = try? self.closureLocalType(of: value, locals: locals) {
                            type = inferred
                        }
                        locals[name.normalized] = BIRVariable(name: name.normalized, type: type, scope: .local)
                    }
                }
            }
            for local in locals.values where !bodyBuilder.function.locals.contains(local) {
                bodyBuilder.function.locals.append(local)
            }
            bodyBuilder.closureLines = parsed
            bodyBuilder.closureLocals = locals
            try bodyBuilder.run()
        }
        closures.functions.append(bodyBuilder.function)

        return .makeClosure(function: bodyName, environment: environmentName, captures: captured.map { .load(variable(VariableName(name: $0.name, column: 0))) }, signature: canonical)
    }

    /// A quick static type for a LOCAL's initial value inside a closure body.
    private func closureLocalType(of expression: Expression, locals: [String: BIRVariable]) throws -> BIRType? {
        switch expression {
        case .number: return .number
        case .string, .interpolatedString: return .string
        case .boolean: return .boolean
        case .variable(let name): return locals[name.normalized]?.type ?? model.variable(name.normalized, in: nil).type
        case .binary(let left, let operation, let right):
            if operation == .add, try closureLocalType(of: left, locals: locals) == .string, try closureLocalType(of: right, locals: locals) == .string { return .string }
            return .number
        case .unaryMinus: return .number
        case .callOrArray(let name, let arguments), .functionCall(let name, let arguments):
            if let userFunction = model.functions[name.normalized] { return userFunction.returnType }
            return BIRIntrinsic.lookup(name.normalized, argumentCount: arguments.count)?.returnType
        case .lenFunction: return .number
        case .chrFunction: return .string
        default: return nil
        }
    }

    /// A call through a closure value, checked against its signature.
    private func lowerClosureCall(_ closure: BIRExpression, signature: BIRSignature, _ arguments: [Expression], name: String) throws -> BIRExpression {
        guard arguments.count == signature.parameterTypes.count else {
            throw CompileError("Function \(name) expects \(signature.parameterTypes.count) arguments, got \(arguments.count)", at: location)
        }
        let lowered = try zip(arguments, signature.parameterTypes).map { argument, type in
            try lowerExpression(argument, expecting: type, context: "\(name) parameter")
        }
        return .callClosure(closure, lowered, returns: signature.returnType)
    }

    /// `NAME(args)`: a closure variable, a user function, an array element,
    /// or a builtin — in the interpreter's order of precedence.
    private func lowerCall(_ name: VariableName, _ arguments: [Expression]) throws -> BIRExpression {
        if model.functions[name.normalized] == nil, BIRIntrinsic.lookup(name.normalized, argumentCount: arguments.count) == nil,
           !BASICKeywords.intrinsicFunctionNames.contains(name.normalized) {
            let candidate = variable(name)
            if let signature = model.signature(of: candidate.type) {
                return try lowerClosureCall(.load(candidate), signature: signature, arguments, name: name.name)
            }
        }
        if let userFunction = model.functions[name.normalized], userFunction.owner == nil {
            guard userFunction.returnType != .void else {
                throw CompileError("VOID function \(userFunction.displayName) cannot be used in an expression", at: location)
            }
            if userFunction.isAsync {
                return .asyncLaunch(userFunction.name, try lowerArguments(arguments, for: userFunction))
            }
            return .call(userFunction.name, try lowerArguments(arguments, for: userFunction), returns: userFunction.returnType)
        }
        if let intrinsic = BIRIntrinsic.lookup(name.normalized, argumentCount: arguments.count) {
            return try lowerIntrinsic(intrinsic, name, arguments)
        }
        if name.normalized == "USING$" {
            guard arguments.count >= 2 else { throw CompileError("USING$ expects at least 2 arguments", at: location) }
            return .usingString(
                format: try lowerExpression(arguments[0], expecting: .string, context: "USING$"),
                values: try arguments.dropFirst().map { try lowerExpression($0) }
            )
        }
        if name.normalized == "TOJSONSTRING" {
            guard arguments.count == 2 else { throw CompileError("\(name.name) expects 2 arguments", at: location) }
            return .jsonEncode(boxed(try lowerExpression(arguments[0])), pretty: try lowerExpression(arguments[1]))
        }
        if name.normalized == "FROMJSONSTRING" {
            guard arguments.count == 2 else { throw CompileError("\(name.name) expects 2 arguments", at: location) }
            return .jsonDecode(try lowerExpression(arguments[0], expecting: .string, context: name.name), permissive: try lowerExpression(arguments[1]))
        }
        let keyed = variable(name)
        if keyed.rank == nil, keyed.type == .dictionary, !arguments.isEmpty {
            guard arguments.count == 1 else { throw CompileError("\(name.name) expects 1 key", at: location) }
            return .dictionaryGet(.load(keyed), key: try lowerExpression(arguments[0]), name: name.name)
        }
        if keyed.rank == nil, keyed.type == .variant, !arguments.isEmpty {
            return .valueIndex(.load(keyed), try arguments.map { try lowerExpression($0) }, name: name.name)
        }
        if let host = try lowerHostBuiltin(name, arguments) { return host }
        if SemanticModel.isSystemClass(name.normalized), model.info(name.normalized, in: functionName) == nil {
            let systemClass = name.normalized == "VTG" ? "VECTORTERMINAL" : name.normalized
            return .systemNew(systemClass, try arguments.map { try lowerExpression($0) }, type: SemanticModel.systemTypeName(systemClass))
        }
        if BASICKeywords.intrinsicFunctionNames.contains(name.normalized) {
            throw unsupported("the builtin \(name.name)")
        }
        let array = variable(name)
        guard let rank = array.rank else {
            throw CompileError("Unknown function \(name.name)", at: location)
        }
        guard rank == arguments.count else {
            throw CompileError("\(name.name) expects \(rank) indexes", at: location)
        }
        let indexes = try arguments.map { try lowerExpression($0, expecting: .number, context: "\(name.name) index") }
        return .element(array, indexes)
    }

    /// The builtins with optional arguments, as runtime calls with the
    /// defaults filled in: `MKI$`, `MKS$`, `MKD$`, `CVI`, `CVS`, `CVD`,
    /// `INPUT$(n, #f)`, `SEEK(n)`.
    private func lowerHostBuiltin(_ name: VariableName, _ arguments: [Expression]) throws -> BIRExpression? {
        func count(_ range: ClosedRange<Int>) throws {
            guard range.contains(arguments.count) else {
                if range.lowerBound == range.upperBound {
                    throw CompileError("\(name.name) expects \(range.lowerBound) argument\(range.lowerBound == 1 ? "" : "s")", at: location)
                }
                throw CompileError("\(name.name) expects \(range.lowerBound) \(range.upperBound - range.lowerBound == 1 ? "or" : "to") \(range.upperBound) arguments", at: location)
            }
        }
        func argument(_ index: Int, _ type: BIRType, default value: BIRExpression) throws -> BIRExpression {
            guard index < arguments.count else { return value }
            return try lowerExpression(arguments[index], expecting: type, context: name.name)
        }
        switch name.normalized {
        case "MKI$":
            try count(1...3)
            return .hostCall("basic_rt_mki", [try argument(0, .number, default: .number(0)), try argument(1, .number, default: .number(16)), try argument(2, .string, default: .string("NATIVE"))], returns: .string)
        case "MKS$", "MKD$":
            try count(1...2)
            return .hostCall(name.normalized == "MKS$" ? "basic_rt_mks" : "basic_rt_mkd", [try argument(0, .number, default: .number(0)), try argument(1, .string, default: .string("NATIVE"))], returns: .string)
        case "CVI":
            try count(1...3)
            return .hostCall("basic_rt_cvi", [try argument(0, .string, default: .string("")), try argument(1, .number, default: .number(16)), try argument(2, .string, default: .string("NATIVE"))], returns: .number)
        case "CVS", "CVD":
            try count(1...2)
            return .hostCall(name.normalized == "CVS" ? "basic_rt_cvs" : "basic_rt_cvd", [try argument(0, .string, default: .string("")), try argument(1, .string, default: .string("NATIVE"))], returns: .number)
        case "INPUT$" where arguments.count == 2:
            return .hostCall("basic_rt_file_input_chars", [try argument(0, .number, default: .number(0)), try argument(1, .number, default: .number(0))], returns: .string)
        case "SEEK":
            try count(1...1)
            return .hostCall("basic_rt_file_seek_position", [try argument(0, .number, default: .number(0))], returns: .number)
        case "INKEY$":
            try count(0...0)
            return .hostCall("basic_rt_inkey", [], returns: .string)
        case "ASYNCVALUE":
            try count(1...1)
            return .hostCall("basic_rt_task_value", [boxed(try lowerExpression(arguments[0]))], returns: .variant)
        case "SLEEP":
            try count(1...1)
            return .hostCall("basic_rt_task_sleep", [try argument(0, .number, default: .number(0))], returns: .variant)
        case "TASKSTATUS$":
            try count(1...1)
            return .hostCall("basic_rt_task_status", [boxed(try lowerExpression(arguments[0]))], returns: .string)
        case "TASKERROR$":
            try count(1...1)
            return .hostCall("basic_rt_task_error", [boxed(try lowerExpression(arguments[0]))], returns: .string)
        case "FIELDCOUNT":
            try count(1...1)
            return .hostCall("basic_rt_field_count", [boxed(try lowerExpression(arguments[0]))], returns: .number)
        case "FIELDNAME$":
            try count(2...2)
            return .hostCall("basic_rt_field_name", [boxed(try lowerExpression(arguments[0])), boxed(try lowerExpression(arguments[1]))], returns: .string)
        case "FIELDMETA":
            try count(2...2)
            return .hostCall("basic_rt_field_meta", [boxed(try lowerExpression(arguments[0])), boxed(try lowerExpression(arguments[1]))], returns: .variant)
        case "FIELDVALUE":
            try count(2...2)
            return .hostCall("basic_rt_field_value", [boxed(try lowerExpression(arguments[0])), boxed(try lowerExpression(arguments[1]))], returns: .variant)
        case "FIELDVALUE$":
            try count(2...2)
            return .unbox(.hostCall("basic_rt_field_value", [boxed(try lowerExpression(arguments[0])), boxed(try lowerExpression(arguments[1]))], returns: .variant), .string, name: nil)
        case "SETFIELD":
            try count(3...3)
            return .hostCall("basic_rt_set_field", [boxed(try lowerExpression(arguments[0])), boxed(try lowerExpression(arguments[1])), boxed(try lowerExpression(arguments[2]))], returns: .variant)
        default:
            return nil
        }
    }

    private func lowerArguments(_ arguments: [Expression], for userFunction: SemanticModel.Function) throws -> [BIRExpression] {
        guard arguments.count == userFunction.parameters.count else {
            throw CompileError(
                "Function \(userFunction.displayName) expects \(userFunction.parameters.count) arguments, got \(arguments.count)",
                at: location
            )
        }
        return try zip(arguments, userFunction.parameters).map { argument, parameter in
            try lowerExpression(argument, expecting: parameter.type, context: "\(userFunction.displayName) parameter \(parameter.name)")
        }
    }

    private func lowerIntrinsic(_ intrinsic: BIRIntrinsic, _ name: VariableName, _ arguments: [Expression]) throws -> BIRExpression {
        var lowered = try arguments.map { try lowerExpression($0) }
        // Normalize the optional-argument forms to a fixed shape.
        switch intrinsic {
        case .mid where lowered.count == 2: lowered.append(.number(-1))
        case .instr where lowered.count == 2: lowered.insert(.number(1), at: 0)
        case .rnd: lowered = []
        default: break
        }
        for (index, expected) in intrinsic.parameterTypes.enumerated() where index < lowered.count && lowered[index].type == .variant {
            lowered[index] = .unbox(lowered[index], expected, name: nil)
        }
        for (argument, expected) in zip(lowered, intrinsic.parameterTypes) where argument.type != expected {
            throw CompileError(
                "Type error: \(name.name) expects \(expected.name), got \(argument.type.name)",
                at: location
            )
        }
        return .intrinsic(intrinsic, lowered)
    }
}
