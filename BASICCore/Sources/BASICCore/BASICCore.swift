import Foundation

public enum BASICError: Error, CustomStringConvertible, Equatable {
    case syntax(String)
    case contextualSyntax(message: String, source: String, column: Int)
    case runtime(String)
    case studioOnlyFeature
    case missingLine(Int)
    case missingLabel(String)
    case halted

    public var description: String {
        switch self {
        case .syntax(let message): return "Syntax error: \(message)"
        case .contextualSyntax(let message, let source, let column):
            let marker = String(repeating: " ", count: max(0, column)) + "^"
            return "\(source)\n\(marker)\nSyntax error: \(message)"
        case .runtime(let message): return "Runtime error: \(message)"
        case .studioOnlyFeature: return "Unsupported feature: you must run this program in BASICStudio"
        case .missingLine(let line): return "Missing line \(line)"
        case .missingLabel(let label): return "Missing label \(label)"
        case .halted: return "Program halted"
        }
    }
}

public enum BASICValue: Equatable, CustomStringConvertible {
    case number(Double)
    case string(String)

    public var description: String {
        switch self {
        case .number(let value):
            if value.rounded() == value {
                return String(Int(value))
            }
            return String(value)
        case .string(let value):
            return value
        }
    }

    var truthy: Bool {
        switch self {
        case .number(let value): return value != 0
        case .string(let value): return !value.isEmpty
        }
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

public protocol BASICHost: AnyObject {
    func printLine(_ text: String)
    func readLine(prompt: String) -> String?
}

public protocol BASICFileHost: BASICHost {
    func loadTextFile(path: String) throws -> String
}

public struct BASICScreenMode: Equatable, Sendable {
    public let number: Int
    public let width: Int
    public let height: Int
    public let colorCount: Int

    public init(number: Int, width: Int, height: Int, colorCount: Int) {
        self.number = number
        self.width = width
        self.height = height
        self.colorCount = colorCount
    }
}

public protocol BASICGraphicsHost: BASICHost {
    func setScreenMode(_ mode: BASICScreenMode)
    func setGraphicsColor(_ color: Int)
    func clearGraphics(color: Int?)
    func setPixel(x: Int, y: Int, color: Int)
    func getPixel(x: Int, y: Int) -> Int
    func drawLine(x1: Int, y1: Int, x2: Int, y2: Int, color: Int)
}

public final class BASICProgram {
    private var lines: [ProgramLine] = []

    public init() {}

    public var isEmpty: Bool { lines.isEmpty }

    public func setLine(number: Int, source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            lines.removeAll { $0.number == number }
        } else {
            if let index = lines.firstIndex(where: { $0.number == number }) {
                lines[index].source = trimmed
            } else {
                lines.append(ProgramLine(number: number, source: trimmed))
            }
            lines.sort { ($0.number ?? Int.max) < ($1.number ?? Int.max) }
        }
    }

    public func loadSource(_ source: String) {
        var sourceLines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        if let firstLine = sourceLines.first,
           firstLine.trimmingCharacters(in: .whitespaces).hasPrefix("#!") {
            sourceLines.removeFirst()
        }

        sourceLines = Self.joinContinuationLines(sourceLines)

        lines = sourceLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                if let numbered = Self.splitNumberedLine(line) {
                    return ProgramLine(number: numbered.number, source: numbered.source)
                }
                return ProgramLine(number: nil, source: line)
            }
    }

    public func clear() {
        lines.removeAll()
    }

    public func listing() -> String {
        orderedLines.map { line in
            if let number = line.number {
                return "\(number) \(line.source)"
            }
            return line.source
        }.joined(separator: "\n")
    }

    public var orderedLines: [(number: Int?, source: String)] {
        lines.map { ($0.number, $0.source) }
    }

    private static func splitNumberedLine(_ source: String) -> (number: Int, source: String)? {
        var digits = ""
        var index = source.startIndex
        while index < source.endIndex, source[index].isNumber {
            digits.append(source[index])
            index = source.index(after: index)
        }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let rest = source[index...].trimmingCharacters(in: .whitespaces)
        return (number, rest)
    }

    private static func joinContinuationLines(_ sourceLines: [String]) -> [String] {
        var joinedLines: [String] = []
        var pending: String?

        for sourceLine in sourceLines {
            let line = sourceLine.trimmingCharacters(in: .whitespaces)
            let combined = [pending, line]
                .compactMap { $0 }
                .joined(separator: pending == nil ? "" : " ")

            if let continued = removingTrailingContinuation(from: combined) {
                pending = continued
            } else {
                joinedLines.append(combined)
                pending = nil
            }
        }

        if let pending {
            joinedLines.append(pending)
        }

        return joinedLines
    }

