import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct BASICString: Equatable, CustomStringConvertible, Sendable {
    private enum Storage: Equatable {
        case text(String)
        case data(Data)
    }

    private let storage: Storage

    /// Creates a BASIC string from Swift text, switching to data-backed storage if it contains NUL bytes.
    public init(_ value: String) {
        if value.utf8.contains(0) {
            self.storage = .data(Data(value.utf8))
        } else {
            self.storage = .text(value)
        }
    }

    init(rawData data: Data) {
        self.storage = .data(data)
    }

    /// Display text for the string, omitting embedded NUL bytes from data-backed values.
    public var description: String {
        switch storage {
        case .text(let value):
            return value
        case .data(let data):
            return String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
        }
    }

    var rawString: String {
        switch storage {
        case .text(let value): return value
        case .data(let data): return String(decoding: data, as: UTF8.self)
        }
    }

    var characterCount: Int {
        rawString.count
    }

    var byteCount: Int {
        switch storage {
        case .text(let value): return value.utf8.count
        case .data(let data): return data.count
        }
    }

    var rawData: Data {
        switch storage {
        case .text(let value): return Data(value.utf8)
        case .data(let data): return data
        }
    }

    func concatenating(_ other: BASICString) -> BASICString {
        switch (storage, other.storage) {
        case (.text(let left), .text(let right)):
            return BASICString(left + right)
        default:
            return BASICString(rawData: rawData + other.rawData)
        }
    }

    static func character(code: Int) throws -> BASICString {
        guard (0...255).contains(code) else {
            throw BASICError.runtime("CHR$ code must be between 0 and 255")
        }
        return BASICString(rawData: Data([UInt8(code)]))
    }
}

indirect enum BASICValue: Equatable, CustomStringConvertible, Sendable {
    case empty
    case null
    case number(Double)
    case string(BASICString)
    case boolean(Bool)
    case record(String, [String: BASICValue])
    case object(String, [String: BASICValue])
    case systemObject(String, Int)
    case task(BASICTaskHandle)
    case closure(BASICCapturedClosure)
    case array(BASICArray)
    case dictionary(BASICDictionary)

    static func == (lhs: BASICValue, rhs: BASICValue) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty), (.null, .null):
            return true
        case (.number(let left), .number(let right)):
            return left == right
        case (.string(let left), .string(let right)):
            return left == right
        case (.boolean(let left), .boolean(let right)):
            return left == right
        case (.record(let leftName, let leftFields), .record(let rightName, let rightFields)):
            return leftName == rightName && leftFields == rightFields
        case (.object(let leftName, let leftFields), .object(let rightName, let rightFields)):
            return leftName == rightName && leftFields == rightFields
        case (.systemObject(let leftName, let leftID), .systemObject(let rightName, let rightID)):
            return leftName == rightName && leftID == rightID
        case (.task(let left), .task(let right)):
            return left == right
        case (.closure(let left), .closure(let right)):
            return left === right
        case (.array(let left), .array(let right)):
            return left == right
        case (.dictionary(let left), .dictionary(let right)):
            return left == right
        default:
            return false
        }
    }

    var description: String {
        switch self {
        case .empty:
            return ""
        case .null:
            return "NULL"
        case .number(let value):
            if value.rounded() == value {
                return String(Int(value))
            }
            return String(value)
        case .string(let value):
            return value.description
        case .boolean(let value):
            return value ? "TRUE" : "FALSE"
        case .record(let name, _):
            return "<\(name)>"
        case .object(let name, _):
            return "<\(name)>"
        case .systemObject(let name, _):
            return "<\(name)>"
        case .task(let handle):
            return "<TASK #\(handle.id) \(handle.name)>"
        case .closure(let closure):
            return "<FUNCTION \(closure.name)>"
        case .array(let array):
            return "<ARRAY \(array.type.name)>"
        case .dictionary(let dictionary):
            return "<DICTIONARY \(dictionary.values.count) entries>"
        }
    }

    var truthy: Bool {
        switch self {
        case .empty, .null: return false
        case .number(let value): return value != 0
        case .string(let value): return !value.description.isEmpty
        case .boolean(let value): return value
        case .record, .object, .systemObject, .task, .closure, .array, .dictionary: return true
        }
    }

    var number: Double? {
        if case .empty = self { return 0 }
        if case .number(let value) = self { return value }
        if case .boolean(let value) = self { return value ? 1 : 0 }
        return nil
    }

    var string: BASICString? {
        if case .empty = self { return BASICString("") }
        if case .string(let value) = self { return value }
        return nil
    }

    private var isEmpty: Bool {
        if case .string(let value) = self {
            return value.description.isEmpty
        }
        return false
    }

    var compositeFields: (name: String, fields: [String: BASICValue])? {
        switch self {
        case .record(let name, let fields), .object(let name, let fields):
            return (name, fields)
        default:
            return nil
        }
    }

    var debugTypeName: String {
        switch self {
        case .empty:
            return "EMPTY"
        case .null:
            return "NULL"
        case .number:
            return "DOUBLE"
        case .string:
            return "STRING"
        case .boolean:
            return "BOOLEAN"
        case .record(let name, _):
            return name
        case .object(let name, _):
            return name
        case .systemObject(let name, _):
            return name
        case .task:
            return "TASK"
        case .closure(let closure):
            return "FUNCTION \(closure.signatureDescription)"
        case .array(let array):
            return "ARRAY OF \(array.type.name)"
        case .dictionary:
            return "DICTIONARY"
        }
    }
}

