import BASICSyntax
import Foundation

/// Turns parsed statements into a ``BIRModule``.
///
/// ```text
///   [ParsedLine] ──► VariableTyper (types) ──► block construction ──► BIRModule
///                    ▲                         │
///                    │                         ├─ a line that is a GOTO/GOSUB target
///                    │                         │  starts a block
///                    │                         ├─ IF / FOR / SELECT are matched
///                    │                         │  lexically with a frame stack
///                    │                         └─ anything the compiler cannot
///                    │                            do yet is a CompileError, never
///                    │                            a silent difference
///                    └── suffix, AS type, or what is assigned
/// ```
///
/// This is the whole front end for the program body. `FUNCTION`s, arrays,
/// records, and classes arrive with Phase 4 of BASIC_COMPILER.md.
public struct BIRBuilder {
    /// Creates a builder.
    public init() {}

    /// Builds the module for a program.
    public func build(_ lines: [ParsedLine], moduleName: String) throws -> BIRModule {
        var typer = VariableTyper()
        try typer.run(lines)
        let builder = FunctionBuilder(lines: lines, typer: typer)
        try builder.run()
        var module = BIRModule(name: moduleName)
        // Variables that are only ever read still need a slot; the builder
        // saw every reference.
        let referencedOnly = builder.referencedGlobals.filter { !typer.order.contains($0.name) }
        module.globals = typer.order.map { BIRVariable(name: $0, type: typer.type(of: $0), scope: .global) }
            + referencedOnly.sorted { $0.name < $1.name }
        module.main = builder.function
        return module
    }
}

/// Builds one function's blocks. A class so the many helpers can share
/// mutable state without `inout` threading.
final class FunctionBuilder {
    private let lines: [ParsedLine]
    private let typer: VariableTyper
    private(set) var function = BIRFunction(name: "main")

    /// The block instructions are currently appended to.
    private var current: BIRBlockID = 0
    /// Blocks that begin at a parsed line, because something jumps there.
    private var blockForLine: [Int: BIRBlockID] = [:]
    private var lineIndexByNumber: [Int: Int] = [:]
    private var lineIndexByLabel: [String: Int] = [:]
    private var location = BIRLocation(file: nil, line: 0, statement: 0, lineNumber: nil)
    private var frames: [Frame] = []
    private var hiddenCounter = 0
    /// Every global the function touched, so read-only variables get storage.
    private(set) var referencedGlobals: Set<BIRVariable> = []

    /// One open IF / FOR / SELECT.
    private enum Frame {
        case ifBlock(elseBlock: BIRBlockID?, join: BIRBlockID)
        case forLoop(variable: BIRVariable, end: BIRVariable, step: BIRVariable, body: BIRBlockID, exit: BIRBlockID)
        case select(subject: BIRVariable, next: BIRBlockID, elseBlock: BIRBlockID?, end: BIRBlockID)
    }

    init(lines: [ParsedLine], typer: VariableTyper) {
        self.lines = lines
        self.typer = typer
    }

    func run() throws {
        try indexTargets()
        for (index, line) in lines.enumerated() {
            location = BIRLocation(file: line.fileName, line: line.sourceLineNumber, statement: line.statementNumber, lineNumber: line.number)
            if let block = blockForLine[index] {
                terminate(.jump(block))
                current = block
            }
            try lower(line.statement)
        }
        terminate(.end)
        guard frames.isEmpty else {
            throw CompileError(unterminatedFrameMessage(), at: location)
        }
        function.pruneUnreachableBlocks()
    }

    // MARK: - Targets