    private static func removingTrailingContinuation(from line: String) -> String? {
        var index = line.endIndex
        while index > line.startIndex {
            let previous = line.index(before: index)
            if line[previous].isWhitespace {
                index = previous
                continue
            }
            guard line[previous] == "\\" else { return nil }
            return String(line[..<previous]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

private struct ProgramLine {
    let number: Int?
    var source: String
}

public final class BASICSession {
    public let program = BASICProgram()
    private let host: BASICHost

    public init(host: BASICHost) {
        self.host = host
    }

    @discardableResult
    public func submit(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        if let numbered = Self.splitNumberedLine(trimmed) {
            program.setLine(number: numbered.number, source: numbered.source)
            return true
        }

        do {
            if let path = try Self.loadPath(from: trimmed) {
                guard let fileHost = host as? BASICFileHost else {
                    throw BASICError.runtime("LOAD is not supported by this host")
                }
                do {
                    program.loadSource(try fileHost.loadTextFile(path: path))
                } catch {
                    throw BASICError.runtime("Could not load \(path): \(error.localizedDescription)")
                }
                return true
            }

            switch trimmed.uppercased() {
            case "RUN":
                try BASICInterpreter(program: program, host: host).run()
            case "LIST":
                let listing = program.listing()
                if !listing.isEmpty { host.printLine(listing) }
            case "NEW":
                program.clear()
            case "CLEAR":
                host.printLine("")
            case "HELP":
                host.printLine("Commands: RUN, LIST, LOAD, NEW, CLEAR, HELP, QUIT")
                host.printLine("Statements: PRINT, LET, INPUT, GOTO, GOSUB, RETURN, IF expr THEN target, LABEL, END, REM")
            case "QUIT", "EXIT":
                return false
            default:
                try BASICInterpreter(program: immediateProgram(for: trimmed), host: host).run()
            }
        } catch let error as BASICError {
            host.printLine(error.description)
        } catch {
            host.printLine("Unexpected error: \(error)")
        }

        return true
    }

    private func immediateProgram(for source: String) -> BASICProgram {
        let program = BASICProgram()
        program.loadSource(source)
        return program
    }

    private static func splitNumberedLine(_ source: String) -> (number: Int, source: String)? {
        var digits = ""
        var index = source.startIndex
        while index < source.endIndex, source[index].isNumber {
            digits.append(source[index])
            index = source.index(after: index)
        }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let rest = source[index...].trimmingCharacters(in: .whitespaces)
        return (number, rest)
    }

    private static func loadPath(from source: String) throws -> String? {
        guard keywordPrefix("LOAD", matches: source) else { return nil }
        let start = source.index(source.startIndex, offsetBy: 4)
        let rest = source[start...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { throw BASICError.syntax("Expected path after LOAD") }

        if rest.hasPrefix("\"") {
            guard rest.hasSuffix("\""), rest.count >= 2 else {
                throw BASICError.syntax("Unterminated LOAD path")
            }
            return String(rest.dropFirst().dropLast())
        }

        return rest
    }

    private static func keywordPrefix(_ keyword: String, matches source: String) -> Bool {
        guard source.count >= keyword.count else { return false }
        let end = source.index(source.startIndex, offsetBy: keyword.count)
        guard source[source.startIndex..<end].uppercased() == keyword else { return false }
        guard end < source.endIndex else { return true }
        return source[end].isWhitespace
    }
}

public final class BASICInterpreter {
    private let program: BASICProgram
    private weak var host: BASICHost?
    private var variables: [String: BASICValue] = [:]
    private var gosubStack: [Int] = []

    public init(program: BASICProgram, host: BASICHost) {
        self.program = program
        self.host = host
    }

    public func run() throws {
        let parsed = try program.orderedLines.map { line in
            var parser = try Parser(source: line.source)
            return try ParsedLine(number: line.number, statement: parser.parseStatement())
        }
        var lineIndexByNumber: [Int: Int] = [:]
        var lineIndexByLabel: [String: Int] = [:]
        for (index, line) in parsed.enumerated() {
            if let number = line.number {
                lineIndexByNumber[number] = index
            }
            if let label = line.statement.label {
                lineIndexByLabel[label.uppercased()] = index
            }
        }

        var pc = 0
        while pc < parsed.count {
            let current = parsed[pc]
            let next = try execute(current.statement, pc: pc)
            switch next {
            case .next:
                pc += 1
            case .goto(let line):
                guard let index = lineIndexByNumber[line] else { throw BASICError.missingLine(line) }
                pc = index
            case .gotoLabel(let label):
                guard let index = lineIndexByLabel[label.uppercased()] else { throw BASICError.missingLabel(label) }
                pc = index
            case .returnTo(let index):
                pc = index
            case .end:
                return
            }
        }
    }

    private func execute(_ statement: Statement, pc: Int) throws -> Flow {
        switch statement {
        case .empty, .remark:
            return .next
        case .label:
            return .next
        case .labeled(_, let statement):
            return try execute(statement, pc: pc)
        case .sequence(let statements):
            for statement in statements {
                let flow = try execute(statement, pc: pc)
                if flow != .next {
                    return flow
                }
            }
            return .next
        case .end:
            return .end
        case .print(let parts):
            host?.printLine(try renderPrint(parts))
            return .next
        case .screen(let expression):
            let modeNumber = try integer(expression)
            guard let graphicsHost = host as? BASICGraphicsHost else {
                throw BASICError.studioOnlyFeature
            }
            graphicsHost.setScreenMode(screenMode(for: modeNumber))
            return .next
        case .color(let expression):
            let color = try integer(expression)
            guard let graphicsHost = host as? BASICGraphicsHost else {
                throw BASICError.studioOnlyFeature
            }
            graphicsHost.setGraphicsColor(color)
            return .next
        case .cls:
            host?.printLine("\u{001B}[2J\u{001B}[H")
            (host as? BASICGraphicsHost)?.clearGraphics(color: nil)
            return .next
        case .pset(let point, let color):
            guard let graphicsHost = host as? BASICGraphicsHost else {
                throw BASICError.studioOnlyFeature
            }
            let resolved = try resolve(point: point)
            let resolvedColor = try color.map(integer) ?? 1
            graphicsHost.setPixel(x: resolved.x, y: resolved.y, color: resolvedColor)
            return .next
        case .preset(let point, let color):
            guard let graphicsHost = host as? BASICGraphicsHost else {
                throw BASICError.studioOnlyFeature
            }
            let resolved = try resolve(point: point)
            let resolvedColor = try color.map(integer) ?? 0
            graphicsHost.setPixel(x: resolved.x, y: resolved.y, color: resolvedColor)
            return .next
        case .line(let start, let end, let color):
            guard let graphicsHost = host as? BASICGraphicsHost else {
                throw BASICError.studioOnlyFeature
            }
            let resolvedStart = try resolve(point: start)
            let resolvedEnd = try resolve(point: end)
            let resolvedColor = try color.map(integer) ?? 1
            graphicsHost.drawLine(
                x1: resolvedStart.x,
                y1: resolvedStart.y,
                x2: resolvedEnd.x,
                y2: resolvedEnd.y,
                color: resolvedColor
            )
            return .next
        case .letValue(let name, let expression):
            let value = try evaluate(expression)
            try assign(value, to: name)
            return .next
        case .input(let name):
            let raw = host?.readLine(prompt: "\(name)? ") ?? ""
            let value: BASICValue
            if name.hasSuffix("$") {
                value = .string(raw)
            } else if let number = Double(raw.trimmingCharacters(in: .whitespaces)) {
                value = .number(number)
            } else {
                throw BASICError.runtime("Expected numeric input for \(name)")
            }
            variables[name.uppercased()] = value
            return .next
        case .goto(let line):
            return .goto(line)
        case .gotoLabel(let label):
            return .gotoLabel(label)
        case .gosub(let target):
            gosubStack.append(pc + 1)
            return target.flow
        case .returnFromSubroutine:
            guard let index = gosubStack.popLast() else {
                throw BASICError.runtime("RETURN without GOSUB")
            }
            return .returnTo(index)
        case .ifThen(let condition, let target):
            return try evaluate(condition).truthy ? target.flow : .next
        }
    }

    private func assign(_ value: BASICValue, to name: String) throws {
        if name.hasSuffix("$"), value.string == nil {
            throw BASICError.runtime("Cannot assign number to string variable \(name)")
        }
        if !name.hasSuffix("$"), value.number == nil {
            throw BASICError.runtime("Cannot assign string to numeric variable \(name)")
        }
        variables[name.uppercased()] = value
    }

    private func renderPrint(_ parts: [PrintPart]) throws -> String {
        var output = ""
        var column = 0
        let tabWidth = 14

        for part in parts {
            switch part {
            case .expression(let expression):
                let text = try evaluate(expression).description
                output += text
                column += text.count
            case .separator(.comma):
                let spaces = tabWidth - (column % tabWidth)
                output += String(repeating: " ", count: spaces)
                column += spaces
            case .separator(.semicolon):
                break
            }
        }

        return output
    }

    private func evaluate(_ expression: Expression) throws -> BASICValue {
        switch expression {
        case .number(let value):
            return .number(value)
        case .string(let value):
            return .string(value)
        case .variable(let name):
            return variables[name.uppercased()] ?? (name.hasSuffix("$") ? .string("") : .number(0))
        case .unaryMinus(let expression):
            guard let value = try evaluate(expression).number else {
                throw BASICError.runtime("Unary minus requires a number")
            }
            return .number(-value)
        case .binary(let left, let operation, let right):
            return try evaluateBinary(left, operation, right)
        case .pointFunction(let point):
            guard let graphicsHost = host as? BASICGraphicsHost else {
                throw BASICError.studioOnlyFeature
            }
            let resolved = try resolve(point: point)
            return .number(Double(graphicsHost.getPixel(x: resolved.x, y: resolved.y)))
        }
    }

    private func evaluateBinary(_ leftExpression: Expression, _ operation: BinaryOperation, _ rightExpression: Expression) throws -> BASICValue {
        let left = try evaluate(leftExpression)
        let right = try evaluate(rightExpression)

        switch operation {
        case .add:
            if let leftString = left.string, let rightString = right.string {
                return .string(leftString + rightString)
            }
            return .number(try numeric(left) + numeric(right))
        case .subtract:
            return .number(try numeric(left) - numeric(right))
        case .multiply:
            return .number(try numeric(left) * numeric(right))
        case .divide:
            let divisor = try numeric(right)
            guard divisor != 0 else { throw BASICError.runtime("Division by zero") }
            return .number(try numeric(left) / divisor)
        case .equal:
            return .number(left == right ? 1 : 0)
        case .notEqual:
            return .number(left != right ? 1 : 0)
        case .less:
            return .number(try numeric(left) < numeric(right) ? 1 : 0)
        case .lessEqual:
            return .number(try numeric(left) <= numeric(right) ? 1 : 0)
        case .greater:
            return .number(try numeric(left) > numeric(right) ? 1 : 0)
        case .greaterEqual:
            return .number(try numeric(left) >= numeric(right) ? 1 : 0)
        case .and:
            return .number(left.truthy && right.truthy ? 1 : 0)
        case .or:
            return .number(left.truthy || right.truthy ? 1 : 0)
        }
    }

    private func numeric(_ value: BASICValue) throws -> Double {
        guard let number = value.number else {
            throw BASICError.runtime("Expected a number")
        }
        return number
    }

    private func integer(_ expression: Expression) throws -> Int {
        Int(try numeric(try evaluate(expression)).rounded())
    }

    private func resolve(point: GraphicsPoint) throws -> (x: Int, y: Int) {
        (try integer(point.x), try integer(point.y))
    }

    private func screenMode(for number: Int) -> BASICScreenMode {
        switch number {
        case 0:
            return BASICScreenMode(number: 0, width: 0, height: 0, colorCount: 0)
        case 1:
            return BASICScreenMode(number: 1, width: 320, height: 200, colorCount: 4)
        case 2:
            return BASICScreenMode(number: 2, width: 640, height: 200, colorCount: 2)
        case 3:
            return BASICScreenMode(number: 3, width: 256, height: 192, colorCount: 4)
        default:
            return BASICScreenMode(number: number, width: 320, height: 200, colorCount: 16)
        }
    }
}

private struct ParsedLine {
    let number: Int?
    let statement: Statement
}

private enum Flow: Equatable {
    case next
    case goto(Int)
    case gotoLabel(String)
    case returnTo(Int)
    case end
}

private indirect enum Statement: Equatable {
    case empty
    case remark
    case label(String)
    case labeled(String, Statement)
    case sequence([Statement])
    case print([PrintPart])
    case screen(Expression)
    case color(Expression)
    case cls
    case pset(GraphicsPoint, Expression?)
    case preset(GraphicsPoint, Expression?)
    case line(GraphicsPoint, GraphicsPoint, Expression?)
    case letValue(String, Expression)
    case input(String)
    case goto(Int)
    case gotoLabel(String)
    case gosub(BranchTarget)
    case returnFromSubroutine
    case ifThen(Expression, BranchTarget)
    case end

    var label: String? {
        if case .label(let name) = self { return name }
        if case .labeled(let name, _) = self { return name }
        return nil
    }
}

private enum PrintPart: Equatable {
    case expression(Expression)
    case separator(PrintSeparator)
}

private enum PrintSeparator: Equatable {
    case comma
    case semicolon
}

private enum BranchTarget: Equatable {
    case line(Int)
    case label(String)

    var flow: Flow {
        switch self {
        case .line(let line): return .goto(line)
        case .label(let label): return .gotoLabel(label)
        }
    }
}

private indirect enum Expression: Equatable {
    case number(Double)
    case string(String)
    case variable(String)
    case unaryMinus(Expression)
    case binary(Expression, BinaryOperation, Expression)
    case pointFunction(GraphicsPoint)
}

private struct GraphicsPoint: Equatable {
    let x: Expression
    let y: Expression
}

private enum BinaryOperation: Equatable {
    case add, subtract, multiply, divide
    case equal, notEqual, less, lessEqual, greater, greaterEqual
    case and, or
}

private enum Token: Equatable {
    case number(Double)
    case string(String)
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
    case leftParen
    case rightParen
    case eof
}

private struct LexedToken: Equatable {
    let token: Token
    let column: Int
}

private struct Lexer {
    private let source: String
    private var index: String.Index
    private var atStatementStart = true

    init(source: String) {
        self.source = source
        self.index = source.startIndex
    }

    mutating func tokenize() throws -> [LexedToken] {
        var tokens: [LexedToken] = []
        while let token = try nextToken() {
            tokens.append(token)
            if token.token == .eof { break }
        }
        return tokens
    }

    private mutating func nextToken() throws -> LexedToken? {
        skipWhitespace()
        let column = self.column
        guard index < source.endIndex else { return LexedToken(token: .eof, column: column) }
        let character = source[index]

        if startsComment(character) {
            index = source.endIndex
            return emit(.eof, column: column)
        }
        if character.isNumber || character == "." {
            return try scanNumber()
        }
        if character == "\"" {
            return try scanString()
        }
        if character.isLetter {
            return scanIdentifier()
        }

        advance()
        let token: Token
        switch character {
        case ",": token = .comma
        case ";": token = .semicolon
        case ":": token = .colon
        case "=": token = .equals
        case "+": token = .plus
        case "-": token = .minus
        case "*": token = .star
        case "/": token = .slash
        case "(": token = .leftParen
        case ")": token = .rightParen
        case "<":
            if match("=") { token = .lessEqual }
            else if match(">") { token = .notEqual }
            else { token = .less }
        case ">":
            if match("=") { token = .greaterEqual }
            else { token = .greater }
        default:
            throw BASICError.contextualSyntax(message: "Unexpected character \(character)", source: source, column: column)
        }
        return emit(token, column: column)
    }

    private mutating func scanNumber() throws -> LexedToken {
        let start = index
        let column = self.column
        var seenDot = false
        while index < source.endIndex {
            let character = source[index]
            if character == "." {
                guard !seenDot else { break }
                seenDot = true
            } else if !character.isNumber {
                break
            }
            advance()
        }
        let text = String(source[start..<index])
        guard let value = Double(text) else {
            throw BASICError.contextualSyntax(message: "Invalid number \(text)", source: source, column: column)
        }
        return emit(.number(value), column: column)
    }

    private mutating func scanString() throws -> LexedToken {
        let column = self.column
        advance()
        let start = index
        while index < source.endIndex, source[index] != "\"" {
            advance()
        }
        guard index < source.endIndex else {
            throw BASICError.contextualSyntax(message: "Unterminated string", source: source, column: column)
        }
        let value = String(source[start..<index])
        advance()
        return emit(.string(value), column: column)
    }

    private mutating func scanIdentifier() -> LexedToken {
        let start = index
        let column = self.column
        while index < source.endIndex, source[index].isLetter || source[index].isNumber || source[index] == "$" {
            advance()
        }
        let name = String(source[start..<index])
        if atStatementStart, name.uppercased() == "REM" {
            index = source.endIndex
        }
        return emit(.identifier(name), column: column)
    }

    private mutating func skipWhitespace() {
        while index < source.endIndex, source[index].isWhitespace {
            advance()
        }
    }

    private mutating func match(_ expected: Character) -> Bool {
        guard index < source.endIndex, source[index] == expected else { return false }
        advance()
        return true
    }

    private mutating func advance() {
        index = source.index(after: index)
    }

    private mutating func emit(_ token: Token, column: Int) -> LexedToken {
        if token == .colon {
            atStatementStart = true
        } else if token != .eof {
            atStatementStart = false
        }
        return LexedToken(token: token, column: column)
    }

    private func startsComment(_ character: Character) -> Bool {
        if character == "'" {
            return true
        }
        if character == "#" {
            return isAtPhysicalLineStart
        }
        if character == "/" {
            let next = source.index(after: index)
            return next < source.endIndex && source[next] == "/"
        }
        return false
    }

    private var isAtPhysicalLineStart: Bool {
        source[..<index].allSatisfy(\.isWhitespace)
    }

    private var column: Int {
        source.distance(from: source.startIndex, to: index)
    }
}

private struct Parser {
    private let source: String
    private var tokens: [LexedToken] = []
    private var current = 0

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
            return .print(try parsePrintParts())
        }
        if matchIdentifier("SCREEN") {
            let mode = try parseExpression()
            return .screen(mode)
        }
        if matchIdentifier("COLOR") {
            let color = try parseExpression()
            return .color(color)
        }
        if matchIdentifier("CLS") {
            return .cls
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
        if matchIdentifier("LINE") {
            let start = try parsePoint()
            guard match(.minus) else { throw syntax("Expected - in LINE") }
            let end = try parsePoint()
            let color = match(.comma) ? try parseExpression() : nil
            return .line(start, end, color)
        }
        if matchIdentifier("LET") {
            return try parseAssignment()
        }
        if matchIdentifier("INPUT") {
            let name = try consumeIdentifier("Expected variable name after INPUT")
            return .input(name)
        }
        if matchIdentifier("GOTO") {
            let target = try consumeBranchTarget("Expected line number or label after GOTO")
            switch target {
            case .line(let line): return .goto(line)
            case .label(let label): return .gotoLabel(label)
            }
        }
        if matchIdentifier("GOSUB") {
            let target = try consumeBranchTarget("Expected line number or label after GOSUB")
            return .gosub(target)
        }
        if matchIdentifier("RETURN") {
            return .returnFromSubroutine
        }
        if matchIdentifier("IF") {
            let condition = try parseExpression()
            guard matchIdentifier("THEN") else { throw syntax("Expected THEN") }
            let target = try consumeBranchTarget("Expected line number or label after THEN")
            return .ifThen(condition, target)
        }
        if matchIdentifier("END") || matchIdentifier("STOP") {
            return .end
        }
        if case .identifier = peek {
            return try parseAssignment()
        }
        throw syntax("Unknown statement")
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

    private mutating func parseAssignment() throws -> Statement {
        let name = try consumeIdentifier("Expected variable name")
        guard match(.equals) else { throw syntax("Expected =") }
        let expression = try parseExpression()
        return .letValue(name, expression)
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
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> Expression {
        switch advance() {
        case .number(let value): return .number(value)
        case .string(let value): return .string(value)
        case .identifier(let name):
            if name.uppercased() == "POINT", peek == .leftParen {
                return .pointFunction(try parsePoint(openParenAlreadyConsumed: false))
            }
            return .variable(name)
        case .leftParen:
            let expression = try parseExpression()
            guard match(.rightParen) else { throw syntax("Expected )") }
            return expression
        default:
            throw syntax("Expected expression")
        }
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

    private mutating func consumeIdentifier(_ message: String) throws -> String {
        guard case .identifier(let name) = advance() else {
            throw syntax(message)
        }
        return name
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
    private var isStatementEnd: Bool { peek == .eof || peek == .colon }
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

    private mutating func matchIdentifier(_ keyword: String) -> Bool {
        guard case .identifier(let name) = peek, name.uppercased() == keyword else { return false }
        _ = advance()
        return true
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

    private static let statementKeywords: Set<String> = [
        "LABEL", "REM", "PRINT", "SCREEN", "COLOR", "CLS", "PSET", "PRESET", "LINE",
        "LET", "INPUT", "GOTO", "GOSUB", "RETURN", "IF", "END", "STOP"
    ]
}