struct BASICArray: Equatable, Sendable {
    let dimensions: [Int]
    let type: BASICType
    let isDynamic: Bool
    var values: [BASICValue]
}

struct BASICDictionary: Equatable, Sendable {
    var values: [String: BASICValue] = [:]
}

struct BASICSecondsTimer: Equatable, Sendable {
    var intervalSeconds: Double
    var repeating = true
    var isRunning = false
}

enum BASICFileAccess: String, Equatable {
    case read = "READ"
    case write = "WRITE"
    case both = "BOTH"
}

enum BASICFileContentType: String, Equatable {
    case raw = "RAW"
    case text = "TEXT"
    case json = "JSON"
}

struct BASICOpenFile: Equatable {
    var path: String?
    var access: BASICFileAccess?
    var contentType: BASICFileContentType?
    var legacyMode: BASICLegacyFileMode?
    var isOpen = false
    var content = BASICString("")
    var position = 0
    var recordLength: Int?
    var fields: [BASICRandomField] = []
    var lastError: String?
}

struct BASICRandomField: Equatable {
    let width: Int
    let variable: VariableName
}

struct BASICRandomGenerator {
    private var state: UInt64 = 0x4d595df4d0f33173
    private var lastValue: Double = 0

    mutating func randomize(seed: Double) {
        let bits = seed.bitPattern
        state = bits ^ 0x9e3779b97f4a7c15
        if state == 0 {
            state = 0x4d595df4d0f33173
        }
        lastValue = 0
    }

    mutating func next(argument: Double?) -> Double {
        if let argument {
            if argument == 0 {
                return lastValue
            }
            if argument < 0 {
                randomize(seed: argument)
            }
        }
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let value = Double(state >> 11) / Double(1 << 53)
        lastValue = value
        return value
    }
}

/// Scope classification for variables exposed to debugger clients.
public enum BASICVariableScope: String, Sendable {
    /// A variable stored in the currently selected local stack frame.
    case local = "Local"
    /// A variable stored in global program state.
    case global = "Global"
}

/// A debugger-friendly snapshot of a variable or child value.
public struct BASICVariableSnapshot: Identifiable, Equatable, Sendable {
    /// Stable identifier derived from the variable path.
    public var id: String { path }
    /// Fully qualified path to the value, including array indexes or field names.
    public let path: String
    /// Display name for the value.
    public let name: String
    /// BASIC type name.
    public let typeName: String
    /// Display value summary.
    public let value: String
    /// Variable scope.
    public let scope: BASICVariableScope
    /// Nested children for arrays, dictionaries, records, and objects.
    public let children: [BASICVariableSnapshot]
}

/// A debugger-friendly snapshot of one modern or numbered file handle.
public struct BASICFileSnapshot: Identifiable, Equatable, Sendable {
    /// Stable identifier for debugger clients.
    public let id: String
    /// BASIC-facing reference such as `File(1)` or `#2`.
    public let reference: String
    /// Attached path, or an empty string for an unbound modern File object.
    public let path: String
    /// Access mode such as READ, WRITE, or BOTH.
    public let access: String
    /// Content or legacy mode such as TEXT, RAW, JSON, or RANDOM.
    public let type: String
    /// Current zero-based stream position.
    public let position: Int
    /// Current size in bytes.
    public let size: Int
    /// Whether the current position is at or beyond the end of the file.
    public let isAtEOF: Bool
    /// Whether the handle is open.
    public let isOpen: Bool
    /// Fixed record length for RANDOM files.
    public let recordLength: Int?
    /// Most recent operation error retained for this handle.
    public let lastError: String?
}