    /// Maps line numbers and labels to line indexes, then gives every
    /// referenced target its own block.
    private func indexTargets() throws {
        for (index, line) in lines.enumerated() {
            if let number = line.number { lineIndexByNumber[number] = index }
            if let label = line.statement.label { lineIndexByLabel[label.uppercased()] = index }
        }
        for line in lines {
            location = BIRLocation(file: line.fileName, line: line.sourceLineNumber, statement: line.statementNumber, lineNumber: line.number)
            try collectTargets(in: line.statement)
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

    private func blockForTarget(_ target: BranchTarget) throws -> BIRBlockID {
        let index: Int
        let label: String
        switch target {
        case .line(let number):
            guard let found = lineIndexByNumber[number] else { throw CompileError("Missing line \(number)", at: location) }
            index = found
            label = "L\(number)"
        case .label(let name):
            guard let found = lineIndexByLabel[name.uppercased()] else { throw CompileError("Missing label \(name)", at: location) }
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
    private func terminate(_ terminator: BIRTerminator) {
        if case .unterminated = function.blocks[current].terminator {
            function.blocks[current].terminator = terminator
        }
        current = newBlock("after")
    }

    private var currentIsOpen: Bool {
        if case .unterminated = function.blocks[current].terminator { return true }
        return false
    }

    private func hidden(_ purpose: String, _ type: BIRType) -> BIRVariable {
        hiddenCounter += 1
        let variable = BIRVariable(name: "$\(purpose).\(hiddenCounter)", type: type, scope: .local)
        function.locals.append(variable)
        return variable
    }

    private func variable(_ name: VariableName) -> BIRVariable {
        let variable = BIRVariable(name: name.normalized, type: typer.type(of: name.normalized), scope: .global)
        referencedGlobals.insert(variable)
        return variable
    }

    private func unsupported(_ what: String) -> CompileError {
        CompileError("\(what) is not supported by basicc yet", at: location)
    }

    // MARK: - Statements

    private func lower(_ statement: Statement) throws {
        switch statement {
        case .empty, .remark, .label:
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

        case .assignment(_, let name, _, let value):
            let target = variable(name)
            let stored = try value.map { try lowerExpression($0, expecting: target.type, context: "assign to \(name.name)") }
                ?? defaultValue(for: target.type)
            emit(.store(target, stored))
        case .dim(_, let name, let dimensions, _):
            guard dimensions.isEmpty else { throw unsupported("DIM of an array") }
            let target = variable(name)
            emit(.store(target, defaultValue(for: target.type)))

        case .input(let prompt, .variable(let name)):
            let promptValue = try prompt.map { try lowerExpression($0, expecting: .string, context: "INPUT prompt") }
            emit(.input(prompt: promptValue, into: variable(name)))
        case .input:
            throw unsupported("INPUT into an array element or field")

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

        case .exitFunction:
            emit(.fail("EXIT FUNCTION outside FUNCTION"))
        case .returnValue:
            emit(.fail("RETURN value outside FUNCTION"))

        case .expression(let expression):
            throw unsupported("a bare expression statement (\(describe(expression)))")
        case .printUsing:
            throw unsupported("PRINT USING")
        case .functionDeclaration, .endFunction, .defFunction:
            throw unsupported("FUNCTION (Phase 4.1)")
        case .typeDeclaration, .typeField, .endType:
            throw unsupported("TYPE (Phase 4.2)")
        case .classDeclaration, .classField, .endClass, .interfaceDeclaration, .interfaceFunctionSignature,
             .endInterface, .implementsDeclaration, .inheritsDeclaration, .functionTypeDeclaration:
            throw unsupported("CLASS and INTERFACE (Phase 4.3)")
        case .closureAssignment, .referenceAssignment:
            throw unsupported("closures and references (Phase 4.4)")
        case .data, .read, .restore:
            throw unsupported("DATA/READ/RESTORE (Phase 4.7)")
        case .importDirective:
            throw unsupported("IMPORT (Phase 4.7)")
        case .onErrorGoto, .error, .resumeNext:
            throw unsupported("ON ERROR (Phase 4.6)")
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

    private func defaultValue(for type: BIRType) -> BIRExpression {
        switch type {
        case .number, .void: return .number(0)
        case .string: return .string("")
        case .boolean: return .boolean(false)
        }
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
        guard counter.type == .number else {
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
        if let expecting, lowered.type != expecting {
            throw CompileError(
                "Type error: \(context) expects \(expecting.rawValue), got \(lowered.type.rawValue)",
                at: location
            )
        }
        return lowered
    }

    private func lowerExpression(_ expression: Expression) throws -> BIRExpression {
        switch expression {
        case .number(let value): return .number(value)
        case .string(let value): return .string(value)
        case .boolean(let value): return .boolean(value)
        case .variable(let name): return .load(variable(name))
        case .unaryMinus(let inner):
            return .negate(try lowerExpression(inner, expecting: .number, context: "unary minus"))
        case .binary(let left, let operation, let right):
            return try lowerBinary(left, operation, right)
        case .callOrArray(let name, let arguments), .functionCall(let name, let arguments):
            return try lowerCall(name, arguments)
        case .lenFunction(let inner):
            return .intrinsic(.len, [try lowerExpression(inner, expecting: .string, context: "LEN")])
        case .chrFunction(let inner):
            return .intrinsic(.chr, [try lowerExpression(inner, expecting: .number, context: "CHR$")])
        case .interpolatedString:
            throw unsupported("string interpolation")
        case .null:
            throw unsupported("NULL")
        default:
            throw unsupported(describe(expression))
        }
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

    private func lowerCall(_ name: VariableName, _ arguments: [Expression]) throws -> BIRExpression {
        guard let intrinsic = BIRIntrinsic.lookup(name.normalized, argumentCount: arguments.count) else {
            if BASICKeywords.intrinsicFunctionNames.contains(name.normalized) {
                throw unsupported("the builtin \(name.name)")
            }
            throw unsupported("calling \(name.name) (user functions and arrays arrive in Phase 4)")
        }
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
                "Type error: \(name.name) expects \(expected.rawValue), got \(argument.type.rawValue)",
                at: location
            )
        }
        return .intrinsic(intrinsic, lowered)
    }
}
