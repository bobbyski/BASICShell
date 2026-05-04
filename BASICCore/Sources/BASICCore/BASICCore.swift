import Foundation

public enum BASICError: Error, CustomStringConvertible, Equatable {
    case syntax(String)
    case contextualSyntax(message: String, source: String, column: Int)
    case type(message: String)
    case contextualType(message: String, source: String, column: Int)
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
        case .type(let message): return "Type error: \(message)"
        case .contextualType(let message, let source, let column):
            let marker = String(repeating: " ", count: max(0, column)) + "^"
            return "\(source)\n\(marker)\nType error: \(message)"
        case .runtime(let message): return "Runtime error: \(message)"
        case .studioOnlyFeature: return "Unsupported feature: you must run this program in BASICStudio"
        case .missingLine(let line): return "Missing line \(line)"
        case .missingLabel(let label): return "Missing label \(label)"
        case .halted: return "Program halted"
        }
    }
}

public struct BASICString: Equatable, CustomStringConvertible {
    private enum Storage: Equatable {
        case text(String)
        case data(Data)
    }

    private let storage: Storage

    public init(_ value: String) {
        if value.utf8.contains(0) {
            self.storage = .data(Data(value.utf8))
        } else {
            self.storage = .text(value)
        }
    }

    private init(data: Data) {
        if data.contains(0) {
            self.storage = .data(data)
        } else {
            self.storage = .text(String(decoding: data, as: UTF8.self))
        }
    }

    public var description: String {
        switch storage {
        case .text(let value):
            return value
        case .data(let data):
            return String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
        }
    }

    var characterCount: Int {
        description.count
    }

    var byteCount: Int {
        switch storage {
        case .text(let value): return value.utf8.count
        case .data(let data): return data.count
        }
    }

    func concatenating(_ other: BASICString) -> BASICString {
        switch (storage, other.storage) {
        case (.text(let left), .text(let right)):
            return BASICString(left + right)
        default:
            return BASICString(data: data + other.data)
        }
    }

    private var data: Data {
        switch storage {
        case .text(let value): return Data(value.utf8)
        case .data(let data): return data
        }
    }

    static func character(code: Int) throws -> BASICString {
        guard (0...255).contains(code) else {
            throw BASICError.runtime("CHR$ code must be between 0 and 255")
        }
        if code == 0 {
            return BASICString(data: Data([0]))
        }
        guard let scalar = UnicodeScalar(code) else {
            throw BASICError.runtime("Invalid CHR$ code \(code)")
        }
        return BASICString(String(Character(scalar)))
    }
}

public enum BASICValue: Equatable, CustomStringConvertible {
    case number(Double)
    case string(BASICString)
    case boolean(Bool)

    public var description: String {
        switch self {
        case .number(let value):
            if value.rounded() == value {
                return String(Int(value))
            }
            return String(value)
        case .string(let value):
            return value.description
        case .boolean(let value):
            return value ? "TRUE" : "FALSE"
        }
    }

    var truthy: Bool {
        switch self {
        case .number(let value): return value != 0
        case .string(let value): return !value.description.isEmpty
        case .boolean(let value): return value
        }
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        if case .boolean(let value) = self { return value ? 1 : 0 }
        return nil
    }

    var string: BASICString? {
        if case .string(let value) = self { return value }
        return nil
    }

    private var isEmpty: Bool {
        if case .string(let value) = self {
            return value.description.isEmpty
        }
        return false
    }
}

private enum BASICScalarType: String, Equatable {
    case integer = "INTEGER"
    case double = "DOUBLE"
    case string = "STRING"
    case boolean = "BOOLEAN"
}

private enum BASICType: Equatable {
    case scalar(BASICScalarType)
    case record(String)
    case classType(String)
}

private enum LetMode: Equatable {
    case global
    case local
}

private enum AssignmentKind: Equatable {
    case bare
    case letValue
    case global
    case local
}

private struct VariableName: Equatable {
    let name: String
    let column: Int

    var normalized: String { name.uppercased() }
}

private struct VariableBinding: Equatable {
    var displayName: String
    var type: BASICType
    var value: BASICValue
}

private final class BASICRuntime {
    private var globals: [String: VariableBinding] = [:]
    private var locals: [[String: VariableBinding]] = []
    var letMode: LetMode = .global

    func resetForRun() {
        globals.removeAll()
        locals.removeAll()
    }

    func clearAll() {
        resetForRun()
        letMode = .global
    }

