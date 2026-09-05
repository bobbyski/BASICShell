import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct BASICPipelineStage: Equatable {
    public let command: Expression
    public let arguments: [Expression]

    /// Creates a value from its parts.
    public init(command: Expression, arguments: [Expression]) {
        self.command = command
        self.arguments = arguments
    }
}

public struct BASICLegacyFieldSpec: Equatable {
    public let width: Expression
    public let variable: VariableName

    /// Creates a value from its parts.
    public init(width: Expression, variable: VariableName) {
        self.width = width
        self.variable = variable
    }
}

public indirect enum Statement: Equatable {
    case empty
    case remark
    case label(String)
    case labeled(String, Statement)
    case sequence([Statement])
    case importDirective(String)
    case typeDeclaration(name: String)
    case typeField(name: String, type: BASICType, fixedLength: Int?, arrayDimensions: [Int?], json: BASICJSONFieldOptions?, metadata: BASICLiteralMetadata, defaultValue: BASICLiteral?)
    case endType
    case interfaceDeclaration(name: String)
    case interfaceFunctionSignature(name: VariableName, parameters: [FunctionParameter], returnType: BASICType)
    case endInterface
    case functionTypeDeclaration(name: String, parameters: [FunctionParameter], returnType: BASICType, isAsync: Bool)
    case classDeclaration(name: String)
    case implementsDeclaration(String)
    case inheritsDeclaration(String)
    case classField(name: String, type: BASICType, visibility: BASICMemberVisibility, arrayDimensions: [Int?], json: BASICJSONFieldOptions?, metadata: BASICLiteralMetadata, defaultValue: BASICLiteral?)
    case endClass
    case functionDeclaration(
        name: VariableName,
        parameters: [FunctionParameter],
        returnType: BASICType,
        isAsync: Bool,
        visibility: BASICMemberVisibility,
        isOverride: Bool,
        explicitInterfaceImplementations: [BASICExplicitInterfaceImplementation]
    )
    case defFunction(name: VariableName, parameter: FunctionParameter, returnType: BASICType, body: Expression)
    case endFunction
    case data([BASICLiteral])
    case read([ReadTarget])
    case restore
    case print([PrintPart])
    case printUsing(format: Expression, values: [Expression], trailingSeparator: PrintSeparator?)
    case log(level: Expression, parts: [PrintPart])
    case module(Expression)
    case traceOn
    case traceOff
    case screen(Expression)
    case color([Expression])
    case cls
    case locate(row: Expression, column: Expression)
    case pset(GraphicsPoint, Expression?)
    case preset(GraphicsPoint, Expression?)
    case line(GraphicsPoint, GraphicsPoint, Expression?)
    case circle(GraphicsPoint, Expression, Expression?, Expression?)
    case paint(GraphicsPoint, Expression, Expression?)
    case draw(Expression)
    case assignment(AssignmentKind, VariableName, BASICType?, Expression?)
    case closureAssignment(AssignmentKind, VariableName, BASICType?, [FunctionParameter], BASICType, [ClosureCaptureSpec], [ClosureBodyLine])
    case referenceAssignment(VariableReference, Expression?)
    case expression(Expression)
    case dim(AssignmentKind, VariableName, [Expression?], BASICType?)
    case optionLetMode(LetMode)
    case optionKeyMode(BASICKeyMode)
    case optionEventInput(type: String, mode: BASICEventInputMode)
    case optionShellMode(Bool)
    case optionStringSubstitution(Bool)
    case input(prompt: Expression?, target: ReadTarget)
    case lineInput(prompt: Expression?, target: ReadTarget, exitTarget: ReadTarget?, fieldLength: Expression?, maxLength: Expression?, defaultValue: Expression?)
    case openFile(path: Expression, mode: BASICLegacyFileMode, number: Expression, recordLength: Expression?)
    case closeFile(Expression?)
    case putFile(number: Expression, parts: [PrintPart])
    case getFile(number: Expression, targets: [ReadTarget])
    case getRecordFile(number: Expression, record: Expression?)
    case writeFile(number: Expression, values: [Expression])
    case fieldFile(number: Expression, fields: [BASICLegacyFieldSpec])
    case setFieldString(target: ReadTarget, value: Expression, rightAligned: Bool)
    case seekFile(number: Expression, position: Expression)
    case resetFile(Expression)
    case printFile(number: Expression, parts: [PrintPart])
    case printFileUsing(number: Expression, format: Expression, values: [Expression], trailingSeparator: PrintSeparator?)
    case inputFile(number: Expression, targets: [ReadTarget])
    case lineInputFile(number: Expression, target: ReadTarget)
    case load(Expression)
    case save(Expression?)
    case cd(Expression?)
    case pwd
    case files
    case setEnvironment(name: Expression, value: Expression)
    case unsetEnvironment(Expression)
    case exportEnvironment(name: String, value: Expression?)
    case which(Expression)
    case typeCommand(Expression)
    case pushDirectory(Expression?)
    case popDirectory
    case directoryStack
    case system(Expression)
    case exec(command: Expression, arguments: [Expression], stdout: ReadTarget?, stderr: ReadTarget?, tty: Bool, timeout: Expression?)
    case pipe(input: Expression?, stages: [BASICPipelineStage])
    case background(Expression)
    case join(Expression)
    case cancelTask(Expression)
    case yield
    case randomize(Expression?)
    case goto(Int)
    case gotoLabel(String)
    case computedGoto([BranchTarget], Expression)
    case computedGosub([BranchTarget], Expression)
    case onErrorGoto(BranchTarget?)
    case onEventCall(BASICEventSelector, VariableName)
    case onTimerEvent(timer: VariableName, ticks: Expression?, handler: VariableName)
    case error(Expression)
    case resumeNext
    case gosub(BranchTarget)
    case returnFromSubroutine
    case returnValue(Expression)
    case pause
    case exitFunction
    case ifThen(Expression, ConditionalAction, ConditionalAction?)
    case blockIf(Expression)
    case elseIf(Expression)
    case elseBlock
    case endIf
    case forLoop(variable: VariableName, start: Expression, end: Expression, step: Expression?)
    case nextLoop([VariableName])
    /// `WHILE condition` — a loop whose count is not known when it starts.
    case whileLoop(Expression)
    /// `WEND` — the end of the innermost `WHILE`.
    case wend
    case selectCase(Expression)
    case caseClause([CaseClause])
    case caseElse
    case endSelect
    case exitSelect
    case end

    public var label: String? {
        if case .label(let name) = self { return name }
        if case .labeled(let name, _) = self { return name }
        return nil
    }
}