/// A debugger snapshot of one active call stack frame.
public struct BASICCallStackFrame: Identifiable, Equatable, Sendable {
    /// Stable identifier for UI lists.
    public var id: String { "\(index):\(kind):\(name)" }
    /// Zero-based frame index.
    public let index: Int
    /// Frame kind such as program, function, method, or GOSUB.
    public let kind: String
    /// Display name for the frame.
    public let name: String
    /// Source location associated with the frame when known.
    public let location: BASICBreakpointLocation?
    /// Class that declares the method, when this is a method frame.
    public let declaringClassName: String?
    /// Runtime receiver class, when this is a method frame.
    public let receiverClassName: String?
    /// Whether the method frame represents an override.
    public let isOverride: Bool
}

typealias BASICMetadata = [String: BASICValue]

protocol BASICFieldDefinition {
    var displayName: String { get }
    var type: BASICType { get }
}

struct BASICRecordField: Equatable, BASICFieldDefinition {
    let displayName: String
    let normalizedName: String
    let type: BASICType
    let fixedLength: Int?
    let arrayDimensions: [Int?]
    let json: BASICJSONFieldOptions?
    let metadata: BASICMetadata
    let defaultValue: BASICValue?
}

struct BASICRecordDefinition: Equatable {
    let displayName: String
    let normalizedName: String
    let fields: [BASICRecordField]
}

/// An `ENUM` gathered before the run (E1).
///
/// Payload-free, so there is no value kind to add: a member *is* its number,
/// and this table exists only so `PRINT` can show the name. Which member a
/// number names is a lookup; which table to consult is decided from the
/// expression's declared type, never from the value — that is what makes the
/// same rule work identically in the compiler, where there is no value to ask.
struct BASICEnumDefinition: Equatable {
    let displayName: String
    let normalizedName: String
    /// Members in declaration order, names as written.
    let members: [(name: String, value: Int)]
    /// Each member's fields, by normalized member name (E3); empty for a
    /// VB-style member.
    var fields: [String: [EnumCaseField]] = [:]

    /// The key a payload value keeps its case under. `$` cannot begin a BASIC
    /// field name, so it can never collide with one.
    static let tagKey = "$CASE"

    /// Whether any member carries fields. Such an ENUM's values are records —
    /// the case plus that case's fields — rather than numbers.
    var isPayload: Bool { fields.values.contains { !$0.isEmpty } }

    func fields(of member: String) -> [EnumCaseField] { fields[member.uppercased()] ?? [] }

    func member(named name: String) -> (name: String, value: Int)? {
        let wanted = name.uppercased()
        return members.first { $0.name.uppercased() == wanted }
    }

    func member(atTag tag: Double) -> (name: String, value: Int)? {
        members.first { Double($0.value) == tag }
    }

    static func == (lhs: BASICEnumDefinition, rhs: BASICEnumDefinition) -> Bool {
        lhs.normalizedName == rhs.normalizedName
            && lhs.members.map(\.name) == rhs.members.map(\.name)
            && lhs.members.map(\.value) == rhs.members.map(\.value)
            && lhs.fields == rhs.fields
    }

    /// The member with this value, or nil — VB shows the number when no
    /// member matches, which is what a nil here means.
    func name(of value: Double) -> String? {
        guard value == value.rounded() else { return nil }
        let whole = Int(value)
        return members.first { $0.value == whole }?.name
    }

    /// The value of a member by name, case-insensitively as BASIC reads it.
    func value(of member: String) -> Int? {
        let wanted = member.uppercased()
        return members.first { $0.name.uppercased() == wanted }?.value
    }
}

struct BASICInterfaceMember: Equatable {
    let displayName: String
    let normalizedName: String
    let parameters: [FunctionParameter]
    let returnType: BASICType
}

struct BASICInterfaceDefinition: Equatable {
    let displayName: String
    let normalizedName: String
    let inheritedInterfaces: [String]
    let members: [BASICInterfaceMember]
}