    func pushLocalContext() {
        locals.append([:])
    }

    func popLocalContext() {
        if !locals.isEmpty {
            _ = locals.removeLast()
        }
    }

    func value(for variable: VariableName) -> BASICValue {
        if let binding = binding(for: variable.normalized) {
            return binding.value
        }
        return defaultValue(for: inferredType(name: variable.name, value: nil))
    }

    func assign(
        kind: AssignmentKind,
        variable: VariableName,
        declaredType: BASICType?,
        value: BASICValue?
    ) throws {
        try validateSuffix(variable: variable, declaredType: declaredType)
        let normalized = variable.normalized
        let target = targetContext(kind: kind, normalized: normalized)
        let existing = binding(in: target, normalized: normalized)
        let type = try resolvedType(variable: variable, declaredType: declaredType, value: value, existing: existing)
        let coerced = try coerce(value ?? defaultValue(for: type), to: type, variable: variable)
        let binding = VariableBinding(displayName: variable.name, type: type, value: coerced)
        set(binding, in: target, normalized: normalized)
    }

    private enum TargetContext {
        case global
        case local(Int)
    }

    private func targetContext(kind: AssignmentKind, normalized: String) -> TargetContext {
        switch kind {
        case .global:
            return .global
        case .local:
            return locals.indices.last.map(TargetContext.local) ?? .global
        case .letValue:
            switch letMode {
            case .global:
                return .global
            case .local:
                return locals.indices.last.map(TargetContext.local) ?? .global
            }
        case .bare:
            if let visible = visibleContext(for: normalized) {
                return visible
            }
            switch letMode {
            case .global:
                return .global
            case .local:
                return locals.indices.last.map(TargetContext.local) ?? .global
            }
        }
    }

    private func visibleContext(for normalized: String) -> TargetContext? {
        for index in locals.indices.reversed() {
            if locals[index][normalized] != nil {
                return .local(index)
            }
        }
        if globals[normalized] != nil {
            return .global
        }
        return nil
    }

    private func binding(for normalized: String) -> VariableBinding? {
        if let context = visibleContext(for: normalized) {
            return binding(in: context, normalized: normalized)
        }
        return nil
    }

    private func binding(in context: TargetContext, normalized: String) -> VariableBinding? {
        switch context {
        case .global: return globals[normalized]
        case .local(let index): return locals[index][normalized]
        }
    }

    private func set(_ binding: VariableBinding, in context: TargetContext, normalized: String) {
        switch context {
        case .global:
            globals[normalized] = binding
        case .local(let index):
            locals[index][normalized] = binding
        }
    }

    private func resolvedType(
        variable: VariableName,
        declaredType: BASICType?,
        value: BASICValue?,
        existing: VariableBinding?
    ) throws -> BASICType {
        if let declaredType {
            if let existing, existing.type != declaredType {
                throw BASICError.type(message: "Cannot redeclare \(variable.name) as \(declaredType.name)")
            }
            return declaredType
        }
        if let existing {
            return existing.type
        }
        return inferredType(name: variable.name, value: value)
    }

    private func inferredType(name: String, value: BASICValue?) -> BASICType {
        if let suffixType = suffixType(for: name) {
            return suffixType
        }
        if let value {
            switch value {
            case .string: return .scalar(.string)
            case .boolean: return .scalar(.boolean)
            case .number(let number) where number.rounded() != number:
                return .scalar(.double)
            case .number:
                return .scalar(.double)
            }
        }
        return .scalar(.double)
    }

    private func suffixType(for name: String) -> BASICType? {
        switch name.last {
        case "$": return .scalar(.string)
        case "%": return .scalar(.integer)
        case "#": return .scalar(.double)
        default: return nil
        }
    }

    private func validateSuffix(variable: VariableName, declaredType: BASICType?) throws {
        guard let declaredType, let suffixType = suffixType(for: variable.name), suffixType != declaredType else {
            return
        }
        throw BASICError.type(message: "suffix \(variable.name.last!) conflicts with AS \(declaredType.name)")
    }