public struct ClosureBodyLine: Equatable {
    public let fileName: String?
    public let sourceLineNumber: Int
    public let statement: Statement

    /// Creates a value from its parts.
    public init(fileName: String?, sourceLineNumber: Int, statement: Statement) {
        self.fileName = fileName
        self.sourceLineNumber = sourceLineNumber
        self.statement = statement
    }
}

public enum CaseClause: Equatable {
    case equals(Expression)
    case range(Expression, Expression)
    case comparison(BinaryOperation, Expression)
}

public enum PrintPart: Equatable {
    case expression(Expression)
    case separator(PrintSeparator)

    public var suppressesNewline: Bool {
        if case .separator = self { return true }
        return false
    }
}

public enum PrintSeparator: Equatable {
    case comma
    case semicolon
}

public struct PrintOutput: Equatable {
    public let text: String
    public let terminator: String
    public let endColumn: Int

    /// Creates a value from its parts.
    public init(text: String, terminator: String, endColumn: Int) {
        self.text = text
        self.terminator = terminator
        self.endColumn = endColumn
    }
}

public enum BranchTarget: Equatable {
    case line(Int)
    case label(String)

    public var flow: Flow {
        switch self {
        case .line(let line): return .goto(line)
        case .label(let label): return .gotoLabel(label)
        }
    }
}

public indirect enum ConditionalAction: Equatable {
    case branch(BranchTarget)
    case statement(Statement)
}

public indirect enum Expression: Equatable {
    case number(Double)
    case string(String)
    case interpolatedString(String)
    case boolean(Bool)
    case null
    case closure(parameters: [FunctionParameter], returnType: BASICType, captures: [ClosureCaptureSpec], body: Expression)
    case variable(VariableName)
    case variableReference(VariableReference)
    case callOrArray(VariableName, [Expression])
    case methodCall(VariableReference, VariableName, [Expression])
    case newObject(String, [Expression])
    case unaryMinus(Expression)
    /// `NOT expression` — the truthiness of the expression, inverted.
    case logicalNot(Expression)
    case binary(Expression, BinaryOperation, Expression)
    case await(Expression)
    case functionCall(VariableName, [Expression])
    case pointFunction(GraphicsPoint)
    case chrFunction(Expression)
    case lenFunction(Expression)
    case environmentFunction(Expression)
    case pwdFunction
    case systemFunction(Expression)
}

public struct GraphicsPoint: Equatable {
    public let x: Expression
    public let y: Expression

    /// Creates a value from its parts.
    public init(x: Expression, y: Expression) {
        self.x = x
        self.y = y
    }
}

public enum BinaryOperation: Equatable {
    case add, subtract, multiply, divide
    case equal, notEqual, less, lessEqual, greater, greaterEqual
    /// The logical set, loosest last: `AND`, `OR`, `XOR`, `EQV`, `IMP`.
    /// `EQV` is true when both sides agree; `IMP` is false only when the
    /// left is true and the right is not.
    case and, or, xor, eqv, imp
}

public enum Token: Equatable {
    case number(Double)
    case string(String)
    case interpolatedString(String)
    case identifier(String)
    case comma
    case semicolon
    case colon
    case equals
    case less
    case greater
    case lessEqual
    case greaterEqual
    case notEqual
    case plus
    case minus
    case star
    case slash
    case hash
    case dot
    case leftParen
    case rightParen
    case leftBrace
    case rightBrace
    case eof
}

public struct LexedToken: Equatable {
    public let token: Token
    public let column: Int

    /// Creates a value from its parts.
    public init(token: Token, column: Int) {
        self.token = token
        self.column = column
    }
}
