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
            return BIRCompositeType(name: name, displayName: type.displayName, index: type.index, fields: model.allFields(of: name).map {
                BIRField(name: $0.name, type: $0.type, defaultNumber: $0.defaultNumber, defaultString: $0.defaultString)
            })
        }

        let closures = ClosureContext(firstTypeIndex: module.types.count)
        let main = FunctionBuilder(lines: lines, model: model, function: nil, owner: analyzer.owner, closures: closures)
        main.substitutesStrings = defaultStringSubstitution
        try main.run()
        module.main = main.function

        for name in model.functionOrder {
            let builder = FunctionBuilder(lines: lines, model: model, function: name, owner: analyzer.owner, closures: closures)
            try builder.run()
            module.functions.append(builder.function)
        }
        module.functions.append(contentsOf: closures.functions)
        module.types.append(contentsOf: closures.environmentTypes)
        module.signatures = model.signatures
        return module
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

    /// One open IF / FOR / SELECT.
    private enum Frame {
        case ifBlock(elseBlock: BIRBlockID?, join: BIRBlockID)
        case forLoop(variable: BIRVariable, end: BIRVariable, step: BIRVariable, body: BIRBlockID, exit: BIRBlockID)
        case select(subject: BIRVariable, next: BIRBlockID, elseBlock: BIRBlockID?, end: BIRBlockID)
    }

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
        }
        terminate(signature == nil && closureLines == nil ? .end : .ret(nil))
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
        for index in ownedLines {
            location = SemanticAnalyzer.location(of: sourceLines[index])
            try collectTargets(in: sourceLines[index].statement)
        }
    }

    private func collectTargets(in statement: Statement) throws {
        switch statement {
        case .goto(let number): _ = try blockForTarget(.line(number))
        case .gotoLabel(let label): _ = try blockForTarget(.label(label))
        case .gosub(let target): _ = try blockForTarget(target)
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
            let items = try parts
                .filter { if case .separator(.semicolon) = $0 { return false } else { return true } }
                .map(lowerPrintPart)
            emit(.print(items, newline: !(parts.last?.suppressesNewline ?? false)))

        case .assignment(let kind, let name, _, let value):
            var target = variable(name)
            if kind == .global, signature != nil {
                target = model.variable(name.normalized, in: nil)
            }
            guard target.rank == nil else { throw CompileError("Type error: \(name.name) is an array", at: location) }
            if value == nil, isInterface(target.type) || target.type.isClosure { return }
            guard let stored = try value.map({ try lowerAssigned($0, to: target.type, name: name.name) }) ?? defaultValue(for: target.type) else { return }
            emit(.store(target, stored))
        case .referenceAssignment(let reference, let value):
            guard !reference.hasEmptyIndexList else { throw unsupported("assigning a whole array") }
            let place = try lowerPlace(reference)
            guard let stored = try value.map({ try lowerAssigned($0, to: place.type, name: reference.base.name) }) ?? defaultValue(for: place.type) else { return }
            switch place {
            case .variable(let target): emit(.store(target, stored))
            case .element(let target, let indexes): emit(.storeElement(target, indexes, stored))
            case .field: emit(.storeField(place, stored))
            }
        case .dim(_, let name, let dimensions, _):
            let target = variable(name)
            if dimensions.isEmpty {
                // An interface- or closure-typed slot starts empty, like the interpreter's.
                if !isInterface(target.type), !target.type.isClosure { emit(.store(target, defaultValue(for: target.type))) }
            } else {
                let bounds = try dimensions.map { dimension -> BIRExpression in
                    guard let dimension else { throw unsupported("DIM with an open dimension") }
                    return try lowerExpression(dimension, expecting: .number, context: "DIM \(name.name)")
                }
                emit(.dim(target, bounds))
            }

        case .input(let prompt, .variable(let name)):
            let promptValue = try prompt.map { try lowerExpression($0, expecting: .string, context: "INPUT prompt") }
            emit(.input(prompt: promptValue, into: variable(name)))
        case .input:
            throw unsupported("INPUT into an array element or field")
        case .lineInput(let prompt, .variable(let name), nil, nil, nil, nil):
            let target = variable(name)
            guard target.type == .string, target.rank == nil else {
                throw CompileError("Type error: LINE INPUT needs a string variable, got \(name.name)", at: location)
            }
            emit(.lineInput(prompt: try prompt.map { try lowerExpression($0, expecting: .string, context: "LINE INPUT prompt") }, into: target))
        case .lineInput:
            throw unsupported("LINE INPUT with EXITVAR, LENGTH, MAX, or DEFAULT")
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
        case .optionKeyMode, .optionShellMode, .optionEventInput:
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
            guard recordLength == nil else { throw unsupported("OPEN … LEN") }
            let modeCode: Int
            switch mode {
            case .input: modeCode = 0
            case .output: modeCode = 1
            case .append: modeCode = 2
            case .binary, .random: throw unsupported("OPEN FOR \(mode.rawValue)")
            }
            emit(.openFile(
                path: try lowerExpression(path, expecting: .string, context: "OPEN"),
                mode: modeCode,
                number: try lowerExpression(number, expecting: .number, context: "OPEN AS")
            ))
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
            terminate(.end)

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
            terminate(.ret(nil))
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
        case .load, .save, .cd, .pwd, .files:
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
        if lowered.type == type || model.isAssignable(lowered.type, to: type) { return lowered }
        let message: String
        switch type {
        case .number: message = "Cannot assign non-numeric value to \(name)"
        case .string: message = "Cannot assign non-string value to \(name)"
        case .boolean: message = "Boolean \(name) must be FALSE, TRUE, 0, or 1"
        case .composite(let typeName): message = "Cannot assign non-\(model.types[typeName]?.displayName ?? typeName) value to \(name)"
        case .closure: message = "Type Mismatch"
        case .void: message = "Cannot assign to \(name)"
        }
        emit(.failType(message))
        return nil
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
        }
    }

    /// The storage a reference names: its base variable or element, then
    /// each `.field` in turn, with the interpreter's access checks.
    private func lowerPlace(_ reference: VariableReference) throws -> BIRPlace {
        let base = variable(reference.base)
        var place: BIRPlace
        if reference.indexes.isEmpty {
            guard base.rank == nil else { throw CompileError("Type error: \(reference.base.name) is an array", at: location) }
            place = .variable(base)
        } else {
            guard let rank = base.rank else { throw CompileError("\(reference.base.name) is not an array", at: location) }
            guard rank == reference.indexes.count else { throw CompileError("\(reference.base.name) expects \(rank) indexes", at: location) }
            place = .element(base, try reference.indexes.map { try lowerExpression($0, expecting: .number, context: "\(reference.base.name) index") })
        }
        for (position, fieldName) in reference.fields.enumerated() {
            if reference.fieldIndexes.indices.contains(position), !reference.fieldIndexes[position].isEmpty {
                throw unsupported("indexed fields")
            }
            let found = try resolveField(fieldName, on: place.type, baseName: reference.base.name)
            place = .field(place, index: found.index, type: found.field.type)
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
        case .variable(let variable): return .load(variable)
        case .element(let variable, let indexes): return .element(variable, indexes)
        case .field(let base, let index, let type): return .field(load(base), index: index, type: type)
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
            let result = hidden("call", signature.returnType)
            emit(.callMethod(receiver: place, candidates: candidates, arguments: lowered, result: result))
            return .load(result)
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
    private static let fileServiceMembers: [String: (name: String, parameters: [BIRType], returns: BIRType)] = [
        "CWD": ("CWD", [], .string), "CWD$": ("CWD", [], .string),
        "CHDIR": ("CHDIR", [.string], .void),
        "MKDIR": ("MKDIR", [.string], .void),
        "RM": ("RM", [.string], .void),
        "RENAME": ("RENAME", [.string, .string], .void),
        "EXISTS": ("EXISTS", [.string], .boolean),
        "ISDIR": ("ISDIR", [.string], .boolean),
        "READTEXT": ("READTEXT", [.string], .string), "READTEXT$": ("READTEXT", [.string], .string),
        "WRITETEXT": ("WRITETEXT", [.string, .string], .void),
    ]

    private func lowerFileService(_ method: VariableName, _ arguments: [Expression]) throws -> (String, [BIRExpression], BIRType) {
        guard let member = Self.fileServiceMembers[method.normalized] else {
            throw unsupported("File.\(method.name) (Phase 4.9)")
        }
        guard arguments.count == member.parameters.count else {
            throw CompileError("File.\(method.name) expects \(member.parameters.count) argument\(member.parameters.count == 1 ? "" : "s")", at: location)
        }
        let lowered = try zip(arguments, member.parameters).map { argument, type in
            try lowerExpression(argument, expecting: type, context: "File.\(method.name)")
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
    private func lowerExpressionStatement(_ expression: Expression) throws {
        switch expression {
        case .callOrArray(let name, let arguments), .functionCall(let name, let arguments):
            if let userFunction = model.functions[name.normalized] {
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
        let counter = variable(name)
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
        frames.append(.forLoop(variable: counter, end: endSlot, step: stepSlot, body: body, exit: exit))
    }

    /// `(step > 0 AND counter <= end) OR (step <= 0 AND counter >= end)`.
    private func loopContinues(_ counter: BIRVariable, _ end: BIRVariable, _ step: BIRVariable) -> BIRExpression {
        .logical(.or,
            .logical(.and, .compare(.greater, .load(step), .number(0)), .compare(.lessEqual, .load(counter), .load(end))),
            .logical(.and, .compare(.lessEqual, .load(step), .number(0)), .compare(.greaterEqual, .load(counter), .load(end))))
    }

    private func lowerNext(_ name: VariableName?) throws {
        guard case .forLoop(let counter, let end, let step, let body, let exit)? = frames.last else {
            throw CompileError("NEXT without FOR", at: location)
        }
        if let name, name.normalized != counter.name {
            throw CompileError("NEXT \(name.name) does not match FOR \(counter.name)", at: location)
        }
        frames.removeLast()
        emit(.store(counter, .arithmetic(.add, .load(counter), .load(step))))
        terminate(.branch(loopContinues(counter, end, step), then: body, else: exit))
        current = exit
    }

    private func lowerCaseClause(_ clause: CaseClause, subject: BIRVariable) throws -> BIRExpression {
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
        case .forLoop(let variable, _, _, _, _): return "FOR \(variable.name) without NEXT"
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
        if let expecting, lowered.type != expecting, !model.isAssignable(lowered.type, to: expecting) {
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
            let resolved = variable(name)
            guard resolved.rank == nil else { throw CompileError("Type error: \(name.name) is an array", at: location) }
            return .load(resolved)
        case .unaryMinus(let inner):
            return .negate(try lowerExpression(inner, expecting: .number, context: "unary minus"))
        case .binary(let left, let operation, let right):
            return try lowerBinary(left, operation, right)
        case .callOrArray(let name, let arguments), .functionCall(let name, let arguments):
            return try lowerCall(name, arguments)
        case .variableReference(let reference):
            return load(try lowerPlace(reference))
        case .closure(let parameters, let returnType, let captures, let body):
            return try makeClosure(parameters: parameters, returnType: returnType, captures: captures, body: .expression(body))
        case .newObject(let className, let arguments):
            return try lowerNew(className, arguments)
        case .methodCall(let reference, let method, let arguments):
            if isFileService(reference) {
                let (member, lowered, returns) = try lowerFileService(method, arguments)
                guard returns != .void else {
                    throw CompileError("VOID function File.\(method.name) cannot be used in an expression", at: location)
                }
                return .fileService(method: member, arguments: lowered, returns: returns)
            }
            return try lowerMethodCall(reference, method, arguments, wantsValue: true)!
        case .lenFunction(let inner):
            return .intrinsic(.len, [try lowerExpression(inner, expecting: .string, context: "LEN")])
        case .chrFunction(let inner):
            return .intrinsic(.chr, [try lowerExpression(inner, expecting: .number, context: "CHR$")])
        case .null:
            throw unsupported("NULL")
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
        let l = try lowerExpression(left)
        let r = try lowerExpression(right)
        switch operation {
        case .add:
            if l.type == .string && r.type == .string { return .concat(l, r) }
            try requireNumbers(l, r, "+")
            return .arithmetic(.add, l, r)
        case .subtract:
            try requireNumbers(l, r, "-"); return .arithmetic(.subtract, l, r)
        case .multiply:
            try requireNumbers(l, r, "*"); return .arithmetic(.multiply, l, r)
        case .divide:
            try requireNumbers(l, r, "/"); return .arithmetic(.divide, l, r)
        case .equal, .notEqual:
            // The interpreter compares values of different kinds as simply unequal.
            if l.type != r.type { return .number(operation == .equal ? 0 : 1) }
            if l.type.isComposite { throw unsupported("comparing records or objects") }
            return .compare(Self.comparison(for: operation)!, l, r)
        case .less, .lessEqual, .greater, .greaterEqual:
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
        for (argument, expected) in zip(lowered, intrinsic.parameterTypes) where argument.type != expected {
            throw CompileError(
                "Type error: \(name.name) expects \(expected.name), got \(argument.type.name)",
                at: location
            )
        }
        return .intrinsic(intrinsic, lowered)
    }
}