    private func coerce(_ value: BASICValue, to type: BASICType, variable: VariableName) throws -> BASICValue {
        guard case .scalar(let scalar) = type else {
            throw BASICError.type(message: "Cannot assign aggregate type \(type.name) yet")
        }

        switch scalar {
        case .string:
            guard let string = value.string else {
                throw BASICError.type(message: "Cannot assign non-string value to \(variable.name)")
            }
            return .string(string)
        case .double:
            guard let number = value.number else {
                throw BASICError.type(message: "Cannot assign non-numeric value to \(variable.name)")
            }
            return .number(number)
        case .integer:
            guard let number = value.number else {
                throw BASICError.type(message: "Cannot assign non-numeric value to \(variable.name)")
            }
            guard number.rounded() == number else {
                throw BASICError.type(message: "Cannot assign non-integer value to \(variable.name)")
            }
            return .number(number)
        case .boolean:
            if case .boolean = value {
                return value
            }
            guard let number = value.number, number == 0 || number == 1 else {
                throw BASICError.type(message: "Boolean \(variable.name) must be FALSE, TRUE, 0, or 1")
            }
            return .boolean(number == 1)
        }
    }

    private func defaultValue(for type: BASICType) -> BASICValue {
        switch type {
        case .scalar(.string): return .string(BASICString(""))
        case .scalar(.boolean): return .boolean(false)
        case .scalar: return .number(0)
        case .record, .classType: return .number(0)
        }
    }
}

private extension BASICType {
    var name: String {
        switch self {
        case .scalar(let scalar): return scalar.rawValue
        case .record(let name): return name
        case .classType(let name): return name
        }
    }
}

public protocol BASICHost: AnyObject {
    func print(_ text: String, terminator: String)
    func printLine(_ text: String)
    func readLine(prompt: String) -> String?
}

public protocol BASICFileHost: BASICHost {
    func loadTextFile(path: String) throws -> String
    func saveTextFile(path: String, text: String) throws
    func listFiles() throws -> [String]
}

public extension BASICFileHost {
    func saveTextFile(path: String, text: String) throws {
        throw BASICError.runtime("SAVE is not supported by this host")
    }

    func listFiles() throws -> [String] {
        throw BASICError.runtime("FILES is not supported by this host")
    }
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

public extension BASICHost {
    func print(_ text: String, terminator: String) {
        printLine(text + terminator.trimmingCharacters(in: .newlines))
    }
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

private final class BASICFileState {
    var lastFilePath: String?
}

public final class BASICSession {
    public let program = BASICProgram()
    private let host: BASICHost
    private let runtime = BASICRuntime()
    private let fileState = BASICFileState()

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
                    fileState.lastFilePath = path
                } catch {
                    throw BASICError.runtime("Could not load \(path): \(error.localizedDescription)")
                }
                return true
            }
            if let saveCommand = try Self.savePath(from: trimmed) {
                guard let fileHost = host as? BASICFileHost else {
                    throw BASICError.runtime("SAVE is not supported by this host")
                }
                guard let path = saveCommand ?? fileState.lastFilePath else {
                    throw BASICError.syntax("Expected path after SAVE")
                }
                do {
                    try fileHost.saveTextFile(path: path, text: program.listing())
                    fileState.lastFilePath = path
                } catch let error as BASICError {
                    throw error
                } catch {
                    throw BASICError.runtime("Could not save \(path): \(error.localizedDescription)")
                }
                return true
            }
            if Self.isFilesCommand(trimmed) {
                guard let fileHost = host as? BASICFileHost else {
                    throw BASICError.runtime("FILES is not supported by this host")
                }
                do {
                    let files = try fileHost.listFiles()
                    if !files.isEmpty {
                        host.printLine(files.joined(separator: "\n"))
                    }
                } catch let error as BASICError {
                    throw error
                } catch {
                    throw BASICError.runtime("Could not list files: \(error.localizedDescription)")
                }
                return true
            }

            if let startLine = try Self.runStartLine(from: trimmed) {
                runtime.resetForRun()
                try BASICInterpreter(program: program, host: host, runtime: runtime, fileState: fileState).run(startLine: startLine)
                return true
            }

            switch trimmed.uppercased() {
            case "LIST":
                let listing = program.listing()
                if !listing.isEmpty { host.printLine(listing) }
            case "NEW":
                program.clear()
                runtime.clearAll()
                fileState.lastFilePath = nil
            case "CLEAR":
                runtime.clearAll()
            case "HELP":
                host.printLine("Commands: RUN, LIST, LOAD, SAVE, FILES, NEW, CLEAR, HELP, QUIT")
                host.printLine("Statements: PRINT, LET, GLOBAL, LOCAL, OPTION, INPUT, GOTO, GOSUB, RETURN, IF expr THEN target, LABEL, END, REM")
            case "QUIT", "EXIT":
                return false
            default:
                try BASICInterpreter(program: immediateProgram(for: trimmed), host: host, runtime: runtime, fileState: fileState).run()
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
        try commandPath(keyword: "LOAD", from: source, requiresPath: true)
    }