struct BASICFunctionTypeDefinition: Equatable {
    let displayName: String
    let normalizedName: String
    let parameters: [FunctionParameter]
    let returnType: BASICType
    let isAsync: Bool
}

struct BASICClassField: Equatable, BASICFieldDefinition {
    let displayName: String
    let normalizedName: String
    let type: BASICType
    let arrayDimensions: [Int?]
    let visibility: BASICMemberVisibility
    let declaringClassName: String
    let json: BASICJSONFieldOptions?
    let metadata: BASICMetadata
    let defaultValue: BASICValue?
}

struct BASICClassDefinition: Equatable {
    let displayName: String
    let normalizedName: String
    let baseClassName: String?
    let fields: [BASICClassField]
    let implementedInterfaces: [String]
    let methods: [String: FunctionDefinition]
}

/// Snapshot of a registered BASIC event handler.
public struct BASICEventHandlerRegistration: Equatable, Sendable {
    /// Event selector handled by the registered function.
    public let selector: BASICEventSelector
    /// Handler name as typed by the user.
    public let handlerName: String
    /// Case-normalized handler name for lookup.
    public let normalizedHandlerName: String
}

struct VariableBinding: Equatable, Sendable {
    var displayName: String
    var type: BASICType
    var value: BASICValue
}

/// Debugger-facing summary of a shared captured value cell.
public struct BASICSharedValueSnapshot: Identifiable, Equatable, Sendable {
    /// Stable shared cell identifier.
    public let id: Int
    /// Human-readable cell name.
    public let name: String
    /// BASIC type summary.
    public let typeName: String
    /// Display value summary.
    public let value: String
    /// Number of successful writes to the cell.
    public let revision: Int
    /// Intended capture/reference access policy.
    public let access: BASICCapturedReferenceAccess
}

/// Thread-safe storage cell for future captured variables and shared async state.
final class BASICSharedValueCell: @unchecked Sendable {
    private let lock = NSLock()
    private var currentValue: BASICValue
    private var revisionValue = 0

    let id: Int
    let name: String
    let access: BASICCapturedReferenceAccess

    init(id: Int, name: String, value: BASICValue, access: BASICCapturedReferenceAccess = .strongMutable) {
        self.id = id
        self.name = name
        self.currentValue = value
        self.access = access
    }

    var value: BASICValue {
        lock.lock()
        defer { lock.unlock() }
        return currentValue
    }

    @discardableResult
    func set(_ value: BASICValue) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard access == .strongMutable else { return false }
        currentValue = value
        revisionValue += 1
        return true
    }

    @discardableResult
    func update(_ transform: (BASICValue) throws -> BASICValue) rethrows -> BASICValue? {
        lock.lock()
        defer { lock.unlock() }
        guard access == .strongMutable else { return nil }
        let newValue = try transform(currentValue)
        currentValue = newValue
        revisionValue += 1
        return newValue
    }

    func snapshot() -> BASICSharedValueSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return BASICSharedValueSnapshot(
            id: id,
            name: name,
            typeName: currentValue.debugTypeName,
            value: currentValue.description,
            revision: revisionValue,
            access: access
        )
    }
}

/// Heap-owned captured variable environment for future closures and async frames.
final class BASICCapturedEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private var nextCellID = 1
    private var cells: [String: BASICSharedValueCell] = [:]
    private var order: [String] = []

    /// Captures or replaces a named value in this environment.
    @discardableResult
    func capture(
        name: String,
        value: BASICValue,
        access: BASICCapturedReferenceAccess = .strongMutable
    ) -> BASICSharedValueSnapshot {
        let normalized = name.uppercased()
        let cell: BASICSharedValueCell
        lock.lock()
        if let existing = cells[normalized] {
            lock.unlock()
            _ = existing.set(value)
            return existing.snapshot()
        }
        cell = BASICSharedValueCell(id: nextCellID, name: name, value: value, access: access)
        nextCellID += 1
        cells[normalized] = cell
        order.append(normalized)
        lock.unlock()
        return cell.snapshot()
    }

    /// Returns a captured value by name.
    func value(named name: String) -> BASICValue? {
        cell(named: name)?.value
    }

    /// Updates a captured value by name, if the cell is mutable.
    @discardableResult
    func set(_ value: BASICValue, named name: String) -> Bool {
        cell(named: name)?.set(value) ?? false
    }

    /// Applies a synchronized update to a captured value by name, if the cell is mutable.
    @discardableResult
    func update(named name: String, _ transform: (BASICValue) throws -> BASICValue) rethrows -> BASICValue? {
        guard let cell = cell(named: name) else { return nil }
        return try cell.update(transform)
    }

    /// Returns a debugger-facing snapshot for one captured value.
    func snapshot(named name: String) -> BASICSharedValueSnapshot? {
        cell(named: name)?.snapshot()
    }

    /// Captured values in creation order.
    var snapshots: [BASICSharedValueSnapshot] {
        lock.lock()
        let orderedCells = order.compactMap { cells[$0] }
        lock.unlock()
        return orderedCells.map { $0.snapshot() }
    }

    /// Number of values captured by this environment.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cells.count
    }

    private func cell(named name: String) -> BASICSharedValueCell? {
        lock.lock()
        defer { lock.unlock() }
        return cells[name.uppercased()]
    }
}

