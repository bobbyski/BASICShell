import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct Parser {
    private let source: String
    private var tokens: [LexedToken] = []
    private var current = 0
    private var stopsAtElse = false

    init(source: String) throws {
        self.source = source
        var lexer = Lexer(source: source)
        self.tokens = try lexer.tokenize()
    }

    mutating func parseStatement() throws -> Statement {
        var statements: [Statement] = []
        while !isAtEnd {
            statements.append(try parseSingleStatement())
            if !match(.colon) {
                break
            }
        }

        try consumeEnd()
        if statements.isEmpty { return .empty }
        if statements.count == 1 { return statements[0] }
        return .sequence(statements)
    }

    mutating func parseClosureBlockAssignmentHeader() throws -> (
        kind: AssignmentKind,
        variable: VariableName,
        declaredType: BASICType?,
        parameters: [FunctionParameter],
        returnType: BASICType,
        captures: [ClosureCaptureSpec]
    )? {
        let start = current
        let kind: AssignmentKind
        if matchIdentifier("LET") {
            kind = .letValue
        } else if matchIdentifier("LOCAL") {
            kind = .local
        } else if matchIdentifier("GLOBAL") {
            kind = .global
        } else {
            kind = .bare
        }

        guard case .identifier = peek else {
            current = start
            return nil
        }

        let variable = try consumeVariableName("Expected variable name")
        let declaredType = try parseOptionalType(for: variable)
        guard match(.equals) else {
            current = start
            return nil
        }
        guard matchIdentifier("FUNCTION") else {
            current = start
            return nil
        }
        let signature = try parseClosureSignature()
        guard isStatementEnd else {
            current = start
            return nil
        }
        try consumeEnd()
        return (kind, variable, declaredType, signature.parameters, signature.returnType, signature.captures)
    }

    private mutating func parseSingleStatement() throws -> Statement {
        if isAtEnd { return .empty }
        if case .identifier(let name) = peek, peekNext == .colon, !Self.statementKeywords.contains(name.uppercased()) {
            _ = advance()
            _ = advance()
            if isAtEnd {
                return .label(name)
            }
            return .labeled(name, try parseSingleStatement())
        }
        if matchIdentifier("LABEL") {
            let name = try consumeLabelName("Expected label name")
            return .label(name)
        }
        if matchIdentifier("REM") { return .remark }
        if matchIdentifier("PRINT") {
            if matchIdentifier("USING") {
                let using = try parseUsingClause()
                return .printUsing(format: using.format, values: using.values, trailingSeparator: using.trailingSeparator)
            }
            if match(.hash) {
                let number = try parseFileNumber(hashAlreadyConsumed: true)
                _ = match(.comma)
                if matchIdentifier("USING") {
                    let using = try parseUsingClause()
                    return .printFileUsing(number: number, format: using.format, values: using.values, trailingSeparator: using.trailingSeparator)
                }
                return .printFile(number: number, parts: try parsePrintParts())
            }
            return .print(try parsePrintParts())
        }
        if matchIdentifier("LOG") {
            return try parseLogStatement()
        }
        if matchIdentifier("MODULE") {
            return .module(try parseExpression())
        }
        if matchIdentifier("TRON") {
            return .traceOn
        }
        if matchIdentifier("TROFF") {
            return .traceOff
        }
        if matchIdentifier("PRINT#") {
            let number = try parseFileNumber(hashAlreadyConsumed: true)
            _ = match(.comma)
            if matchIdentifier("USING") {
                let using = try parseUsingClause()
                return .printFileUsing(number: number, format: using.format, values: using.values, trailingSeparator: using.trailingSeparator)
            }
            return .printFile(number: number, parts: try parsePrintParts())
        }
        if matchIdentifier("IMPORT") {
            guard case .string(let path) = advance() else { throw syntax("Expected import path") }
            return .importDirective(path)
        }
        if matchIdentifier("DATA") {
            return .data(try parseDataValues())
        }
        if matchIdentifier("READ") {
            return .read(try parseReadTargets())
        }
        if matchIdentifier("RESTORE") {
            return .restore
        }
        if matchIdentifier("FUNCTION") {
            if matchIdentifier("TYPE") {
                return try parseFunctionTypeDeclaration(isAsync: false)
            }
            return try parseFunctionDeclaration(visibility: .public, isOverride: false, isAsync: false)
        }
        if matchIdentifier("ASYNC") {
            guard matchIdentifier("FUNCTION") else { throw syntax("Expected FUNCTION after ASYNC") }
            if matchIdentifier("TYPE") {
                return try parseFunctionTypeDeclaration(isAsync: true)
            }
            return try parseFunctionDeclaration(visibility: .public, isOverride: false, isAsync: true)
        }
        if matchIdentifier("DEF") {
            return try parseDefFunction()
        }
        if matchIdentifier("TYPE") {
            let name = try consumeIdentifier("Expected TYPE name")
            return .typeDeclaration(name: name)
        }
        if matchIdentifier("RECORD") {
            let name = try consumeIdentifier("Expected RECORD name")
            return .typeDeclaration(name: name)
        }
        if matchIdentifier("INTERFACE") {
            let name = try consumeIdentifier("Expected INTERFACE name")
            return .interfaceDeclaration(name: name)
        }
        if matchIdentifier("CLASS") {
            let name = try consumeIdentifier("Expected CLASS name")
            return .classDeclaration(name: name)
        }
        if matchIdentifier("IMPLEMENTS") {
            let name = try consumeIdentifier("Expected interface name after IMPLEMENTS")
            return .implementsDeclaration(name)
        }
        if matchIdentifier("INHERITS") {
            let name = try consumeIdentifier("Expected type name after INHERITS")
            return .inheritsDeclaration(name)
        }
        if isMemberModifier {
            return try parseModifiedMember()
        }
        if matchIdentifier("DIM") {
            return try parseDim(kind: .bare)
        }
        if matchIdentifier("FOR") {
            return try parseForLoop()
        }
        if matchIdentifier("NEXT") {
            return try parseNextLoop()
        }
        if matchIdentifier("SELECT") {
            _ = matchIdentifier("CASE")
            return .selectCase(try parseExpression())
        }
        if matchIdentifier("CASE") {
            if matchIdentifier("ELSE") {
                return .caseElse
            }
            return .caseClause(try parseCaseClauses())
        }
        if matchIdentifier("ELSEIF") {
            let condition = try parseExpression()
            guard matchIdentifier("THEN") else { throw syntax("Expected THEN") }
            return .elseIf(condition)
        }
        if matchIdentifier("ELSE") {
            return .elseBlock
        }
        if matchIdentifier("END") {
            if matchIdentifier("FUNCTION") {
                return .endFunction
            }
            if matchIdentifier("TYPE") {
                return .endType
            }
            if matchIdentifier("RECORD") {
                return .endType
            }
            if matchIdentifier("INTERFACE") {
                return .endInterface
            }
            if matchIdentifier("CLASS") {
                return .endClass
            }
            if matchIdentifier("SELECT") {
                return .endSelect
            }
            if matchIdentifier("IF") {
                return .endIf
            }
            return .end
        }
        if matchIdentifier("EXIT") {
            if matchIdentifier("SELECT") {
                return .exitSelect
            }
            guard matchIdentifier("FUNCTION") else { throw syntax("Expected SELECT or FUNCTION") }
            guard isStatementEnd else { throw syntax("EXIT FUNCTION does not accept a return value") }
            return .exitFunction
        }
        if matchIdentifier("OPTION") {
            return try parseOptionStatement()
        }
        if matchIdentifier("GLOBAL") {
            return try parseAssignment(kind: .global, requiresEquals: false)
        }
        if matchIdentifier("LOCAL") {
            return try parseAssignment(kind: .local, requiresEquals: false)
        }
        if matchIdentifier("SCREEN") {
            let mode = try parseExpression()
            return .screen(mode)
        }
        if matchIdentifier("COLOR") {
            var colors = [try parseExpression()]
            while match(.comma) {
                colors.append(try parseExpression())
            }
            return .color(colors)
        }
        if matchIdentifier("CLS") {
            return .cls
        }
        if matchIdentifier("LOCATE") {
            let row = try parseExpression()
            guard match(.comma) else { throw syntax("Expected , in LOCATE") }
            return .locate(row: row, column: try parseExpression())
        }
        if matchIdentifier("PSET") {
            let point = try parsePoint()
            let color = match(.comma) ? try parseExpression() : nil
            return .pset(point, color)
        }
        if matchIdentifier("PRESET") {
            let point = try parsePoint()
            let color = match(.comma) ? try parseExpression() : nil
            return .preset(point, color)
        }
        if matchIdentifier("CIRCLE") {
            let center = try parsePoint()
            guard match(.comma) else { throw syntax("Expected , after CIRCLE center") }
            let radius = try parseExpression()
            let color = match(.comma) ? try parseExpression() : nil
            let aspect = match(.comma) ? try parseExpression() : nil
            return .circle(center, radius, color, aspect)
        }
        if matchIdentifier("PAINT") {
            let point = try parsePoint()
            guard match(.comma) else { throw syntax("Expected , after PAINT point") }
            let color = try parseExpression()
            let borderColor = match(.comma) ? try parseExpression() : nil
            return .paint(point, color, borderColor)
        }
        if matchIdentifier("DRAW") {
            return .draw(try parseExpression())
        }
        if matchIdentifier("LINE") {
            if matchIdentifier("INPUT") {
                if match(.hash) {
                    let number = try parseFileNumber(hashAlreadyConsumed: true)
                    guard match(.comma) else { throw syntax("Expected , after file number") }
                    return .lineInputFile(number: number, target: try parseFileTarget())
                }
                return try parseLineInput()
            }
            if matchIdentifier("INPUT#") {
                let number = try parseFileNumber(hashAlreadyConsumed: true)
                guard match(.comma) else { throw syntax("Expected , after file number") }
                return .lineInputFile(number: number, target: try parseFileTarget())
            }
            let start = try parsePoint()
            guard match(.minus) else { throw syntax("Expected - in LINE") }
            let end = try parsePoint()
            let color = match(.comma) ? try parseExpression() : nil
            return .line(start, end, color)
        }
        if matchIdentifier("LET") {
            return try parseAssignment(kind: .letValue, requiresEquals: false)
        }
        if matchIdentifier("OPEN") {
            return try parseOpenFile()
        }
        if matchIdentifier("CLOSE") {
            return .closeFile(isStatementEnd ? nil : try parseFileNumber(hashAlreadyConsumed: match(.hash)))
        }
        if matchIdentifier("PUT") {
            let number = try parseFileNumber(hashAlreadyConsumed: match(.hash))
            _ = match(.comma)
            return .putFile(number: number, parts: try parsePrintParts())
        }
        if matchIdentifier("GET") {
            let number = try parseFileNumber(hashAlreadyConsumed: match(.hash))
            guard match(.comma) else { throw syntax("Expected , after file number") }
            return .getFile(number: number, targets: try parseFileTargets())
        }
        if matchIdentifier("RESET") {
            return .resetFile(try parseFileNumber(hashAlreadyConsumed: match(.hash)))
        }
        if matchIdentifier("INPUT#") {
            let number = try parseFileNumber(hashAlreadyConsumed: true)
            guard match(.comma) else { throw syntax("Expected , after file number") }
            return .inputFile(number: number, targets: try parseFileTargets())
        }
        if isKeywordStatement("INPUT") && matchIdentifier("INPUT") {
            if match(.hash) {
                let number = try parseFileNumber(hashAlreadyConsumed: true)
                guard match(.comma) else { throw syntax("Expected , after file number") }
                return .inputFile(number: number, targets: try parseFileTargets())
            }
            let prompt: Expression?
            if case .string = peek {
                prompt = try parseExpression()
                guard match(.comma) || match(.semicolon) else { throw syntax("Expected , after INPUT prompt") }
            } else {
                prompt = nil
            }
            let reference = try parseVariableReference(message: "Expected variable after INPUT")
            return .input(prompt: prompt, target: reference.isSimple ? .variable(reference.base) : .reference(reference))
        }
        if matchIdentifier("LOAD") {
            return .load(try parseExpression())
        }
        if matchIdentifier("SAVE") {
            return .save(isStatementEnd ? nil : try parseExpression())
        }
        if matchIdentifier("CD") {
            return .cd(isStatementEnd ? nil : try parseExpression())
        }
        if matchIdentifier("FILES") {
            return .files
        }
        if matchIdentifier("SYSTEM") {
            return .system(try parseExpression())
        }
        if matchIdentifier("JOIN") {
            return .join(try parseExpression())
        }
        if matchIdentifier("YIELD") {
            return .yield
        }
        if matchIdentifier("RANDOMIZE") {
            return .randomize(isStatementEnd ? nil : try parseExpression())
        }
        if matchIdentifier("ERROR") {
            return .error(try parseExpression())
        }
        if matchIdentifier("ON") {
            return try parseOnStatement()
        }
        if matchIdentifier("GOTO") {
            return try parseGotoStatement()
        }
        if matchIdentifier("GOSUB") {
            let target = try consumeBranchTarget("Expected line number or label after GOSUB")
            return .gosub(target)
        }
        if matchIdentifier("RETURN") {
            if isStatementEnd {
                return .returnFromSubroutine
            }
            return .returnValue(try parseExpression())
        }
        if matchIdentifier("RESUME") {
            guard matchIdentifier("NEXT") else { throw syntax("Expected NEXT after RESUME") }
            return .resumeNext
        }
        if matchIdentifier("PAUSE") {
            return .pause
        }
        if matchIdentifier("IF") {
            let condition = try parseExpression()
            guard matchIdentifier("THEN") else { throw syntax("Expected THEN") }
            if isStatementEnd {
                return .blockIf(condition)
            }
            let thenAction = try parseConditionalAction(stoppingAtElse: true)
            let elseAction = matchIdentifier("ELSE") ? try parseConditionalAction(stoppingAtElse: false) : nil
            return .ifThen(condition, thenAction, elseAction)
        }
        if matchIdentifier("STOP") {
            return .end
        }
        if isClassFieldDeclaration {
            return try parseClassField()
        }
        if isTypeFieldDeclaration {
            return try parseTypeField()
        }
        if case .identifier = peek {
            if hasTopLevelEqualsBeforeStatementEnd() {
                return try parseAssignment(kind: .bare, requiresEquals: true)
            }
            if hasTopLevelDotBeforeStatementEnd() {
                return .expression(try parseExpression())
            }
            return try parseAssignment(kind: .bare, requiresEquals: true)
        }
        if case .hash = peek {
            throw syntax("Unexpected character #")
        }
        throw syntax("Unknown statement")
    }

    private func hasTopLevelDotBeforeStatementEnd() -> Bool {
        var index = current
        var depth = 0
        while index < tokens.count {
            switch tokens[index].token {
            case .eof:
                return false
            case .colon where depth == 0:
                return false
            case .leftParen:
                depth += 1
            case .rightParen:
                depth = max(0, depth - 1)
            case .dot where depth == 0:
                return true
            default:
                break
            }
            index += 1
        }
        return false
    }

    private func isKeywordStatement(_ keyword: String) -> Bool {
        guard case .identifier(let name) = peek, name.uppercased() == keyword else { return false }
        return tokens[safe: current + 1]?.token != .dot
    }

    private func hasTopLevelEqualsBeforeStatementEnd() -> Bool {
        var index = current
        var depth = 0
        while index < tokens.count {
            switch tokens[index].token {
            case .eof:
                return false
            case .colon where depth == 0:
                return false
            case .leftParen:
                depth += 1
            case .rightParen:
                depth = max(0, depth - 1)
            case .equals where depth == 0:
                return true
            default:
                break
            }
            index += 1
        }
        return false
    }

    private mutating func parseDim(kind: AssignmentKind) throws -> Statement {
        let variable = try consumeVariableName("Expected variable name after DIM")
        var dimensions: [Expression?] = []
        if match(.leftParen) {
            if match(.rightParen) {
                dimensions.append(nil)
            } else {
                repeat {
                    if match(.star) {
                        dimensions.append(nil)
                    } else {
                        dimensions.append(try parseExpression())
                    }
                } while match(.comma)
                guard match(.rightParen) else { throw syntax("Expected )") }
            }
        }
        let declaredType = try parseOptionalType(for: variable)
        return .dim(kind, variable, dimensions, declaredType)
    }

    private mutating func parseTypeField() throws -> Statement {
        let name = try consumeIdentifier("Expected field name")
        let arrayDimensions = try parseOptionalArrayDimensions()
        guard matchIdentifier("AS") else { throw syntax("Expected AS") }
        let typeSpec = try parseTypeSpec(allowVoid: false)
        let json = try parseJSONFieldOptions(defaultName: name)
        let metadata = try parseOptionalFieldMetadata()
        let defaultValue = try parseOptionalFieldDefault()
        return .typeField(name: name, type: typeSpec.type, fixedLength: typeSpec.fixedLength, arrayDimensions: arrayDimensions, json: json, metadata: metadata, defaultValue: defaultValue)
    }

    private mutating func parseModifiedMember() throws -> Statement {
        let visibility = parseVisibilityModifier() ?? .public
        let isOverride = matchIdentifier("OVERRIDES")
        _ = matchIdentifier("VIRTUAL")
        let isAsync = matchIdentifier("ASYNC")
        if matchIdentifier("FUNCTION") {
            return try parseFunctionDeclaration(visibility: visibility, isOverride: isOverride, isAsync: isAsync)
        }
        if isAsync {
            throw syntax("Expected FUNCTION after ASYNC")
        }
        return try parseClassField(visibility: visibility)
    }

    private mutating func parseVisibilityModifier() -> BASICMemberVisibility? {
        if matchIdentifier("PUBLIC") { return .public }
        if matchIdentifier("PRIVATE") { return .private }
        if matchIdentifier("PROTECTED") { return .protected }
        return nil
    }

    private mutating func parseClassField(visibility: BASICMemberVisibility? = nil) throws -> Statement {
        let visibility = visibility ?? parseVisibilityModifier() ?? .public
        let name = try consumeIdentifier("Expected class field name")
        let arrayDimensions = try parseOptionalArrayDimensions()
        guard matchIdentifier("AS") else { throw syntax("Expected AS") }
        let typeSpec = try parseTypeSpec(allowVoid: false)
        let json = try parseJSONFieldOptions(defaultName: name)
        let metadata = try parseOptionalFieldMetadata()
        let defaultValue = try parseOptionalFieldDefault()
        return .classField(name: name, type: typeSpec.type, visibility: visibility, arrayDimensions: arrayDimensions, json: json, metadata: metadata, defaultValue: defaultValue)
    }

    private mutating func parseOptionalArrayDimensions() throws -> [Int?] {
        guard match(.leftParen) else { return [] }
        if match(.rightParen) {
            return [nil]
        }
        var dimensions: [Int?] = []
        repeat {
            if match(.star) {
                dimensions.append(nil)
            } else {
                guard case .number(let bound) = advance(), bound.rounded() == bound, bound >= 0 else {
                    throw syntax("Expected array bound")
                }
                dimensions.append(Int(bound))
            }
        } while match(.comma)
        guard match(.rightParen) else { throw syntax("Expected )") }
        return dimensions
    }

    private mutating func parseJSONFieldOptions(defaultName: String) throws -> BASICJSONFieldOptions? {
        guard matchIdentifier("JSON") else { return nil }
        if matchIdentifier("EXCLUDE") {
            return nil
        }
        if matchIdentifier("NAME") {
            guard case .string(let name) = advance() else {
                throw syntax("Expected JSON field name string")
            }
            return BASICJSONFieldOptions(name: name)
        }
        return BASICJSONFieldOptions(name: defaultName)
    }

    private mutating func parseOptionalFieldMetadata() throws -> BASICMetadata {
        guard matchIdentifier("META") else { return [:] }
        guard match(.leftBrace) else { throw syntax("Expected { after META") }
        var metadata: BASICMetadata = [:]
        if !match(.rightBrace) {
            repeat {
                let key: String
                switch advance() {
                case .identifier(let name), .string(let name):
                    key = name
                default:
                    throw syntax("Expected metadata key")
                }
                guard match(.colon) else { throw syntax("Expected : after metadata key") }
                metadata[key] = try parseMetadataLiteral()
            } while match(.comma)
            guard match(.rightBrace) else { throw syntax("Expected } after metadata") }
        }
        return metadata
    }

    private mutating func parseMetadataLiteral() throws -> BASICValue {
        switch advance() {
        case .number(let value):
            return .number(value)
        case .string(let value):
            return .string(BASICString(value))
        case .identifier(let name):
            switch name.uppercased() {
            case "TRUE": return .boolean(true)
            case "FALSE": return .boolean(false)
            case "NULL": return .null
            case "EMPTY": return .empty
            default: throw syntax("Expected literal metadata value")
            }
        default:
            throw syntax("Expected literal metadata value")
        }
    }

    private mutating func parseOptionalFieldDefault() throws -> BASICValue? {
        guard match(.equals) else { return nil }
        switch advance() {
        case .number(let value):
            return .number(value)
        case .string(let value):
            return .string(BASICString(value))
        case .identifier(let name):
            switch name.uppercased() {
            case "TRUE": return .boolean(true)
            case "FALSE": return .boolean(false)
            case "NULL": return .null
            case "EMPTY": return .empty
            default: throw syntax("Expected literal field default")
            }
        default:
            throw syntax("Expected literal field default")
        }
    }

    private mutating func parseForLoop() throws -> Statement {
        let variable = try consumeVariableName("Expected variable name after FOR")
        guard match(.equals) else { throw syntax("Expected =") }
        let start = try parseExpression()
        guard matchIdentifier("TO") else { throw syntax("Expected TO") }
        let end = try parseExpression()
        let step = matchIdentifier("STEP") ? try parseExpression() : nil
        return .forLoop(variable: variable, start: start, end: end, step: step)
    }

    private mutating func parseNextLoop() throws -> Statement {
        var variables: [VariableName] = []
        while !isStatementEnd {
            variables.append(try consumeVariableName("Expected variable name after NEXT"))
            if !match(.comma) {
                break
            }
        }
        return .nextLoop(variables)
    }

    private mutating func parseOpenFile() throws -> Statement {
        let path = try parseExpression()
        guard matchIdentifier("FOR") else { throw syntax("Expected FOR in OPEN") }
        let modeName = try consumeIdentifier("Expected INPUT, OUTPUT, or APPEND")
        guard let mode = BASICLegacyFileMode(rawValue: modeName.uppercased()) else {
            throw syntax("Expected INPUT, OUTPUT, or APPEND")
        }
        guard matchIdentifier("AS") else { throw syntax("Expected AS in OPEN") }
        let hashAlreadyConsumed = match(.hash)
        return .openFile(path: path, mode: mode, number: try parseFileNumber(hashAlreadyConsumed: hashAlreadyConsumed))
    }

    private mutating func parseFileNumber(hashAlreadyConsumed: Bool) throws -> Expression {
        if !hashAlreadyConsumed {
            guard match(.hash) else { throw syntax("Expected file number") }
        }
        return try parseExpression()
    }

    private mutating func parseFileTargets() throws -> [ReadTarget] {
        var targets: [ReadTarget] = []
        repeat {
            targets.append(try parseFileTarget())
        } while match(.comma)
        return targets
    }

    private mutating func parseFileTarget() throws -> ReadTarget {
        let reference = try parseVariableReference(message: "Expected variable after file number")
        return reference.isSimple ? .variable(reference.base) : .reference(reference)
    }

    private mutating func parseFunctionDeclaration(visibility: BASICMemberVisibility, isOverride: Bool, isAsync: Bool) throws -> Statement {
        let name = try consumeVariableName("Expected function name")
        let parameters = try parseFunctionParameterList()

        let returnType: BASICType
        if matchIdentifier("AS") {
            returnType = try parseType(allowVoid: true)
        } else if let suffixType = suffixType(for: name.name) {
            returnType = suffixType
        } else {
            returnType = .void
        }

        if let suffixType = suffixType(for: name.name), suffixType != returnType {
            throw BASICError.contextualType(
                message: "suffix \(name.name.last!) conflicts with AS \(returnType.name)",
                source: source,
                column: name.column
            )
        }

        let explicitInterfaceImplementations = try parseExplicitInterfaceImplementations()
        return .functionDeclaration(
            name: name,
            parameters: parameters,
            returnType: returnType,
            isAsync: isAsync,
            visibility: visibility,
            isOverride: isOverride,
            explicitInterfaceImplementations: explicitInterfaceImplementations
        )
    }

    private mutating func parseFunctionTypeDeclaration(isAsync: Bool) throws -> Statement {
        let name = try consumeIdentifier("Expected function type name")
        let parameters = try parseFunctionParameterList()
        guard matchIdentifier("AS") else { throw syntax("FUNCTION TYPE \(name) requires AS <type>") }
        return .functionTypeDeclaration(
            name: name,
            parameters: parameters,
            returnType: try parseType(allowVoid: true),
            isAsync: isAsync
        )
    }

    private mutating func parseFunctionParameterList() throws -> [FunctionParameter] {
        guard match(.leftParen) else { throw syntax("Expected (") }
        var parameters: [FunctionParameter] = []
        if !match(.rightParen) {
            repeat {
                let parameter = try consumeVariableName("Expected parameter name")
                guard matchIdentifier("AS") else { throw syntax("Parameter \(parameter.name) requires AS <type>") }
                let type = try parseType(allowVoid: false)
                parameters.append(FunctionParameter(variable: parameter, type: type))
            } while match(.comma)
            guard match(.rightParen) else { throw syntax("Expected )") }
        }
        return parameters
    }

    private mutating func parseDefFunction() throws -> Statement {
        let name = try consumeVariableName("Expected DEF function name")
        guard name.normalized.hasPrefix("FN") else {
            throw syntax("DEF function names must start with FN")
        }
        guard match(.leftParen) else { throw syntax("Expected (") }
        let parameter = try consumeVariableName("Expected DEF parameter name")
        guard match(.rightParen) else { throw syntax("Expected )") }
        guard match(.equals) else { throw syntax("Expected =") }
        let returnType = suffixType(for: name.name) ?? .scalar(.double)
        let parameterType = suffixType(for: parameter.name) ?? .scalar(.double)
        return .defFunction(
            name: name,
            parameter: FunctionParameter(variable: parameter, type: parameterType),
            returnType: returnType,
            body: try parseExpression()
        )
    }

    private mutating func parseGotoStatement() throws -> Statement {
        var targets = [try consumeBranchTarget("Expected line number or label after GOTO")]
        while match(.comma) {
            targets.append(try consumeBranchTarget("Expected line number or label after ,"))
        }

        if matchIdentifier("ON") {
            return .computedGoto(targets, try parseExpression())
        }

        guard targets.count == 1 else {
            throw syntax("Expected ON after computed GOTO targets")
        }
        switch targets[0] {
        case .line(let line): return .goto(line)
        case .label(let label): return .gotoLabel(label)
        }
    }

    private mutating func parseOnStatement() throws -> Statement {
        if matchIdentifier("ERROR") {
            guard matchIdentifier("GOTO") else { throw syntax("Expected GOTO after ON ERROR") }
            if case .number(let value) = peek, value == 0 {
                _ = advance()
                return .onErrorGoto(nil)
            }
            return .onErrorGoto(try consumeBranchTarget("Expected line number or label after ON ERROR GOTO"))
        }
        if let eventSelector = try parseEventSelector() {
            return .onEventCall(eventSelector, try consumeVariableName("Expected function name after CALL"))
        }
        if let timerEvent = try parseTimerEventStatement() {
            return timerEvent
        }
        let selector = try parseExpression()
        if matchIdentifier("GOTO") {
            return .computedGoto(try parseBranchTargetList(), selector)
        }
        if matchIdentifier("GOSUB") {
            return .computedGosub(try parseBranchTargetList(), selector)
        }
        throw syntax("Expected GOTO or GOSUB after ON expression")
    }

    private mutating func parseTimerEventStatement() throws -> Statement? {
        let checkpoint = current
        guard case .identifier = peek else { return nil }
        let timer = try consumeVariableName("Expected timer variable after ON")
        let ticks: Expression?
        if match(.leftParen) {
            ticks = try parseExpression()
            guard match(.rightParen) else {
                current = checkpoint
                return nil
            }
        } else {
            ticks = nil
        }
        guard matchIdentifier("GOSUB") || matchIdentifier("CALL") else {
            current = checkpoint
            return nil
        }
        return .onTimerEvent(
            timer: timer,
            ticks: ticks,
            handler: try consumeVariableName("Expected timer handler name")
        )
    }

    private mutating func parseEventSelector() throws -> BASICEventSelector? {
        let checkpoint = current
        guard case .identifier(let eventType) = peek else { return nil }
        _ = advance()
        if matchIdentifier("CALL") {
            return BASICEventSelector(type: eventType)
        }
        guard case .identifier(let subtype) = peek else {
            current = checkpoint
            return nil
        }
        _ = advance()
        guard matchIdentifier("CALL") else {
            current = checkpoint
            return nil
        }
        return BASICEventSelector(type: eventType, subtype: subtype)
    }

    private mutating func parseBranchTargetList() throws -> [BranchTarget] {
        var targets = [try consumeBranchTarget("Expected line number or label")]
        while match(.comma) {
            targets.append(try consumeBranchTarget("Expected line number or label after ,"))
        }
        return targets
    }

    private mutating func parseExplicitInterfaceImplementations() throws -> [BASICExplicitInterfaceImplementation] {
        guard matchIdentifier("IMPLEMENTS") else { return [] }
        var implementations: [BASICExplicitInterfaceImplementation] = []
        repeat {
            let interfaceName = try consumeIdentifier("Expected interface name after IMPLEMENTS")
            guard match(.dot) else { throw syntax("Expected . in interface implementation") }
            let memberName = try consumeIdentifier("Expected interface member name after .")
            implementations.append(
                BASICExplicitInterfaceImplementation(
                    interfaceName: interfaceName,
                    normalizedInterfaceName: interfaceName.uppercased(),
                    memberName: memberName,
                    normalizedMemberName: memberName.uppercased()
                )
            )
        } while match(.comma)
        return implementations
    }

    private mutating func parseConditionalAction(stoppingAtElse: Bool) throws -> ConditionalAction {
        if let target = try consumeInlineBranchTarget() {
            return .branch(target)
        }

        let previousStopsAtElse = stopsAtElse
        stopsAtElse = stoppingAtElse
        defer { stopsAtElse = previousStopsAtElse }
        return .statement(try parseSingleStatement())
    }

    private mutating func parsePrintParts() throws -> [PrintPart] {
        var parts: [PrintPart] = []
        while !isStatementEnd {
            if match(.comma) {
                parts.append(.separator(.comma))
            } else if match(.semicolon) {
                parts.append(.separator(.semicolon))
            } else {
                parts.append(.expression(try parseExpression()))
            }
        }
        return parts
    }

    private mutating func parseLogStatement() throws -> Statement {
        let level: Expression
        if case .identifier(let name) = peek, peekNext == .comma {
            _ = advance()
            level = .string(name)
        } else {
            level = try parseExpression()
        }
        guard match(.comma) else { throw syntax("Expected , after LOG level") }
        return .log(level: level, parts: try parsePrintParts())
    }

    private mutating func parseLineInput() throws -> Statement {
        let prompt: Expression?
        if case .string = peek {
            prompt = try parseExpression()
            _ = match(.semicolon) || match(.comma)
        } else {
            prompt = nil
        }
        let target = try parseFileTarget()
        var exitTarget: ReadTarget?
        var fieldLength: Expression?
        var maxLength: Expression?
        var defaultValue: Expression?
        while !isStatementEnd {
            if matchIdentifier("EXITVAR") {
                guard exitTarget == nil else { throw syntax("Duplicate EXITVAR in LINE INPUT") }
                exitTarget = try parseFileTarget()
            } else if matchIdentifier("LENGTH") {
                guard fieldLength == nil else { throw syntax("Duplicate LENGTH in LINE INPUT") }
                fieldLength = try parseExpression()
            } else if matchIdentifier("MAX") {
                guard maxLength == nil else { throw syntax("Duplicate MAX in LINE INPUT") }
                maxLength = try parseExpression()
            } else if matchIdentifier("DEFAULT") {
                guard defaultValue == nil else { throw syntax("Duplicate DEFAULT in LINE INPUT") }
                defaultValue = try parseExpression()
            } else {
                throw syntax("Expected EXITVAR, LENGTH, MAX, or DEFAULT in LINE INPUT")
            }
        }
        return .lineInput(prompt: prompt, target: target, exitTarget: exitTarget, fieldLength: fieldLength, maxLength: maxLength, defaultValue: defaultValue)
    }

    private mutating func parseUsingClause() throws -> (format: Expression, values: [Expression], trailingSeparator: PrintSeparator?) {
        let format = try parseExpression()
        guard match(.semicolon) || match(.comma) else {
            throw syntax("Expected ; after USING format")
        }

        var values: [Expression] = []
        var trailingSeparator: PrintSeparator?
        while !isStatementEnd {
            if match(.comma) {
                trailingSeparator = .comma
            } else if match(.semicolon) {
                trailingSeparator = .semicolon
            } else {
                values.append(try parseExpression())
                trailingSeparator = nil
            }
        }
        return (format, values, trailingSeparator)
    }

    private mutating func parseDataValues() throws -> [BASICValue] {
        var values: [BASICValue] = []
        repeat {
            if isStatementEnd {
                values.append(.string(BASICString("")))
                break
            }
            values.append(try parseDataValue())
        } while match(.comma)
        return values
    }

    private mutating func parseDataValue() throws -> BASICValue {
        if match(.minus) {
            guard case .number(let value) = advance() else { throw syntax("Expected number after - in DATA") }
            return .number(-value)
        }
        switch advance() {
        case .number(let value):
            return .number(value)
        case .string(let value):
            return .string(BASICString(value))
        case .identifier(let value):
            if value.uppercased() == "TRUE" { return .boolean(true) }
            if value.uppercased() == "FALSE" { return .boolean(false) }
            return .string(BASICString(value))
        default:
            throw syntax("Expected DATA value")
        }
    }

    private mutating func parseReadTargets() throws -> [ReadTarget] {
        var targets: [ReadTarget] = []
        repeat {
            let reference = try parseVariableReference(message: "Expected variable after READ")
            if reference.isSimple {
                targets.append(.variable(reference.base))
            } else {
                targets.append(.reference(reference))
            }
        } while match(.comma)
        return targets
    }

    private mutating func parseCaseClauses() throws -> [CaseClause] {
        var clauses: [CaseClause] = []
        repeat {
            clauses.append(try parseCaseClause())
        } while match(.comma)
        return clauses
    }

    private mutating func parseCaseClause() throws -> CaseClause {
        _ = matchIdentifier("IS")
        if let operation = matchComparisonOperator() {
            return .comparison(operation, try parseExpression())
        }

        let lower = try parseExpression()
        if matchIdentifier("TO") {
            return .range(lower, try parseExpression())
        }
        return .equals(lower)
    }

    private mutating func parseAssignment(kind: AssignmentKind, requiresEquals: Bool) throws -> Statement {
        let reference = try parseVariableReference(message: "Expected variable name")
        let variable = reference.base
        let declaredType = (reference.isSimple || (reference.fields.isEmpty && !reference.declarationDimensions.isEmpty)) ? try parseOptionalType(for: variable) : nil
        let expression: Expression?
        if match(.equals) {
            expression = try parseExpression()
        } else if requiresEquals {
            throw syntax("Expected =")
        } else {
            expression = nil
        }
        if !reference.isSimple {
            if reference.declarationDimensions.contains(where: { $0 == nil }) && expression != nil {
                throw syntax("Dynamic array markers are only valid in declarations")
            }
            if expression == nil, reference.fields.isEmpty {
                return .dim(kind, variable, reference.declarationDimensions, declaredType)
            }
            guard kind == .bare || kind == .letValue else {
                throw syntax("GLOBAL and LOCAL require simple variable names")
            }
            return .referenceAssignment(reference, expression)
        }
        return .assignment(kind, variable, declaredType, expression)
    }

    private mutating func parseOptionStatement() throws -> Statement {
        if matchIdentifier("GLOBAL") {
            guard match(.minus), matchIdentifier("LET") else { throw syntax("Expected GLOBAL-LET") }
            return .optionLetMode(.global)
        }
        if matchIdentifier("LOCAL") {
            guard match(.minus), matchIdentifier("LET") else { throw syntax("Expected LOCAL-LET") }
            return .optionLetMode(.local)
        }
        if matchIdentifier("IBM") {
            guard match(.minus), matchIdentifier("KEYS") else { throw syntax("Expected IBM-KEYS") }
            return .optionKeyMode(.ibm)
        }
        if matchIdentifier("AIBASIC") {
            guard match(.minus), matchIdentifier("KEYS") else { throw syntax("Expected AIBASIC-KEYS") }
            return .optionKeyMode(.aibasic)
        }
        throw syntax("Expected GLOBAL-LET, LOCAL-LET, IBM-KEYS, or AIBASIC-KEYS")
    }

    private mutating func parseLetMode() throws -> LetMode {
        if matchIdentifier("GLOBAL") {
            guard match(.minus), matchIdentifier("LET") else { throw syntax("Expected GLOBAL-LET") }
            return .global
        }
        if matchIdentifier("LOCAL") {
            guard match(.minus), matchIdentifier("LET") else { throw syntax("Expected LOCAL-LET") }
            return .local
        }
        throw syntax("Expected GLOBAL-LET or LOCAL-LET")
    }

    private mutating func parseOptionalType(for variable: VariableName) throws -> BASICType? {
        guard matchIdentifier("AS") else { return nil }
        let type = try parseType(allowVoid: false)
        if let suffixType = suffixType(for: variable.name), suffixType != type {
            throw BASICError.contextualType(
                message: "suffix \(variable.name.last!) conflicts with AS \(type.name)",
                source: source,
                column: variable.column
            )
        }
        return type
    }

    private mutating func parseType(allowVoid: Bool) throws -> BASICType {
        try parseTypeSpec(allowVoid: allowVoid).type
    }

    private mutating func parseTypeSpec(allowVoid: Bool) throws -> BASICTypeSpec {
        let typeToken = tokens[current]
        guard case .identifier(let name) = advance() else {
            throw syntax("Expected type name")
        }
        let type: BASICType
        var fixedLength: Int?
        switch name.uppercased() {
        case "INTEGER": type = .scalar(.integer)
        case "SINGLE": type = .scalar(.double)
        case "DOUBLE": type = .scalar(.double)
        case "STRING": type = .scalar(.string)
        case "BOOLEAN": type = .scalar(.boolean)
        case "VARIANT": type = .scalar(.variant)
        case "DICTIONARY": type = .dictionary
        case "VOID" where allowVoid: type = .void
        case "VOID": throw BASICError.contextualType(message: "VOID is only valid as a function return type", source: source, column: typeToken.column)
        case "RECORD":
            guard case .identifier(let recordName) = advance() else { throw syntax("Expected RECORD type name") }
            type = .record(recordName)
        case "CLASS":
            guard case .identifier(let className) = advance() else { throw syntax("Expected CLASS type name") }
            type = .classType(className)
        case "INTERFACE":
            guard case .identifier(let interfaceName) = advance() else { throw syntax("Expected INTERFACE type name") }
            type = .interfaceType(interfaceName)
        default:
            type = .record(name)
        }
        if case .scalar(.string) = type, match(.star) {
            guard case .number(let length) = advance(), length.rounded() == length, length > 0 else {
                throw syntax("Expected fixed string length")
            }
            fixedLength = Int(length)
        }
        return BASICTypeSpec(type: type, fixedLength: fixedLength)
    }

    private mutating func parseExpression() throws -> Expression {
        try parseOr()
    }

    private mutating func parseOr() throws -> Expression {
        var expression = try parseAnd()
        while matchIdentifier("OR") {
            expression = .binary(expression, .or, try parseAnd())
        }
        return expression
    }

    private mutating func parseAnd() throws -> Expression {
        var expression = try parseComparison()
        while matchIdentifier("AND") {
            expression = .binary(expression, .and, try parseComparison())
        }
        return expression
    }

    private mutating func parseComparison() throws -> Expression {
        var expression = try parseTerm()
        while true {
            if match(.equals) { expression = .binary(expression, .equal, try parseTerm()) }
            else if match(.notEqual) { expression = .binary(expression, .notEqual, try parseTerm()) }
            else if match(.less) { expression = .binary(expression, .less, try parseTerm()) }
            else if match(.lessEqual) { expression = .binary(expression, .lessEqual, try parseTerm()) }
            else if match(.greater) { expression = .binary(expression, .greater, try parseTerm()) }
            else if match(.greaterEqual) { expression = .binary(expression, .greaterEqual, try parseTerm()) }
            else { break }
        }
        return expression
    }

    private mutating func parseTerm() throws -> Expression {
        var expression = try parseFactor()
        while true {
            if match(.plus) { expression = .binary(expression, .add, try parseFactor()) }
            else if match(.minus) { expression = .binary(expression, .subtract, try parseFactor()) }
            else { break }
        }
        return expression
    }

    private mutating func parseFactor() throws -> Expression {
        var expression = try parseUnary()
        while true {
            if match(.star) { expression = .binary(expression, .multiply, try parseUnary()) }
            else if match(.slash) { expression = .binary(expression, .divide, try parseUnary()) }
            else { break }
        }
        return expression
    }

    private mutating func parseUnary() throws -> Expression {
        if match(.minus) {
            return .unaryMinus(try parseUnary())
        }
        if matchIdentifier("AWAIT") {
            return .await(try parseUnary())
        }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> Expression {
        switch advance() {
        case .number(let value): return .number(value)
        case .string(let value): return .string(value)
        case .identifier(let name):
            let uppercased = name.uppercased()
            if uppercased == "TRUE" { return .boolean(true) }
            if uppercased == "FALSE" { return .boolean(false) }
            if uppercased == "NULL" { return .null }
            if uppercased == "FUNCTION" {
                return try parseClosureExpression()
            }
            if uppercased == "NEW" {
                let className = try consumeIdentifier("Expected class name after NEW")
                let arguments = peek == .leftParen ? try parseArgumentList() : []
                return .newObject(className, arguments)
            }
            if (uppercased == "RND" || uppercased == "INKEY$"), peek != .leftParen {
                return .functionCall(VariableName(name: name, column: tokens[max(0, current - 1)].column), [])
            }
            if uppercased == "POINT", peek == .leftParen {
                return .pointFunction(try parsePoint(openParenAlreadyConsumed: false))
            }
            if uppercased == "CHR$", peek == .leftParen {
                return .chrFunction(try parseSingleArgumentFunction())
            }
            if uppercased == "LEN", peek == .leftParen {
                return .lenFunction(try parseSingleArgumentFunction())
            }
            if uppercased == "SYSTEM$", peek == .leftParen {
                return .systemFunction(try parseSingleArgumentFunction())
            }
            let column = tokens[max(0, current - 1)].column
            if peek == .leftParen {
                let arguments = try parseArgumentList()
                var fields: [String] = []
                var fieldIndexes: [[Expression]] = []
                while match(.dot) {
                    let fieldColumn = tokens[current].column
                    let fieldName = try consumeIdentifier("Expected field name after .")
                    if peek == .leftParen {
                        let memberArguments = try parseArgumentList()
                        if peek == .dot {
                            fields.append(fieldName)
                            fieldIndexes.append(memberArguments)
                            continue
                        }
                        return .methodCall(
                            VariableReference(base: VariableName(name: name, column: column), indexes: arguments, fields: fields, fieldIndexes: fieldIndexes),
                            VariableName(name: fieldName, column: fieldColumn),
                            memberArguments
                        )
                    }
                    fields.append(fieldName)
                    fieldIndexes.append([])
                }
                if !fields.isEmpty {
                    return .variableReference(VariableReference(base: VariableName(name: name, column: column), indexes: arguments, fields: fields, fieldIndexes: fieldIndexes))
                }
                return .callOrArray(VariableName(name: name, column: column), arguments)
            }
            var reference = VariableReference(base: VariableName(name: name, column: column))
            while match(.dot) {
                let fieldColumn = tokens[current].column
                let fieldName = try consumeIdentifier("Expected field name after .")
                if peek == .leftParen {
                    let arguments = try parseArgumentList()
                    if peek == .dot {
                        reference.fields.append(fieldName)
                        reference.fieldIndexes.append(arguments)
                        continue
                    }
                    return .methodCall(reference, VariableName(name: fieldName, column: fieldColumn), arguments)
                }
                reference.fields.append(fieldName)
                reference.fieldIndexes.append([])
            }
            if !reference.fields.isEmpty {
                return .variableReference(reference)
            }
            return .variable(reference.base)
        case .leftParen:
            let expression = try parseExpression()
            guard match(.rightParen) else { throw syntax("Expected )") }
            return expression
        default:
            throw syntax("Expected expression")
        }
    }

    private mutating func parseClosureExpression() throws -> Expression {
        let signature = try parseClosureSignature()
        guard match(.equals) else { throw syntax("Expected = after closure signature") }
        return .closure(parameters: signature.parameters, returnType: signature.returnType, captures: signature.captures, body: try parseExpression())
    }

    private mutating func parseClosureSignature() throws -> (
        parameters: [FunctionParameter],
        returnType: BASICType,
        captures: [ClosureCaptureSpec]
    ) {
        guard match(.leftParen) else { throw syntax("Expected ( after FUNCTION") }
        var parameters: [FunctionParameter] = []
        if !match(.rightParen) {
            repeat {
                let parameter = try consumeVariableName("Expected closure parameter name")
                guard matchIdentifier("AS") else { throw syntax("Parameter \(parameter.name) requires AS <type>") }
                let type = try parseType(allowVoid: false)
                parameters.append(FunctionParameter(variable: parameter, type: type))
            } while match(.comma)
            guard match(.rightParen) else { throw syntax("Expected )") }
        }

        let returnType: BASICType
        if matchIdentifier("AS") {
            returnType = try parseType(allowVoid: false)
        } else {
            returnType = .scalar(.variant)
        }
        let captures = try parseClosureCaptures()
        return (parameters, returnType, captures)
    }

    private mutating func parseClosureCaptures() throws -> [ClosureCaptureSpec] {
        guard matchIdentifier("CAPTURES") else { return [] }
        var captures: [ClosureCaptureSpec] = []
        repeat {
            let access = try parseClosureCaptureAccess()
            let variable = try consumeVariableName("Expected capture variable name")
            captures.append(ClosureCaptureSpec(variable: variable, access: access))
        } while match(.comma)
        return captures
    }

    private mutating func parseClosureCaptureAccess() throws -> BASICCapturedReferenceAccess {
        if matchIdentifier("READONLY") {
            return .readOnly
        }
        if matchIdentifier("READ") {
            guard match(.minus), matchIdentifier("ONLY") else { throw syntax("Expected READ-ONLY") }
            return .readOnly
        }
        if matchIdentifier("STRONG") || matchIdentifier("MUTABLE") {
            return .strongMutable
        }
        if matchIdentifier("WEAK") {
            return .weak
        }
        return .readOnly
    }

    private mutating func parsePoint(openParenAlreadyConsumed: Bool = false) throws -> GraphicsPoint {
        if !openParenAlreadyConsumed {
            guard match(.leftParen) else { throw syntax("Expected (") }
        }
        let x = try parseExpression()
        guard match(.comma) else { throw syntax("Expected ,") }
        let y = try parseExpression()
        guard match(.rightParen) else { throw syntax("Expected )") }
        return GraphicsPoint(x: x, y: y)
    }

    private mutating func parseSingleArgumentFunction() throws -> Expression {
        guard match(.leftParen) else { throw syntax("Expected (") }
        let expression = try parseExpression()
        guard match(.rightParen) else { throw syntax("Expected )") }
        return expression
    }

    private mutating func parseArgumentList() throws -> [Expression] {
        guard match(.leftParen) else { throw syntax("Expected (") }
        var arguments: [Expression] = []
        if !match(.rightParen) {
            repeat {
                if match(.hash) {
                    arguments.append(try parseExpression())
                    continue
                }
                arguments.append(try parseExpression())
            } while match(.comma)
            guard match(.rightParen) else { throw syntax("Expected )") }
        }
        return arguments
    }

    private mutating func parseVariableReference(message: String) throws -> VariableReference {
        let base = try consumeVariableName(message)
        var indexes: [Expression] = []
        var declarationDimensions: [Expression?] = []
        var hasEmptyIndexList = false
        if match(.leftParen) {
            if match(.rightParen) {
                hasEmptyIndexList = true
                declarationDimensions = [nil]
            } else {
                repeat {
                    if match(.star) {
                        declarationDimensions.append(nil)
                    } else {
                        let expression = try parseExpression()
                        indexes.append(expression)
                        declarationDimensions.append(expression)
                    }
                } while match(.comma)
                guard match(.rightParen) else { throw syntax("Expected )") }
            }
        }
        var fields: [String] = []
        var fieldIndexes: [[Expression]] = []
        while match(.dot) {
            fields.append(try consumeIdentifier("Expected field name after ."))
            fieldIndexes.append(peek == .leftParen ? try parseArgumentList() : [])
        }
        return VariableReference(base: base, indexes: indexes, declarationDimensions: declarationDimensions, fields: fields, fieldIndexes: fieldIndexes, hasEmptyIndexList: hasEmptyIndexList)
    }

    private mutating func consumeIdentifier(_ message: String) throws -> String {
        guard case .identifier(let name) = advance() else {
            throw syntax(message)
        }
        return name
    }

    private mutating func consumeVariableName(_ message: String) throws -> VariableName {
        let token = tokens[current]
        guard case .identifier(let name) = advance() else {
            throw syntax(message)
        }
        return VariableName(name: name, column: token.column)
    }

    private mutating func consumeBranchTarget(_ message: String) throws -> BranchTarget {
        switch advance() {
        case .number(let value) where value.rounded() == value:
            return .line(Int(value))
        case .identifier(let name):
            return .label(name)
        case .string(let name):
            return .label(name)
        default:
            throw syntax(message)
        }
    }

    private mutating func consumeInlineBranchTarget() throws -> BranchTarget? {
        switch peek {
        case .number(let value) where value.rounded() == value:
            _ = advance()
            return .line(Int(value))
        case .string(let name):
            _ = advance()
            return .label(name)
        case .identifier(let name) where isInlineLabelTarget(name):
            _ = advance()
            return .label(name)
        default:
            return nil
        }
    }

    private func isInlineLabelTarget(_ name: String) -> Bool {
        guard !Self.statementKeywords.contains(name.uppercased()) else { return false }
        return peekNext == .eof || peekNext == .colon || isElse(peekNext)
    }

    private mutating func consumeLabelName(_ message: String) throws -> String {
        switch advance() {
        case .identifier(let name), .string(let name):
            return name
        default:
            throw syntax(message)
        }
    }

    private mutating func consumeEnd() throws {
        guard isAtEnd else {
            throw syntax("Unexpected input after statement")
        }
    }

    private var isAtEnd: Bool { peek == .eof }
    private var isStatementEnd: Bool { peek == .eof || peek == .colon || (stopsAtElse && isElse(peek)) }

    private var isTypeFieldDeclaration: Bool {
        guard case .identifier = peek else { return false }
        let asIndex = fieldAsKeywordIndex(startingAt: current + 1)
        guard asIndex < tokens.count, case .identifier(let next) = tokens[asIndex].token else { return false }
        return next.uppercased() == "AS"
    }

    private var isClassFieldDeclaration: Bool {
        guard case .identifier(let access) = peek else { return false }
        guard ["PUBLIC", "PRIVATE", "PROTECTED"].contains(access.uppercased()) else { return false }
        let nameIndex = current + 1
        guard case .identifier = tokens[nameIndex].token else { return false }
        let asIndex = fieldAsKeywordIndex(startingAt: nameIndex + 1)
        guard asIndex < tokens.count else { return false }
        guard case .identifier(let asKeyword) = tokens[asIndex].token else { return false }
        return asKeyword.uppercased() == "AS"
    }

    private func fieldAsKeywordIndex(startingAt index: Int) -> Int {
        guard index < tokens.count else { return index }
        guard tokens[index].token == .leftParen else { return index }
        var cursor = index + 1
        while cursor < tokens.count, tokens[cursor].token != .rightParen {
            cursor += 1
        }
        return min(cursor + 1, tokens.count)
    }

    private var isMemberModifier: Bool {
        guard case .identifier(let name) = peek else { return false }
        return ["PUBLIC", "PRIVATE", "PROTECTED", "OVERRIDES", "VIRTUAL"].contains(name.uppercased())
    }
    private var peek: Token { tokens[current].token }
    private var peekNext: Token {
        let next = current + 1
        guard next < tokens.count else { return .eof }
        return tokens[next].token
    }

    @discardableResult
    private mutating func advance() -> Token {
        let token = tokens[current].token
        if !isAtEnd { current += 1 }
        return token
    }

    private mutating func match(_ token: Token) -> Bool {
        guard peek == token else { return false }
        _ = advance()
        return true
    }

    private mutating func matchComparisonOperator() -> BinaryOperation? {
        if match(.equals) { return .equal }
        if match(.notEqual) { return .notEqual }
        if match(.lessEqual) { return .lessEqual }
        if match(.less) { return .less }
        if match(.greaterEqual) { return .greaterEqual }
        if match(.greater) { return .greater }
        return nil
    }

    private mutating func matchIdentifier(_ keyword: String) -> Bool {
        guard case .identifier(let name) = peek, name.uppercased() == keyword else { return false }
        _ = advance()
        return true
    }

    private func isElse(_ token: Token) -> Bool {
        if case .identifier(let name) = token, name.uppercased() == "ELSE" {
            return true
        }
        return false
    }

    private func syntax(_ message: String) -> BASICError {
        let column: Int
        if current < tokens.count {
            column = tokens[current].column
        } else {
            column = source.count
        }
        return .contextualSyntax(message: message, source: source, column: column)
    }

    private func suffixType(for name: String) -> BASICType? {
        switch name.last {
        case "$": return .scalar(.string)
        case "%": return .scalar(.integer)
        case "#": return .scalar(.double)
        default: return nil
        }
    }

    private static let statementKeywords: Set<String> = [
        "LABEL", "REM", "PRINT", "PRINT#", "LOG", "MODULE", "TRON", "TROFF", "USING", "USING$", "SCREEN", "COLOR", "CLS", "LOCATE", "PSET", "PRESET", "LINE", "CIRCLE", "PAINT", "DRAW",
        "LET", "GLOBAL", "LOCAL", "OPTION", "INPUT", "INPUT#", "OPEN", "CLOSE", "PUT", "GET", "RESET", "DATA", "READ", "RESTORE", "LOAD", "SAVE", "CD", "FILES", "SYSTEM", "JOIN", "YIELD", "ON", "ERROR", "RESUME", "GOTO", "GOSUB", "RETURN", "IF",
        "IMPORT", "TYPE", "INTERFACE", "CLASS", "IMPLEMENTS", "INHERITS", "PUBLIC", "PRIVATE", "PROTECTED", "OVERRIDES", "VIRTUAL",
        "FUNCTION", "DEF", "VOID", "VARIANT", "NEW", "ME", "FOR", "TO", "STEP", "NEXT", "SELECT", "CASE", "ELSEIF", "ELSE", "EXIT", "END", "STOP", "PAUSE"
    ]
}