    private static func savePath(from source: String) throws -> String?? {
        guard keywordPrefix("SAVE", matches: source) else { return nil }
        return try commandPath(keyword: "SAVE", from: source, requiresPath: false)
    }

    private static func commandPath(keyword: String, from source: String, requiresPath: Bool) throws -> String? {
        guard keywordPrefix(keyword, matches: source) else { return nil }
        let start = source.index(source.startIndex, offsetBy: keyword.count)
        let rest = source[start...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else {
            if requiresPath {
                throw BASICError.syntax("Expected path after \(keyword)")
            }
            return nil
        }

        if rest.hasPrefix("\"") {
            guard rest.hasSuffix("\""), rest.count >= 2 else {
                throw BASICError.syntax("Unterminated \(keyword) path")
            }
            return String(rest.dropFirst().dropLast())
        }

        return rest
    }

    private static func isFilesCommand(_ source: String) -> Bool {
        source.uppercased() == "FILES"
    }

    private static func runStartLine(from source: String) throws -> Int?? {
        guard keywordPrefix("RUN", matches: source) else { return nil }
        let start = source.index(source.startIndex, offsetBy: 3)
        let rest = source[start...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return .some(nil) }
        guard let line = Int(rest) else { throw BASICError.syntax("Expected line number after RUN") }
        return .some(line)
    }

    private static func keywordPrefix(_ keyword: String, matches source: String) -> Bool {
        guard source.count >= keyword.count else { return false }
        let end = source.index(source.startIndex, offsetBy: keyword.count)
        guard source[source.startIndex..<end].uppercased() == keyword else { return false }
        guard end < source.endIndex else { return true }
        return source[end].isWhitespace || source[end] == "\""
    }
}

public final class BASICInterpreter {
    private let program: BASICProgram
    private weak var host: BASICHost?
    private let runtime: BASICRuntime
    private let fileState: BASICFileState
    private var gosubStack: [Int] = []
    private var forStack: [ForFrame] = []

    public convenience init(program: BASICProgram, host: BASICHost) {
        self.init(program: program, host: host, runtime: BASICRuntime(), fileState: BASICFileState())
    }

    fileprivate init(program: BASICProgram, host: BASICHost, runtime: BASICRuntime, fileState: BASICFileState = BASICFileState()) {
        self.program = program
        self.host = host
        self.runtime = runtime
        self.fileState = fileState
    }