/// Operation stored by a captured closure.
typealias BASICCapturedClosureOperation = @Sendable (BASICCapturedEnvironment, [BASICValue]) throws -> BASICValue

/// Callable runtime value that carries captured variables with it.
final class BASICCapturedClosure: @unchecked Sendable {
    /// Human-readable closure name for diagnostics and debugger display.
    let name: String
    /// Captured variable environment owned by the closure.
    let environment: BASICCapturedEnvironment
    let parameters: [FunctionParameter]
    let returnType: BASICType
    let bodyExpression: Expression?
    let bodyStatements: [ClosureBodyLine]?
    private let operation: BASICCapturedClosureOperation

    init(
        name: String,
        environment: BASICCapturedEnvironment = BASICCapturedEnvironment(),
        operation: @escaping BASICCapturedClosureOperation
    ) {
        self.name = name
        self.environment = environment
        self.parameters = []
        self.returnType = .scalar(.variant)
        self.bodyExpression = nil
        self.bodyStatements = nil
        self.operation = operation
    }

    init(
        name: String,
        parameters: [FunctionParameter],
        returnType: BASICType,
        bodyExpression: Expression,
        environment: BASICCapturedEnvironment
    ) {
        self.name = name
        self.environment = environment
        self.parameters = parameters
        self.returnType = returnType
        self.bodyExpression = bodyExpression
        self.bodyStatements = nil
        self.operation = { _, _ in .empty }
    }

    init(
        name: String,
        parameters: [FunctionParameter],
        returnType: BASICType,
        bodyStatements: [ClosureBodyLine],
        environment: BASICCapturedEnvironment
    ) {
        self.name = name
        self.environment = environment
        self.parameters = parameters
        self.returnType = returnType
        self.bodyExpression = nil
        self.bodyStatements = bodyStatements
        self.operation = { _, _ in .empty }
    }

    /// Invokes the closure with BASIC argument values.
    func call(arguments: [BASICValue] = []) throws -> BASICValue {
        try operation(environment, arguments)
    }

    func matchesSignature(of definition: BASICFunctionTypeDefinition) -> Bool {
        guard !definition.isAsync else { return false }
        return returnType == definition.returnType
            && parameters.map(\.type) == definition.parameters.map(\.type)
    }

    func call(arguments: [BASICValue], interpreter: BASICInterpreter) throws -> BASICValue {
        guard bodyExpression != nil || bodyStatements != nil else {
            return try call(arguments: arguments)
        }
        guard arguments.count == parameters.count else {
            throw BASICError.runtime("Function \(name) expects \(parameters.count) arguments, got \(arguments.count)")
        }

        let localContextIndex = interpreter.runtime.pushLocalContext()
        defer { interpreter.runtime.popLocalContext() }
        for snapshot in environment.snapshots {
            if let capturedValue = environment.value(named: snapshot.name) {
                try interpreter.runtime.assign(
                    kind: .local,
                    variable: VariableName(name: snapshot.name, column: 0),
                    declaredType: nil,
                    value: capturedValue
                )
            }
        }
        for (parameter, argument) in zip(parameters, arguments) {
            try interpreter.runtime.assign(
                kind: .local,
                variable: parameter.variable,
                declaredType: parameter.type,
                value: argument
            )
        }
        _ = localContextIndex
        if let bodyExpression {
            return try interpreter.runtime.coerce(
                interpreter.evaluate(bodyExpression),
                to: returnType,
                variable: VariableName(name: name, column: 0)
            )
        }
        return try interpreter.callClosureBlock(self)
    }

    /// Debugger-facing snapshots of captured values.
    var capturedSnapshots: [BASICSharedValueSnapshot] {
        environment.snapshots
    }

    var signatureDescription: String {
        guard !parameters.isEmpty else { return name }
        let parameterList = parameters
            .map { "\($0.variable.name) AS \($0.type.name)" }
            .joined(separator: ", ")
        return "(\(parameterList)) AS \(returnType.name)"
    }
}

struct BASICRuntimeSnapshot: Sendable {
    var globals: [String: VariableBinding]
    var letMode: LetMode
    var keyMode: BASICKeyMode
}

struct FunctionDefinition: Equatable {
    let displayName: String
    let normalizedName: String
    let parameters: [FunctionParameter]
    let returnType: BASICType
    let isAsync: Bool
    let startIndex: Int
    let endIndex: Int
    let ownerClassName: String?
    let visibility: BASICMemberVisibility
    let isOverride: Bool
    let explicitInterfaceImplementations: [BASICExplicitInterfaceImplementation]
    let bodyExpression: Expression?

    init(
        displayName: String,
        normalizedName: String,
        parameters: [FunctionParameter],
        returnType: BASICType,
        isAsync: Bool = false,
        startIndex: Int,
        endIndex: Int,
        ownerClassName: String? = nil,
        visibility: BASICMemberVisibility = .public,
        isOverride: Bool = false,
        explicitInterfaceImplementations: [BASICExplicitInterfaceImplementation] = [],
        bodyExpression: Expression? = nil
    ) {
        self.displayName = displayName
        self.normalizedName = normalizedName
        self.parameters = parameters
        self.returnType = returnType
        self.isAsync = isAsync
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.ownerClassName = ownerClassName
        self.visibility = visibility
        self.isOverride = isOverride
        self.explicitInterfaceImplementations = explicitInterfaceImplementations
        self.bodyExpression = bodyExpression
    }
}

struct FunctionFrame {
    let definition: FunctionDefinition
    let receiverClassName: String?
    let localContextIndex: Int
    var returnValue: BASICValue
    var didReturn: Bool = false
}

struct GosubFrame {
    let returnIndex: Int
    let localContextIndex: Int
    let functionDepth: Int
    let displayName: String
}

struct FunctionCallResult {
    let value: BASICValue
    let receiver: BASICValue?
}

struct BASICHostReference: @unchecked Sendable {
    let host: BASICHost
}

struct BASICAsyncFunctionJob: @unchecked Sendable {
    let program: BASICProgram
    let host: BASICHostReference
    let runtimeSnapshot: BASICRuntimeSnapshot
    let definition: FunctionDefinition
    let receiver: BASICValue?
    let receiverClassName: String?
    let argumentValues: [BASICValue]
    let allowVoid: Bool
    let outputCoordinator: BASICHostOutputCoordinator

    func run(
        task: BASICTask,
        taskScheduler: BASICTaskScheduler,
        eventLoop: BASICEventLoop?,
        executionControl: BASICExecutionControl?
    ) async throws -> FunctionCallResult {
        await Task.yield()
        try Task.checkCancellation()
        let runtime = BASICRuntime()
        runtime.restore(snapshot: runtimeSnapshot)
        let interpreter = BASICInterpreter(
            program: program,
            host: host.host,
            runtime: runtime,
            fileState: BASICFileState(),
            executionControl: executionControl,
            task: task,
            taskScheduler: taskScheduler,
            eventLoop: eventLoop,
            outputCoordinator: outputCoordinator
        )
        try interpreter.prepare(startLine: nil)
        return try interpreter.callFunctionSynchronously(
            definition: definition,
            receiver: receiver,
            receiverClassName: receiverClassName,
            argumentValues: argumentValues,
            allowVoid: allowVoid
        )
    }
}

extension BASICValue {
    /// The runtime value of a literal the parser produced.
    init(_ literal: BASICLiteral) {
        switch literal {
        case .number(let value):
            self = .number(value)
        case .string(let value):
            self = .string(BASICString(value))
        case .boolean(let value):
            self = .boolean(value)
        case .null:
            self = .null
        case .empty:
            self = .empty
        }
    }
}