    public func run(startLine: Int? = nil) throws {
        gosubStack.removeAll()
        forStack.removeAll()
        let parsed = try program.orderedLines.flatMap { line in
            var parser = try Parser(source: line.source)
            let statement = try parser.parseStatement()
            return ParsedLine.flatten(number: line.number, statement: statement)
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
        if let startLine {
            guard let index = lineIndexByNumber[startLine] else { throw BASICError.missingLine(startLine) }
            pc = index
        }
        while pc < parsed.count {
            let current = parsed[pc]
            let next = try execute(current.statement, pc: pc, parsed: parsed)
            switch next {
            case .next:
                pc += 1
            case .jump(let index):
                pc = index
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
            case .exitSelect:
                guard let index = matchingEndSelect(after: pc, in: parsed) else {
                    throw BASICError.runtime("EXIT SELECT without SELECT")
                }
                pc = index + 1
            }
        }
    }

    private func execute(_ statement: Statement, pc: Int, parsed: [ParsedLine] = []) throws -> Flow {
        switch statement {
        case .empty, .remark:
            return .next
        case .label:
            return .next
        case .labeled(_, let statement):
            return try execute(statement, pc: pc, parsed: parsed)
        case .sequence(let statements):
            for statement in statements {
                let flow = try execute(statement, pc: pc, parsed: parsed)
                if flow != .next {
                    return flow
                }
            }
            return .next
        case .end:
            return .end
        case .print(let parts):
            let rendered = try renderPrint(parts)
            host?.print(rendered.text, terminator: rendered.terminator)
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
        case .assignment(let kind, let variable, let declaredType, let expression):
            let value = try expression.map(evaluate)
            try runtime.assign(kind: kind, variable: variable, declaredType: declaredType, value: value)
            return .next
        case .optionLetMode(let mode):
            runtime.letMode = mode
            return .next
        case .input(let name):
            let raw = host?.readLine(prompt: "\(name)? ") ?? ""
            let value: BASICValue
            if name.hasSuffix("$") {
                value = .string(BASICString(raw))
            } else if let number = Double(raw.trimmingCharacters(in: .whitespaces)) {
                value = .number(number)
            } else {
                throw BASICError.runtime("Expected numeric input for \(name)")
            }
            try runtime.assign(kind: .bare, variable: VariableName(name: name, column: 0), declaredType: nil, value: value)
            return .next
        case .load(let path):
            let resolvedPath = try string(path)
            try loadProgram(path: resolvedPath)
            return .next
        case .save(let path):
            let resolvedPath = try path.map(string) ?? fileState.lastFilePath
            guard let resolvedPath else { throw BASICError.syntax("Expected path after SAVE") }
            try saveProgram(path: resolvedPath)
            return .next
        case .files:
            try listFiles()
            return .next
        case .goto(let line):
            return .goto(line)
        case .gotoLabel(let label):
            return .gotoLabel(label)
        case .gosub(let target):
            gosubStack.append(pc + 1)
            runtime.pushLocalContext()
            return target.flow
        case .returnFromSubroutine:
            guard let index = gosubStack.popLast() else {
                throw BASICError.runtime("RETURN without GOSUB")
            }
            runtime.popLocalContext()
            return .returnTo(index)
        case .ifThen(let condition, let thenAction, let elseAction):
            if try evaluate(condition).truthy {
                return try execute(thenAction, pc: pc, parsed: parsed)
            }
            guard let elseAction else { return .next }
            return try execute(elseAction, pc: pc, parsed: parsed)
        case .forLoop(let variable, let start, let end, let step):
            return try forLoopFlow(variable: variable, start: start, end: end, step: step, pc: pc, parsed: parsed)
        case .nextLoop(let variables):
            return try nextLoopFlow(variables: variables)
        case .selectCase(let expression):
            return try selectCaseFlow(expression, pc: pc, parsed: parsed)
        case .caseClause, .caseElse:
            guard let index = matchingEndSelect(after: pc, in: parsed) else {
                throw BASICError.runtime("CASE without SELECT")
            }
            return .jump(index + 1)
        case .endSelect:
            return .next
        case .exitSelect:
            return .exitSelect
        }
    }

    private func forLoopFlow(
        variable: VariableName,
        start: Expression,
        end: Expression,
        step: Expression?,
        pc: Int,
        parsed: [ParsedLine]
    ) throws -> Flow {
        let startValue = try numeric(try evaluate(start))
        let endValue = try numeric(try evaluate(end))
        let stepValue = try step.map { try numeric(try evaluate($0)) } ?? 1
        guard stepValue != 0 else {
            throw BASICError.runtime("FOR STEP cannot be 0")
        }

        try runtime.assign(kind: .bare, variable: variable, declaredType: nil, value: .number(startValue))
        let entersLoop = stepValue > 0 ? startValue <= endValue : startValue >= endValue
        guard entersLoop else {
            guard let index = matchingNext(after: pc, in: parsed) else {
                throw BASICError.runtime("FOR without NEXT")
            }
            return .jump(index + 1)
        }

        forStack.append(ForFrame(variable: variable, endValue: endValue, stepValue: stepValue, loopStartIndex: pc))
        return .next
    }

    private func nextLoopFlow(variables: [VariableName]) throws -> Flow {
        if variables.isEmpty {
            return try advanceNextLoop(variable: nil)
        }

        for variable in variables {
            let flow = try advanceNextLoop(variable: variable)
            if flow != .next {
                return flow
            }
        }
        return .next
    }

    private func loadProgram(path: String) throws {
        guard let fileHost = host as? BASICFileHost else {
            throw BASICError.runtime("LOAD is not supported by this host")
        }
        do {
            program.loadSource(try fileHost.loadTextFile(path: path))
            fileState.lastFilePath = path
        } catch {
            throw BASICError.runtime("Could not load \(path): \(error.localizedDescription)")
        }
    }

    private func saveProgram(path: String) throws {
        guard let fileHost = host as? BASICFileHost else {
            throw BASICError.runtime("SAVE is not supported by this host")
        }
        do {
            try fileHost.saveTextFile(path: path, text: program.listing())
            fileState.lastFilePath = path
        } catch let error as BASICError {
            throw error
        } catch {
            throw BASICError.runtime("Could not save \(path): \(error.localizedDescription)")
        }
    }

    private func listFiles() throws {
        guard let fileHost = host as? BASICFileHost else {
            throw BASICError.runtime("FILES is not supported by this host")
        }
        do {
            let files = try fileHost.listFiles()
            if !files.isEmpty {
                host?.printLine(files.joined(separator: "\n"))
            }
        } catch let error as BASICError {
            throw error
        } catch {
            throw BASICError.runtime("Could not list files: \(error.localizedDescription)")
        }
    }

    private func advanceNextLoop(variable: VariableName?) throws -> Flow {
        guard let frame = forStack.last else {
            throw BASICError.runtime("NEXT without FOR")
        }
        if let variable, variable.normalized != frame.variable.normalized {
            throw BASICError.runtime("NEXT \(variable.name) without matching FOR")
        }

        let currentValue = try numeric(runtime.value(for: frame.variable))
        let nextValue = currentValue + frame.stepValue
        try runtime.assign(kind: .bare, variable: frame.variable, declaredType: nil, value: .number(nextValue))

        let continues = frame.stepValue > 0 ? nextValue <= frame.endValue : nextValue >= frame.endValue
        if continues {
            return .jump(frame.loopStartIndex + 1)
        }

        _ = forStack.popLast()
        return .next
    }

    private func renderPrint(_ parts: [PrintPart]) throws -> PrintOutput {
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

        let terminator = parts.last?.suppressesNewline == true ? "" : "\n"
        return PrintOutput(text: output, terminator: terminator)
    }

    private func execute(_ action: ConditionalAction, pc: Int, parsed: [ParsedLine]) throws -> Flow {
        switch action {
        case .branch(let target):
            return target.flow
        case .statement(let statement):
            return try execute(statement, pc: pc, parsed: parsed)
        }
    }

    private func selectCaseFlow(_ expression: Expression, pc: Int, parsed: [ParsedLine]) throws -> Flow {
        let testValue = try evaluate(expression)
        var depth = 0
        var elseIndex: Int?
        var index = pc + 1

        while index < parsed.count {
            switch parsed[index].statement {
            case .selectCase:
                depth += 1
            case .endSelect:
                if depth == 0 {
                    if let elseIndex {
                        return .jump(elseIndex + 1)
                    }
                    return .jump(index + 1)
                }
                depth -= 1
            case .caseClause(let clauses) where depth == 0:
                for clause in clauses {
                    if try caseClause(clause, matches: testValue) {
                        return .jump(index + 1)
                    }
                }
            case .caseElse where depth == 0:
                elseIndex = index
            default:
                break
            }
            index += 1
        }

        throw BASICError.runtime("SELECT without END SELECT")
    }

    private func matchingEndSelect(after pc: Int, in parsed: [ParsedLine]) -> Int? {
        var depth = 0
        var index = pc + 1
        while index < parsed.count {
            switch parsed[index].statement {
            case .selectCase:
                depth += 1
            case .endSelect:
                if depth == 0 {
                    return index
                }
                depth -= 1
            default:
                break
            }
            index += 1
        }
        return nil
    }

    private func matchingNext(after pc: Int, in parsed: [ParsedLine]) -> Int? {
        var depth = 0
        var index = pc + 1
        while index < parsed.count {
            for event in loopEvents(in: parsed[index].statement) {
                switch event {
                case .forLoop:
                    depth += 1
                case .nextLoop:
                    if depth == 0 {
                        return index
                    }
                    depth -= 1
                }
            }
            index += 1
        }
        return nil
    }

    private func loopEvents(in statement: Statement) -> [LoopEvent] {
        switch statement {
        case .forLoop:
            return [.forLoop]
        case .nextLoop:
            return [.nextLoop]
        case .labeled(_, let statement):
            return loopEvents(in: statement)
        case .sequence(let statements):
            return statements.flatMap(loopEvents)
        default:
            return []
        }
    }

    private func caseClause(_ clause: CaseClause, matches testValue: BASICValue) throws -> Bool {
        switch clause {
        case .equals(let expression):
            return try compare(testValue, .equal, evaluate(expression))
        case .range(let lower, let upper):
            return try compare(testValue, .greaterEqual, evaluate(lower)) && compare(testValue, .lessEqual, evaluate(upper))
        case .comparison(let operation, let expression):
            return try compare(testValue, operation, evaluate(expression))
        }
    }

    private func compare(_ left: BASICValue, _ operation: BinaryOperation, _ right: BASICValue) throws -> Bool {
        switch operation {
        case .equal:
            return left == right
        case .notEqual:
            return left != right
        case .less, .lessEqual, .greater, .greaterEqual:
            if let leftNumber = left.number, let rightNumber = right.number {
                switch operation {
                case .less: return leftNumber < rightNumber
                case .lessEqual: return leftNumber <= rightNumber
                case .greater: return leftNumber > rightNumber
                case .greaterEqual: return leftNumber >= rightNumber
                default: break
                }
            }
            if let leftString = left.string?.description, let rightString = right.string?.description {
                switch operation {
                case .less: return leftString < rightString
                case .lessEqual: return leftString <= rightString
                case .greater: return leftString > rightString
                case .greaterEqual: return leftString >= rightString
                default: break
                }
            }
            throw BASICError.runtime("Cannot compare these values")
        case .add, .subtract, .multiply, .divide, .and, .or:
            throw BASICError.runtime("Invalid CASE comparison")
        }
    }

    private func evaluate(_ expression: Expression) throws -> BASICValue {
        switch expression {
        case .number(let value):
            return .number(value)
        case .string(let value):
            return .string(BASICString(value))
        case .boolean(let value):
            return .boolean(value)
        case .variable(let name):
            return runtime.value(for: name)
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
        case .chrFunction(let expression):
            return .string(try BASICString.character(code: integer(expression)))
        case .lenFunction(let expression):
            guard let string = try evaluate(expression).string else {
                throw BASICError.runtime("LEN requires a string")
            }
            return .number(Double(string.characterCount))
        }
    }

    private func evaluateBinary(_ leftExpression: Expression, _ operation: BinaryOperation, _ rightExpression: Expression) throws -> BASICValue {
        let left = try evaluate(leftExpression)
        let right = try evaluate(rightExpression)

        switch operation {
        case .add:
            if let leftString = left.string, let rightString = right.string {
                return .string(leftString.concatenating(rightString))
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

    private func string(_ expression: Expression) throws -> String {
        guard let string = try evaluate(expression).string else {
            throw BASICError.runtime("Expected a string")
        }
        return string.description
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

    static func flatten(number: Int?, statement: Statement) -> [ParsedLine] {
        guard case .sequence(let statements) = statement else {
            return [ParsedLine(number: number, statement: statement)]
        }

        return statements.enumerated().map { index, statement in
            ParsedLine(number: index == 0 ? number : nil, statement: statement)
        }
    }
}

private struct ForFrame {
    let variable: VariableName
    let endValue: Double
    let stepValue: Double
    let loopStartIndex: Int
}

private enum LoopEvent {
    case forLoop
    case nextLoop
}

private enum Flow: Equatable {
    case next
    case jump(Int)
    case goto(Int)
    case gotoLabel(String)
    case returnTo(Int)
    case exitSelect
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
    case assignment(AssignmentKind, VariableName, BASICType?, Expression?)
    case optionLetMode(LetMode)
    case input(String)
    case load(Expression)
    case save(Expression?)
    case files
    case goto(Int)
    case gotoLabel(String)
    case gosub(BranchTarget)
    case returnFromSubroutine
    case ifThen(Expression, ConditionalAction, ConditionalAction?)
    case forLoop(variable: VariableName, start: Expression, end: Expression, step: Expression?)
    case nextLoop([VariableName])
    case selectCase(Expression)
    case caseClause([CaseClause])
    case caseElse
    case endSelect
    case exitSelect
    case end

    var label: String? {
        if case .label(let name) = self { return name }
        if case .labeled(let name, _) = self { return name }
        return nil
    }
}

private enum CaseClause: Equatable {
    case equals(Expression)
    case range(Expression, Expression)
    case comparison(BinaryOperation, Expression)
}

private enum PrintPart: Equatable {
    case expression(Expression)
    case separator(PrintSeparator)

    var suppressesNewline: Bool {
        if case .separator = self { return true }
        return false
    }
}

private enum PrintSeparator: Equatable {
    case comma
    case semicolon
}

private struct PrintOutput: Equatable {
    let text: String
    let terminator: String
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

private indirect enum ConditionalAction: Equatable {
    case branch(BranchTarget)
    case statement(Statement)
}

private indirect enum Expression: Equatable {
    case number(Double)
    case string(String)
    case boolean(Bool)
    case variable(VariableName)
    case unaryMinus(Expression)
    case binary(Expression, BinaryOperation, Expression)
    case pointFunction(GraphicsPoint)
    case chrFunction(Expression)
    case lenFunction(Expression)
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
        while index < source.endIndex, source[index].isLetter || source[index].isNumber {
            advance()
        }
        if index < source.endIndex, source[index] == "$" || source[index] == "%" || source[index] == "#" {
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
        if matchIdentifier("END") {
            if matchIdentifier("SELECT") {
                return .endSelect
            }
            return .end
        }
        if matchIdentifier("EXIT") {
            guard matchIdentifier("SELECT") else { throw syntax("Expected SELECT") }
            return .exitSelect
        }
        if matchIdentifier("OPTION") {
            return .optionLetMode(try parseLetMode())
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
            return try parseAssignment(kind: .letValue, requiresEquals: true)
        }
        if matchIdentifier("INPUT") {
            let name = try consumeIdentifier("Expected variable name after INPUT")
            return .input(name)
        }
        if matchIdentifier("LOAD") {
            return .load(try parseExpression())
        }
        if matchIdentifier("SAVE") {
            return .save(isStatementEnd ? nil : try parseExpression())
        }
        if matchIdentifier("FILES") {
            return .files
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
            let thenAction = try parseConditionalAction(stoppingAtElse: true)
            let elseAction = matchIdentifier("ELSE") ? try parseConditionalAction(stoppingAtElse: false) : nil
            return .ifThen(condition, thenAction, elseAction)
        }
        if matchIdentifier("STOP") {
            return .end
        }
        if case .identifier = peek {
            return try parseAssignment(kind: .bare, requiresEquals: true)
        }
        throw syntax("Unknown statement")
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
        let variable = try consumeVariableName("Expected variable name")
        let declaredType = try parseOptionalType(for: variable)
        let expression: Expression?
        if match(.equals) {
            expression = try parseExpression()
        } else if requiresEquals {
            throw syntax("Expected =")
        } else {
            expression = nil
        }
        return .assignment(kind, variable, declaredType, expression)
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
        let typeToken = tokens[current]
        guard case .identifier(let name) = advance() else {
            throw syntax("Expected type name")
        }
        let type: BASICType
        switch name.uppercased() {
        case "INTEGER": type = .scalar(.integer)
        case "DOUBLE": type = .scalar(.double)
        case "STRING": type = .scalar(.string)
        case "BOOLEAN": type = .scalar(.boolean)
        case "RECORD":
            guard case .identifier(let recordName) = advance() else { throw syntax("Expected RECORD type name") }
            type = .record(recordName)
        case "CLASS":
            guard case .identifier(let className) = advance() else { throw syntax("Expected CLASS type name") }
            type = .classType(className)
        default:
            throw BASICError.contextualType(message: "Unknown type \(name)", source: source, column: typeToken.column)
        }

        if let suffixType = suffixType(for: variable.name), suffixType != type {
            throw BASICError.contextualType(
                message: "suffix \(variable.name.last!) conflicts with AS \(type.name)",
                source: source,
                column: variable.column
            )
        }
        return type
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
            let uppercased = name.uppercased()
            if uppercased == "TRUE" { return .boolean(true) }
            if uppercased == "FALSE" { return .boolean(false) }
            if uppercased == "POINT", peek == .leftParen {
                return .pointFunction(try parsePoint(openParenAlreadyConsumed: false))
            }
            if uppercased == "CHR$", peek == .leftParen {
                return .chrFunction(try parseSingleArgumentFunction())
            }
            if uppercased == "LEN", peek == .leftParen {
                return .lenFunction(try parseSingleArgumentFunction())
            }
            let column = tokens[max(0, current - 1)].column
            return .variable(VariableName(name: name, column: column))
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

    private mutating func parseSingleArgumentFunction() throws -> Expression {
        guard match(.leftParen) else { throw syntax("Expected (") }
        let expression = try parseExpression()
        guard match(.rightParen) else { throw syntax("Expected )") }
        return expression
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
        "LABEL", "REM", "PRINT", "SCREEN", "COLOR", "CLS", "PSET", "PRESET", "LINE",
        "LET", "GLOBAL", "LOCAL", "OPTION", "INPUT", "LOAD", "SAVE", "FILES", "GOTO", "GOSUB", "RETURN", "IF",
        "FOR", "TO", "STEP", "NEXT", "SELECT", "CASE", "ELSE", "EXIT", "END", "STOP"
    ]
}
