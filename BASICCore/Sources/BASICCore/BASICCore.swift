import Foundation

/// Errors produced while parsing, validating, or running BASIC source.
public enum BASICError: Error, CustomStringConvertible, Equatable {
    /// A general syntax error without source-line context.
    case syntax(String)
    /// A syntax error tied to a specific source line and column.
    case contextualSyntax(message: String, source: String, column: Int)
    /// A general type-checking or coercion error.
    case type(message: String)
    /// A type error tied to a specific source line and column.
    case contextualType(message: String, source: String, column: Int)
    /// A runtime failure raised while executing a valid program.
    case runtime(String)
    /// A runtime failure raised by the BASIC ERROR statement.
    case numberedRuntime(Int)
    /// An operation that requires BASICStudio graphics support on the current host.
    case studioOnlyFeature
    /// A branch target referenced a missing numbered line.
    case missingLine(Int)
    /// A branch target referenced a missing label.
    case missingLabel(String)
    /// Execution was interrupted by a user break request.
    case breakRequested(Int?)
    /// Execution stopped at a configured breakpoint.
    case breakpoint(BASICBreakpointLocation)
    /// Execution stopped after completing a debugger step.
    case stepComplete(BASICBreakpointLocation)
    /// Execution halted intentionally.
    case halted

    /// A user-facing rendering of the error, including caret context when available.
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
        case .numberedRuntime(let number): return "Runtime error: Error \(number)"
        case .studioOnlyFeature: return "Unsupported feature: you must run this program in BASICStudio"
        case .missingLine(let line): return "Missing line \(line)"
        case .missingLabel(let label): return "Missing label \(label)"
        case .breakRequested(let line):
            if let line {
                return "Break at \(line)"
            }
            return "Break at unnumbered line"
        case .breakpoint(let location):
            return "Break at \(location.lineNumber)"
        case .stepComplete(let location):
            return "Break at \(location.lineNumber)"
        case .halted: return "Program halted"
        }
    }
}

/// Severity for diagnostics reported before running a BASIC program.
public enum BASICDiagnosticSeverity: String, Codable, Sendable {
    /// A diagnostic that prevents correct execution.
    case error
    /// A diagnostic that should be shown but does not necessarily prevent execution.
    case warning
}

/// A source diagnostic suitable for editor decorations and LIST CHECK output.
public struct BASICDiagnostic: Codable, Equatable, Sendable {
    /// Optional source file path associated with the diagnostic.
    public let fileName: String?
    /// One-based physical source line number.
    public let lineNumber: Int
    /// Zero-based source column.
    public let column: Int
    /// Human-readable diagnostic message.
    public let message: String
    /// Diagnostic severity.
    public let severity: BASICDiagnosticSeverity

    /// Creates a diagnostic at a source location.
    public init(
        fileName: String? = nil,
        lineNumber: Int,
        column: Int,
        message: String,
        severity: BASICDiagnosticSeverity = .error
    ) {
        self.fileName = fileName
        self.lineNumber = lineNumber
        self.column = column
        self.message = message
        self.severity = severity
    }
}

private extension BASICError {
    var isDebugPause: Bool {
        switch self {
        case .breakRequested, .breakpoint, .stepComplete:
            return true
        default:
            return false
        }
    }
}

/// String storage used by the interpreter, preserving embedded NUL bytes when required.
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

    private init(data: Data) {
        if data.contains(0) {
            self.storage = .data(data)
        } else {
            self.storage = .text(String(decoding: data, as: UTF8.self))
        }
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

indirect enum BASICValue: Equatable, CustomStringConvertible, Sendable {
    case empty
    case null
    case number(Double)
    case string(BASICString)
    case boolean(Bool)
    case record(String, [String: BASICValue])
    case object(String, [String: BASICValue])
    case systemObject(String, Int)
    case array(BASICArray)
    case dictionary(BASICDictionary)

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
        case .record, .object, .systemObject, .array, .dictionary: return true
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

private enum BASICFileAccess: String, Equatable {
    case read = "READ"
    case write = "WRITE"
    case both = "BOTH"
}

private enum BASICFileContentType: String, Equatable {
    case raw = "RAW"
    case text = "TEXT"
    case json = "JSON"
}

private enum BASICLegacyFileMode: String, Equatable {
    case input = "INPUT"
    case output = "OUTPUT"
    case append = "APPEND"
}

private struct BASICOpenFile: Equatable {
    var path: String?
    var access: BASICFileAccess?
    var contentType: BASICFileContentType?
    var isOpen = false
    var content = BASICString("")
    var position = 0
}

private struct BASICRandomGenerator {
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

enum BASICScalarType: String, Equatable, Sendable {
    case integer = "INTEGER"
    case double = "DOUBLE"
    case string = "STRING"
    case boolean = "BOOLEAN"
    case variant = "VARIANT"
}

enum BASICType: Equatable, Sendable {
    case scalar(BASICScalarType)
    case void
    case record(String)
    case classType(String)
    case interfaceType(String)
    case dictionary
}

private struct BASICTypeSpec: Equatable {
    let type: BASICType
    let fixedLength: Int?
}

private struct BASICJSONFieldOptions: Equatable {
    let name: String
}

private typealias BASICMetadata = [String: BASICValue]

private protocol BASICFieldDefinition {
    var displayName: String { get }
    var type: BASICType { get }
}

private struct BASICRecordField: Equatable, BASICFieldDefinition {
    let displayName: String
    let normalizedName: String
    let type: BASICType
    let fixedLength: Int?
    let arrayDimensions: [Int?]
    let json: BASICJSONFieldOptions?
    let metadata: BASICMetadata
    let defaultValue: BASICValue?
}

private struct BASICRecordDefinition: Equatable {
    let displayName: String
    let normalizedName: String
    let fields: [BASICRecordField]
}

private struct BASICInterfaceMember: Equatable {
    let displayName: String
    let normalizedName: String
    let parameters: [FunctionParameter]
    let returnType: BASICType
}

private struct BASICInterfaceDefinition: Equatable {
    let displayName: String
    let normalizedName: String
    let inheritedInterfaces: [String]
    let members: [BASICInterfaceMember]
}

private struct BASICExplicitInterfaceImplementation: Equatable {
    let interfaceName: String
    let normalizedInterfaceName: String
    let memberName: String
    let normalizedMemberName: String
}

private enum BASICMemberVisibility: String, Equatable {
    case `public` = "PUBLIC"
    case `private` = "PRIVATE"
    case `protected` = "PROTECTED"
}

private struct BASICClassField: Equatable, BASICFieldDefinition {
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

private struct BASICClassDefinition: Equatable {
    let displayName: String
    let normalizedName: String
    let baseClassName: String?
    let fields: [BASICClassField]
    let implementedInterfaces: [String]
    let methods: [String: FunctionDefinition]
}

private enum LetMode: Equatable {
    case global
    case local
}

private enum BASICKeyMode: Equatable {
    case aibasic
    case ibm
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

private struct VariableReference: Equatable {
    let base: VariableName
    var indexes: [Expression]
    var declarationDimensions: [Expression?]
    var fields: [String]
    var fieldIndexes: [[Expression]]
    var hasEmptyIndexList: Bool

    init(base: VariableName, indexes: [Expression] = [], declarationDimensions: [Expression?] = [], fields: [String] = [], fieldIndexes: [[Expression]] = [], hasEmptyIndexList: Bool = false) {
        self.base = base
        self.indexes = indexes
        self.declarationDimensions = declarationDimensions
        self.fields = fields
        self.fieldIndexes = fields.enumerated().map { index, _ in
            fieldIndexes.indices.contains(index) ? fieldIndexes[index] : []
        }
        self.hasEmptyIndexList = hasEmptyIndexList
    }

    var isSimple: Bool {
        indexes.isEmpty && declarationDimensions.isEmpty && fields.isEmpty && fieldIndexes.isEmpty && !hasEmptyIndexList
    }
}

private struct VariableBinding: Equatable {
    var displayName: String
    var type: BASICType
    var value: BASICValue
}

private struct FunctionParameter: Equatable {
    let variable: VariableName
    let type: BASICType
}

private struct FunctionDefinition: Equatable {
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

private struct FunctionFrame {
    let definition: FunctionDefinition
    let receiverClassName: String?
    let localContextIndex: Int
    var returnValue: BASICValue
    var didReturn: Bool = false
}

private struct GosubFrame {
    let returnIndex: Int
    let localContextIndex: Int
}

private struct FunctionCallResult {
    let value: BASICValue
    let receiver: BASICValue?
}

private enum ReadTarget: Equatable {
    case variable(VariableName)
    case reference(VariableReference)
}

private final class BASICRuntime {
    private var globals: [String: VariableBinding] = [:]
    private var locals: [[String: VariableBinding]] = []
    var recordDefinitions: [String: BASICRecordDefinition] = [:]
    var interfaceDefinitions: [String: BASICInterfaceDefinition] = [:]
    var classDefinitions: [String: BASICClassDefinition] = [:]
    var letMode: LetMode = .global
    var keyMode: BASICKeyMode = .aibasic
    var randomGenerator = BASICRandomGenerator()
    private var fileObjects: [Int: BASICOpenFile] = [:]
    private var nextFileObjectID = 1

    func resetForRun() {
        globals.removeAll()
        locals.removeAll()
        fileObjects.removeAll()
        nextFileObjectID = 1
    }

    func clearAll() {
        resetForRun()
        letMode = .global
        keyMode = .aibasic
    }

    func pushLocalContext() -> Int {
        locals.append([:])
        return locals.count - 1
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

    func declaredType(for reference: VariableReference) -> BASICType? {
        binding(for: reference.base.normalized)?.type
    }

    func metadata(
        for reference: VariableReference,
        indexes: [BASICValue],
        fieldIndexes: [[BASICValue]] = [],
        accessClassName: String? = nil
    ) throws -> BASICValue {
        let binding = binding(for: reference.base.normalized)
        var displayName = binding?.displayName ?? reference.base.name
        var currentType = binding?.type ?? inferredType(name: reference.base.name, value: binding?.value)
        var currentValue = binding?.value ?? defaultValue(for: currentType)
        var metadata: BASICMetadata = [:]
        var path = displayName
        var parentPath: String?
        var indexDescription: String?

        if !indexes.isEmpty {
            let indexed = try reflectedIndexedValue(
                currentValue,
                indexes: indexes,
                name: displayName
            )
            currentValue = indexed.value
            currentType = indexed.type
            indexDescription = reflectionIndexDescription(indexes)
        }

        for (fieldIndex, fieldName) in reference.fields.enumerated() {
            guard let composite = currentValue.compositeFields else {
                throw BASICError.runtime("\(reference.base.name) has no field \(fieldName)")
            }
            let (recordName, fields) = composite
            let lookupTypeName = fieldIndex == 0 ? fieldSurfaceType(for: reference)?.name ?? recordName : recordName
            try validateFieldAccess(typeName: lookupTypeName, fieldName: fieldName, accessClassName: accessClassName)
            guard let field = compositeFieldDefinitions(for: lookupTypeName).first(where: { $0.normalizedName == fieldName.uppercased() }) else {
                throw BASICError.runtime("\(fieldLookupTypeName(fieldSurfaceType(for: reference), fallbackTypeName: recordName)) has no field \(fieldName)")
            }

            parentPath = path
            displayName = field.displayName
            metadata = field.metadata
            path = "\(path).\(displayName)"
            currentType = field.type
            currentValue = fields[field.normalizedName] ?? defaultValue(for: field)

            let indexes = fieldIndexes.indices.contains(fieldIndex) ? fieldIndexes[fieldIndex] : []
            if !indexes.isEmpty {
                let indexed = try reflectedIndexedValue(
                    currentValue,
                    indexes: indexes,
                    name: field.displayName
                )
                currentValue = indexed.value
                currentType = indexed.type
                indexDescription = reflectionIndexDescription(indexes)
            } else {
                indexDescription = nil
            }
        }

        return reflectionDictionary(
            metadata: metadata,
            name: displayName,
            typeName: reflectionTypeName(type: currentType, value: currentValue),
            path: path,
            parent: parentPath,
            index: indexDescription
        )
    }

    func reflectedFieldCount(for value: BASICValue) throws -> Int {
        try reflectedFields(for: value).count
    }

    func reflectedFieldName(for value: BASICValue, selector: BASICValue) throws -> String {
        try reflectedField(for: value, selector: selector).displayName
    }

    func reflectedFieldMetadata(for value: BASICValue, selector: BASICValue) throws -> BASICValue {
        let field = try reflectedField(for: value, selector: selector)
        return reflectionDictionary(
            metadata: field.metadata,
            name: field.displayName,
            typeName: field.type.name,
            path: field.displayName,
            parent: nil,
            index: nil
        )
    }

    func reflectedFieldValue(for value: BASICValue, selector: BASICValue) throws -> BASICValue {
        let composite = try reflectedComposite(for: value)
        let field = try reflectedField(for: value, selector: selector)
        return composite.fields[field.normalizedName] ?? defaultValue(for: field)
    }

    func settingReflectedField(value: BASICValue, selector: BASICValue, newValue: BASICValue) throws -> BASICValue {
        let composite = try reflectedComposite(for: value)
        let field = try reflectedField(for: value, selector: selector)
        var fields = composite.fields
        fields[field.normalizedName] = try coerceReflectedValue(newValue, to: field)
        switch value {
        case .record(let name, _):
            return .record(name, fields)
        case .object(let name, _):
            return .object(name, fields)
        default:
            throw BASICError.runtime("SETFIELD expects a record or object")
        }
    }

    private func reflectedComposite(for value: BASICValue) throws -> (name: String, fields: [String: BASICValue]) {
        guard let composite = value.compositeFields else {
            throw BASICError.runtime("Reflection expects a record or object")
        }
        return composite
    }

    private func reflectedFields(for value: BASICValue) throws -> [BASICClassField] {
        let composite = try reflectedComposite(for: value)
        return compositeFieldDefinitions(for: composite.name)
    }

    private func reflectedField(for value: BASICValue, selector: BASICValue) throws -> BASICClassField {
        let fields = try reflectedFields(for: value)
        if let number = selector.number {
            guard number.rounded() == number else {
                throw BASICError.runtime("Field index must be an integer")
            }
            let index = Int(number)
            guard fields.indices.contains(index) else {
                throw BASICError.runtime("Field index out of range")
            }
            return fields[index]
        }
        if let name = selector.string?.description {
            guard let field = fields.first(where: { $0.normalizedName == name.uppercased() }) else {
                throw BASICError.runtime("Unknown field \(name)")
            }
            return field
        }
        throw BASICError.runtime("Field selector must be a number or string")
    }

    private func coerceReflectedValue(_ value: BASICValue, to field: BASICClassField) throws -> BASICValue {
        if case .string(let string) = value {
            let text = string.description.trimmingCharacters(in: .whitespacesAndNewlines)
            switch field.type {
            case .scalar(.integer), .scalar(.double):
                if let number = Double(text) {
                    return try coerce(.number(number), to: field, variable: VariableName(name: field.displayName, column: 0))
                }
            case .scalar(.boolean):
                switch text.uppercased() {
                case "TRUE": return try coerce(.boolean(true), to: field, variable: VariableName(name: field.displayName, column: 0))
                case "FALSE": return try coerce(.boolean(false), to: field, variable: VariableName(name: field.displayName, column: 0))
                case "1": return try coerce(.number(1), to: field, variable: VariableName(name: field.displayName, column: 0))
                case "0": return try coerce(.number(0), to: field, variable: VariableName(name: field.displayName, column: 0))
                default: break
                }
            default:
                break
            }
        }
        return try coerce(value, to: field, variable: VariableName(name: field.displayName, column: 0))
    }

    static func isBuiltInClass(_ name: String) -> Bool {
        name.uppercased() == "FILE"
    }

    func fileObject(isOpen: Bool = false) -> BASICValue {
        let id = nextFileObjectID
        nextFileObjectID += 1
        fileObjects[id] = BASICOpenFile(isOpen: isOpen)
        return .systemObject("File", id)
    }

    func value(
        for reference: VariableReference,
        indexes: [BASICValue],
        fieldIndexes: [[BASICValue]] = [],
        accessClassName: String? = nil
    ) throws -> BASICValue {
        let declaredFieldType = fieldSurfaceType(for: reference)
        var value: BASICValue
        if !indexes.isEmpty, binding(for: reference.base.normalized) == nil {
            value = try createImplicitArray(for: reference.base, rank: indexes.count).value
        } else {
            value = self.value(for: reference.base)
        }
        if !indexes.isEmpty {
            switch value {
            case .array(let array):
                value = try arrayValue(array, at: indexes, name: reference.base.name)
            case .dictionary(let dictionary):
                value = try dictionaryValue(dictionary, at: indexes, name: reference.base.name)
            default:
                throw BASICError.runtime("\(reference.base.name) is not an array")
            }
        }
        for (fieldIndex, field) in reference.fields.enumerated() {
            if case .systemObject(let typeName, let id) = value {
                guard reference.fields.count == 1 else {
                    throw BASICError.runtime("\(typeName) has no field \(field)")
                }
                value = try callSystemObjectMethod(typeName: typeName, id: id, method: field, arguments: [])
                continue
            }
            guard let composite = value.compositeFields else {
                throw BASICError.runtime("\(reference.base.name) has no field \(field)")
            }
            let (recordName, fields) = composite
            let normalized = field.uppercased()
            let lookupTypeName = fieldIndex == 0 ? declaredFieldType?.name ?? recordName : recordName
            try validateFieldAccess(typeName: lookupTypeName, fieldName: field, accessClassName: accessClassName)
            guard fieldExists(typeName: lookupTypeName, fieldName: field) else {
                throw BASICError.runtime("\(fieldLookupTypeName(declaredFieldType, fallbackTypeName: recordName)) has no field \(field)")
            }
            guard let fieldValue = fields[normalized] else {
                throw BASICError.runtime("\(recordName) has no field \(field)")
            }
            value = fieldValue
            let indexes = fieldIndexes.indices.contains(fieldIndex) ? fieldIndexes[fieldIndex] : []
            if !indexes.isEmpty {
                switch value {
                case .array(let array):
                    value = try arrayValue(array, at: indexes, name: field)
                case .dictionary(let dictionary):
                    value = try dictionaryValue(dictionary, at: indexes, name: field)
                default:
                    throw BASICError.runtime("\(field) is not an array")
                }
            }
        }
        return value
    }

    func callSystemObjectMethod(typeName: String, id: Int, method: String, arguments: [BASICValue], fileHost: BASICFileHost? = nil, jsonDecoder: ((String) throws -> BASICValue)? = nil, jsonEncoder: ((BASICValue, Bool) throws -> String)? = nil) throws -> BASICValue {
        guard typeName.uppercased() == "FILE" else {
            throw BASICError.runtime("\(typeName) has no method \(method)")
        }
        return try callFileMethod(id: id, method: method, arguments: arguments, fileHost: fileHost, jsonDecoder: jsonDecoder, jsonEncoder: jsonEncoder)
    }

    func localSnapshots() -> [BASICVariableSnapshot] {
        guard let local = locals.last else { return [] }
        return snapshots(from: local, scope: .local)
    }

    func localSnapshots(depthFromTop: Int) -> [BASICVariableSnapshot] {
        let index = locals.count - 1 - depthFromTop
        guard locals.indices.contains(index) else { return [] }
        return snapshots(from: locals[index], scope: .local)
    }

    func localSnapshots(contextIndex: Int) -> [BASICVariableSnapshot] {
        guard locals.indices.contains(contextIndex) else { return [] }
        return snapshots(from: locals[contextIndex], scope: .local)
    }

    func globalSnapshots() -> [BASICVariableSnapshot] {
        snapshots(from: globals, scope: .global)
    }

    func jsonString(for value: BASICValue, pretty: Bool) throws -> String {
        let object = try jsonObject(for: value, declaredType: inferredType(name: "", value: value))
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]
        if pretty {
            options.insert(.prettyPrinted)
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: options)
        return String(decoding: data, as: UTF8.self)
    }

    func valueFromJSONString(_ source: String, permissive: Bool) throws -> BASICValue {
        var options: JSONSerialization.ReadingOptions = []
        if permissive {
            options.insert(.fragmentsAllowed)
        }
        let data = Data(source.utf8)
        let object = try JSONSerialization.jsonObject(with: data, options: options)
        return try basicValue(fromJSONObject: object)
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
        if case .array(let existingArray) = existing?.value, let value {
            let coercedArray = try coerceArray(value, toMatch: existingArray, variable: variable)
            let binding = VariableBinding(displayName: variable.name, type: existingArray.type, value: .array(coercedArray))
            set(binding, in: target, normalized: normalized)
            return
        }
        let coerced = try coerce(value ?? defaultValue(for: type), to: type, variable: variable)
        let binding = VariableBinding(displayName: variable.name, type: type, value: coerced)
        set(binding, in: target, normalized: normalized)
    }

    func dim(kind: AssignmentKind, variable: VariableName, dimensions: [Int?], declaredType: BASICType?) throws {
        try validateSuffix(variable: variable, declaredType: declaredType)
        guard !dimensions.isEmpty else {
            let type = resolvedDeclaredType(declaredType ?? inferredType(name: variable.name, value: nil))
            let binding = VariableBinding(displayName: variable.name, type: type, value: defaultValue(for: type))
            set(binding, in: targetContext(kind: kind, normalized: variable.normalized), normalized: variable.normalized)
            return
        }
        guard dimensions.allSatisfy({ ($0 ?? 0) >= 0 }) else {
            throw BASICError.runtime("DIM bounds must be non-negative")
        }
        let type = resolvedDeclaredType(declaredType ?? inferredType(name: variable.name, value: nil))
        let resolvedDimensions = dimensions.map { $0 ?? -1 }
        let elementCount = resolvedDimensions.contains(-1) ? 0 : resolvedDimensions.reduce(1) { $0 * ($1 + 1) }
        let array = BASICArray(
            dimensions: resolvedDimensions,
            type: type,
            isDynamic: dimensions.contains(where: { $0 == nil }),
            values: Array(repeating: defaultValue(for: type), count: elementCount)
        )
        let binding = VariableBinding(displayName: variable.name, type: type, value: .array(array))
        set(binding, in: targetContext(kind: kind, normalized: variable.normalized), normalized: variable.normalized)
    }

    func assign(
        reference: VariableReference,
        indexes: [BASICValue],
        fieldIndexes: [[BASICValue]] = [],
        value: BASICValue?,
        accessClassName: String? = nil
    ) throws {
        guard !reference.isSimple else {
            try assign(kind: .bare, variable: reference.base, declaredType: nil, value: value)
            return
        }

        let normalized = reference.base.normalized
        let context = targetContext(kind: .bare, normalized: normalized)
        var binding: VariableBinding
        if let existing = self.binding(in: context, normalized: normalized) {
            binding = existing
        } else if !indexes.isEmpty {
            binding = try createImplicitArray(for: reference.base, rank: indexes.count, in: context)
        } else {
            throw BASICError.runtime("\(reference.base.name) is not defined")
        }

        if !indexes.isEmpty {
            switch binding.value {
            case .array(var array):
                let offset = try arrayOffset(dimensions: array.dimensions, indexes: indexes, name: reference.base.name)
                if reference.fields.isEmpty {
                    array.values[offset] = try coerce(value ?? defaultValue(for: array.type), to: array.type, variable: reference.base)
                } else {
                    array.values[offset] = try assigningField(
                        reference.fields,
                        fieldIndexes: fieldIndexes,
                        in: array.values[offset],
                        value: value,
                        accessClassName: accessClassName,
                        declaredType: fieldSurfaceType(for: reference)
                    )
                }
                binding.value = .array(array)
                set(binding, in: context, normalized: normalized)
                return
            case .dictionary(var dictionary):
                let key = try dictionaryKey(from: indexes, name: reference.base.name)
                let currentValue = dictionary.values[key] ?? .empty
                if reference.fields.isEmpty {
                    dictionary.values[key] = value ?? .empty
                } else {
                    dictionary.values[key] = try assigningField(
                        reference.fields,
                        fieldIndexes: fieldIndexes,
                        in: currentValue,
                        value: value,
                        accessClassName: accessClassName,
                        declaredType: fieldSurfaceType(for: reference)
                    )
                }
                binding.value = .dictionary(dictionary)
                set(binding, in: context, normalized: normalized)
                return
            default:
                throw BASICError.runtime("\(reference.base.name) is not an array")
            }
        }

        binding.value = try assigningField(
            reference.fields,
            fieldIndexes: fieldIndexes,
            in: binding.value,
            value: value,
            accessClassName: accessClassName,
            declaredType: fieldSurfaceType(for: reference)
        )
        set(binding, in: context, normalized: normalized)
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

    @discardableResult
    private func createImplicitArray(
        for variable: VariableName,
        rank: Int,
        in context: TargetContext? = nil
    ) throws -> VariableBinding {
        let target = context ?? targetContext(kind: .bare, normalized: variable.normalized)
        let type = resolvedDeclaredType(inferredType(name: variable.name, value: nil))
        try validateSuffix(variable: variable, declaredType: type)
        let dimensions = Array(repeating: 10, count: rank)
        let count = dimensions.reduce(1) { $0 * ($1 + 1) }
        let binding = VariableBinding(
            displayName: variable.name,
            type: type,
            value: .array(BASICArray(
                dimensions: dimensions,
                type: type,
                isDynamic: false,
                values: Array(repeating: defaultValue(for: type), count: count)
            ))
        )
        set(binding, in: target, normalized: variable.normalized)
        return binding
    }

    private func jsonObject(for value: BASICValue, declaredType: BASICType) throws -> Any {
        switch value {
        case .empty, .null:
            return NSNull()
        case .number(let number):
            return number
        case .string(let string):
            return string.rawString
        case .boolean(let boolean):
            return boolean
        case .systemObject:
            throw BASICError.runtime("System objects cannot be encoded as JSON")
        case .array(let array):
            return try jsonArrayObject(for: array)
        case .dictionary(let dictionary):
            var object: [String: Any] = [:]
            for key in dictionary.values.keys.sorted() {
                object[key] = try jsonObject(for: dictionary.values[key] ?? .empty, declaredType: inferredType(name: key, value: dictionary.values[key]))
            }
            return object
        case .record(let name, let fields):
            let definition = recordDefinitions[name.uppercased()]
            var object: [String: Any] = [:]
            for field in definition?.fields ?? [] {
                guard let json = field.json else { continue }
                let fieldValue = fields[field.normalizedName] ?? defaultValue(for: field)
                object[json.name] = try jsonObject(for: fieldValue, declaredType: field.type)
            }
            return object
        case .object(let name, let fields):
            guard let definition = classDefinitions[name.uppercased()] else { return [:] }
            var object: [String: Any] = [:]
            for field in inheritedFields(for: definition) {
                guard let json = field.json else { continue }
                let fieldValue = fields[field.normalizedName] ?? defaultValue(for: field)
                object[json.name] = try jsonObject(for: fieldValue, declaredType: field.type)
            }
            return object
        }
    }

    private func basicValue(fromJSONObject object: Any) throws -> BASICValue {
        if object is NSNull {
            return .null
        }
        if let string = object as? String {
            return .string(BASICString(string))
        }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            return .number(number.doubleValue)
        }
        if let array = object as? [Any] {
            return .array(BASICArray(
                dimensions: [array.count - 1],
                type: .scalar(.variant),
                isDynamic: true,
                values: try array.map(basicValue(fromJSONObject:))
            ))
        }
        if let dictionary = object as? [String: Any] {
            var values: [String: BASICValue] = [:]
            for key in dictionary.keys.sorted() {
                values[key] = try basicValue(fromJSONObject: dictionary[key] as Any)
            }
            return .dictionary(BASICDictionary(values: values))
        }
        throw BASICError.runtime("Unsupported JSON value")
    }

    private func jsonArrayObject(for array: BASICArray) throws -> Any {
        guard array.dimensions.count > 1 else {
            return try array.values.map { try jsonObject(for: $0, declaredType: array.type) }
        }
        return try jsonArraySlice(for: array, dimension: 0, offset: 0).value
    }

    private func jsonArraySlice(for array: BASICArray, dimension: Int, offset: Int) throws -> (value: Any, nextOffset: Int) {
        let count = max(0, array.dimensions[dimension] + 1)
        var values: [Any] = []
        var cursor = offset
        if dimension == array.dimensions.count - 1 {
            for _ in 0..<count {
                values.append(try jsonObject(for: array.values[cursor], declaredType: array.type))
                cursor += 1
            }
            return (values, cursor)
        }
        for _ in 0..<count {
            let child = try jsonArraySlice(for: array, dimension: dimension + 1, offset: cursor)
            values.append(child.value)
            cursor = child.nextOffset
        }
        return (values, cursor)
    }

    private func resolvedType(
        variable: VariableName,
        declaredType: BASICType?,
        value: BASICValue?,
        existing: VariableBinding?
    ) throws -> BASICType {
        if let declaredType {
            let resolvedDeclaredType = resolvedDeclaredType(declaredType)
            if let existing, existing.type != resolvedDeclaredType {
                throw BASICError.type(message: "Cannot redeclare \(variable.name) as \(resolvedDeclaredType.name)")
            }
            return resolvedDeclaredType
        }
        if let existing {
            return existing.type
        }
        return inferredType(name: variable.name, value: value)
    }

    private func resolvedDeclaredType(_ type: BASICType) -> BASICType {
        if case .record(let name) = type, classDefinitions[name.uppercased()] != nil || Self.isBuiltInClass(name) {
            return .classType(name)
        }
        if case .record(let name) = type, interfaceDefinitions[name.uppercased()] != nil {
            return .interfaceType(name)
        }
        return type
    }

    private func inferredType(name: String, value: BASICValue?) -> BASICType {
        if let suffixType = suffixType(for: name) {
            return suffixType
        }
        if let value {
            switch value {
            case .empty, .null: return .scalar(.variant)
            case .string: return .scalar(.string)
            case .boolean: return .scalar(.boolean)
            case .number(let number) where number.rounded() != number:
                return .scalar(.double)
            case .number:
                return .scalar(.double)
            case .record(let name, _):
                return .record(name)
            case .object(let name, _):
                return .classType(name)
            case .systemObject(let name, _):
                return .classType(name)
            case .array(let array):
                return array.type
            case .dictionary:
                return .dictionary
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

    func coerce(_ value: BASICValue, to type: BASICType, variable: VariableName) throws -> BASICValue {
        if case .record(let name) = type {
            if case .record(let valueName, _) = value, valueName.uppercased() == name.uppercased() {
                return value
            }
            if case .dictionary(let dictionary) = value {
                return try decodeRecord(name: name, from: dictionary, variable: variable)
            }
            if case .object(let valueName, let fields) = value, valueName.uppercased() == name.uppercased() {
                return .record(valueName, fields)
            }
            if case .empty = value {
                return defaultValue(for: type)
            }
            throw BASICError.type(message: "Cannot assign non-\(name) value to \(variable.name)")
        }
        if case .classType(let name) = type {
            if Self.isBuiltInClass(name), case .systemObject(let valueName, _) = value, valueName.uppercased() == name.uppercased() {
                return value
            }
            if case .null = value {
                return .null
            }
            if case .dictionary(let dictionary) = value {
                return try decodeObject(name: name, from: dictionary, variable: variable)
            }
            if case .object(let valueName, _) = value {
                if valueName.uppercased() == name.uppercased() || isClass(valueName, subclassOf: name) {
                    return value
                }
            }
            if case .empty = value {
                return defaultValue(for: type)
            }
            throw BASICError.type(message: "Cannot assign non-\(name) object to \(variable.name)")
        }
        if case .interfaceType(let name) = type {
            if case .null = value {
                return .null
            }
            if case .object(let valueName, _) = value,
               classConforms(valueName, toInterface: name) {
                return value
            }
            if case .empty = value {
                return .empty
            }
            throw BASICError.type(message: "Cannot assign non-\(name) object to \(variable.name)")
        }
        if case .dictionary = type {
            if case .dictionary = value {
                return value
            }
            if case .empty = value {
                return defaultValue(for: type)
            }
            throw BASICError.type(message: "Cannot assign non-dictionary value to \(variable.name)")
        }
        guard case .scalar(let scalar) = type else {
            throw BASICError.type(message: "Cannot assign aggregate type \(type.name) yet")
        }
        switch scalar {
        case .variant:
            return value
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

    private func decodeRecord(name: String, from dictionary: BASICDictionary, variable: VariableName) throws -> BASICValue {
        guard let definition = recordDefinitions[name.uppercased()] else {
            throw BASICError.runtime("Type Mismatch")
        }
        var fields = defaultValue(for: .record(name)).compositeFields?.fields ?? [:]
        for field in definition.fields {
            guard let json = field.json, let sourceValue = dictionary.values[json.name] else { continue }
            do {
                fields[field.normalizedName] = try coerce(sourceValue, to: field, variable: VariableName(name: field.displayName, column: variable.column))
            } catch {
                throw BASICError.runtime("Type Mismatch")
            }
        }
        return .record(definition.displayName, fields)
    }

    private func decodeObject(name: String, from dictionary: BASICDictionary, variable: VariableName) throws -> BASICValue {
        guard let definition = classDefinitions[name.uppercased()] else {
            throw BASICError.runtime("Type Mismatch")
        }
        var fields = defaultValue(for: .classType(name)).compositeFields?.fields ?? [:]
        for field in inheritedFields(for: definition) {
            guard let json = field.json, let sourceValue = dictionary.values[json.name] else { continue }
            do {
                fields[field.normalizedName] = try coerce(sourceValue, to: field, variable: VariableName(name: field.displayName, column: variable.column))
            } catch {
                throw BASICError.runtime("Type Mismatch")
            }
        }
        return .object(definition.displayName, fields)
    }

    private func coerceArray(_ value: BASICValue, toMatch existingArray: BASICArray, variable: VariableName) throws -> BASICArray {
        guard case .array(let sourceArray) = value else {
            throw BASICError.runtime("Type Mismatch")
        }
        do {
            let shape = try arrayShape(from: sourceArray, rank: existingArray.dimensions.count)
            let dimensions: [Int]
            if existingArray.isDynamic {
                dimensions = try zip(existingArray.dimensions, shape).map { existing, decoded in
                    if existing >= 0, existing != decoded {
                        throw BASICError.runtime("Type Mismatch")
                    }
                    return existing >= 0 ? existing : decoded
                }
            } else {
                guard shape == existingArray.dimensions else {
                    throw BASICError.runtime("Type Mismatch")
                }
                dimensions = existingArray.dimensions
            }
            let sourceValues = try flattenedArrayValues(from: sourceArray, rank: existingArray.dimensions.count)
            return BASICArray(
                dimensions: dimensions,
                type: existingArray.type,
                isDynamic: existingArray.isDynamic,
                values: try sourceValues.map {
                    try coerce($0, to: existingArray.type, variable: variable)
                }
            )
        } catch {
            throw BASICError.runtime("Type Mismatch")
        }
    }

    private func arrayShape(from array: BASICArray, rank: Int) throws -> [Int] {
        guard rank > 0 else { throw BASICError.runtime("Type Mismatch") }
        if rank == 1 {
            return [array.values.count - 1]
        }
        guard let first = array.values.first else {
            return Array(repeating: -1, count: rank)
        }
        guard case .array(let firstArray) = first else {
            throw BASICError.runtime("Type Mismatch")
        }
        let childShape = try arrayShape(from: firstArray, rank: rank - 1)
        for value in array.values.dropFirst() {
            guard case .array(let childArray) = value,
                  try arrayShape(from: childArray, rank: rank - 1) == childShape else {
                throw BASICError.runtime("Type Mismatch")
            }
        }
        return [array.values.count - 1] + childShape
    }

    private func flattenedArrayValues(from array: BASICArray, rank: Int) throws -> [BASICValue] {
        guard rank > 0 else { throw BASICError.runtime("Type Mismatch") }
        if rank == 1 {
            return array.values
        }
        var values: [BASICValue] = []
        for value in array.values {
            guard case .array(let childArray) = value else {
                throw BASICError.runtime("Type Mismatch")
            }
            values.append(contentsOf: try flattenedArrayValues(from: childArray, rank: rank - 1))
        }
        return values
    }

    private func coerce(_ value: BASICValue, to field: BASICRecordField, variable: VariableName) throws -> BASICValue {
        if !field.arrayDimensions.isEmpty {
            guard case .array(let defaultArray) = defaultValue(for: field) else {
                throw BASICError.runtime("Type Mismatch")
            }
            return .array(try coerceArray(value, toMatch: defaultArray, variable: variable))
        }
        return try coerce(value, to: field.type, variable: variable)
    }

    private func coerce(_ value: BASICValue, to field: BASICClassField, variable: VariableName) throws -> BASICValue {
        if !field.arrayDimensions.isEmpty {
            guard case .array(let defaultArray) = defaultValue(for: field) else {
                throw BASICError.runtime("Type Mismatch")
            }
            return .array(try coerceArray(value, toMatch: defaultArray, variable: variable))
        }
        return try coerce(value, to: field.type, variable: variable)
    }

    private func callFileMethod(id: Int, method: String, arguments: [BASICValue], fileHost: BASICFileHost?, jsonDecoder: ((String) throws -> BASICValue)?, jsonEncoder: ((BASICValue, Bool) throws -> String)?) throws -> BASICValue {
        let normalized = method.uppercased()
        guard var file = fileObjects[id] else {
            throw BASICError.runtime("Bad file object")
        }

        func requireHost() throws -> BASICFileHost {
            guard let fileHost else { throw BASICError.runtime("File I/O is not supported by this host") }
            return fileHost
        }

        func requireOpen() throws {
            guard file.isOpen else { throw BASICError.runtime("File is not open") }
        }

        func requireAccess(_ allowed: Set<BASICFileAccess>) throws {
            guard let access = file.access, allowed.contains(access) else {
                throw BASICError.runtime("Bad file mode")
            }
        }

        switch normalized {
        case "OPEN":
            guard arguments.count == 4 else { throw BASICError.runtime("open expects 4 arguments") }
            guard !file.isOpen else { throw BASICError.runtime("File Already Open") }
            let path = try filePath(from: arguments[0])
            let access = try fileAccess(from: arguments[1])
            let contentType = try fileContentType(from: arguments[2])
            let requireNew = try fileBoolean(from: arguments[3])
            let host = try requireHost()
            let exists = try host.fileExists(path: path)
            if requireNew && exists {
                throw BASICError.runtime("File Already Exists")
            }
            if access == .read && !exists {
                throw BASICError.runtime("File Not Found")
            }
            let initialContent: BASICString
            if exists, access != .write || contentType == .json && access == .read {
                initialContent = BASICString(try host.loadTextFile(path: path))
            } else {
                initialContent = BASICString("")
                if access == .write || access == .both {
                    try host.saveTextFile(path: path, text: "")
                }
            }
            file = BASICOpenFile(path: path, access: access, contentType: contentType, isOpen: true, content: initialContent, position: 0)
            fileObjects[id] = file
            return .empty
        case "READ":
            try requireOpen()
            try requireAccess([.read, .both])
            guard file.contentType != .json else { throw BASICError.runtime("Bad file mode") }
            let raw = file.content.rawString
            let remaining = String(raw.dropFirst(file.position))
            let result: String
            if arguments.isEmpty {
                result = remaining
                file.position = raw.count
            } else {
                guard arguments.count == 1 else { throw BASICError.runtime("read expects 0 or 1 arguments") }
                let maxCount = max(0, try fileInteger(from: arguments[0]))
                result = String(remaining.prefix(maxCount))
                file.position += result.count
            }
            fileObjects[id] = file
            return .string(BASICString(result))
        case "JSON":
            try requireOpen()
            try requireAccess([.read, .both])
            guard file.contentType == .json else { throw BASICError.runtime("Bad file mode") }
            guard arguments.isEmpty else { throw BASICError.runtime("json expects 0 arguments") }
            guard let jsonDecoder else { throw BASICError.runtime("JSON is not available") }
            return try jsonDecoder(file.content.rawString)
        case "WRITE":
            try requireOpen()
            try requireAccess([.write, .both])
            guard file.contentType != .json else { throw BASICError.runtime("Bad file mode") }
            guard arguments.count == 1, let text = arguments[0].string else {
                throw BASICError.runtime("write expects a string")
            }
            let path = try openPath(file)
            file.content = file.content.concatenating(text)
            file.position = file.content.rawString.count
            try requireHost().saveTextFile(path: path, text: file.content.rawString)
            fileObjects[id] = file
            return .empty
        case "WRITEJSON":
            try requireOpen()
            try requireAccess([.write, .both])
            guard file.contentType == .json else { throw BASICError.runtime("Bad file mode") }
            guard arguments.count == 2 else { throw BASICError.runtime("writeJson expects 2 arguments") }
            guard let jsonEncoder else { throw BASICError.runtime("JSON is not available") }
            let pretty = try fileBoolean(from: arguments[1])
            let text = try jsonEncoder(arguments[0], pretty)
            let path = try openPath(file)
            try requireHost().saveTextFile(path: path, text: text)
            file.content = BASICString(text)
            file.position = text.count
            fileObjects[id] = file
            return .empty
        case "SIZE":
            try requireOpen()
            guard arguments.isEmpty else { throw BASICError.runtime("size expects 0 arguments") }
            return .number(Double(file.content.byteCount))
        case "CLOSE":
            guard arguments.isEmpty else { throw BASICError.runtime("close expects 0 arguments") }
            file.isOpen = false
            fileObjects[id] = file
            return .empty
        default:
            throw BASICError.runtime("File has no method \(method)")
        }
    }

    private func openPath(_ file: BASICOpenFile) throws -> String {
        guard let path = file.path else { throw BASICError.runtime("File is not open") }
        return path
    }

    private func filePath(from value: BASICValue) throws -> String {
        guard let string = value.string else { throw BASICError.runtime("Expected a string") }
        return string.description
    }

    private func fileInteger(from value: BASICValue) throws -> Int {
        guard let number = value.number, number.rounded() == number else { throw BASICError.runtime("Expected an integer") }
        return Int(number)
    }

    private func fileBoolean(from value: BASICValue) throws -> Bool {
        switch value {
        case .boolean(let boolean): return boolean
        case .number(let number) where number == 0: return false
        case .number(let number) where number == 1: return true
        default: throw BASICError.runtime("Expected a boolean")
        }
    }

    private func fileAccess(from value: BASICValue) throws -> BASICFileAccess {
        guard let string = value.string else { throw BASICError.runtime("Expected file access") }
        guard let access = BASICFileAccess(rawValue: string.description.uppercased()) else {
            throw BASICError.runtime("Expected READ, WRITE, or BOTH")
        }
        return access
    }

    private func fileContentType(from value: BASICValue) throws -> BASICFileContentType {
        guard let string = value.string else { throw BASICError.runtime("Expected file type") }
        guard let type = BASICFileContentType(rawValue: string.description.uppercased()) else {
            throw BASICError.runtime("Expected RAW, TEXT, or JSON")
        }
        return type
    }

    func defaultValue(for type: BASICType) -> BASICValue {
        switch type {
        case .void: return .empty
        case .scalar(.string): return .string(BASICString(""))
        case .scalar(.boolean): return .boolean(false)
        case .scalar(.variant): return .empty
        case .scalar: return .number(0)
        case .record(let name):
            guard let definition = recordDefinitions[name.uppercased()] else {
                return .record(name, [:])
            }
            let fields = Dictionary(uniqueKeysWithValues: definition.fields.map {
                ($0.normalizedName, defaultValue(for: $0))
            })
            return .record(definition.displayName, fields)
        case .classType(let name):
            if Self.isBuiltInClass(name) {
                return fileObject()
            }
            guard let definition = classDefinitions[name.uppercased()] else {
                return .object(name, [:])
            }
            let fields = Dictionary(uniqueKeysWithValues: inheritedFields(for: definition).map {
                ($0.normalizedName, defaultValue(for: $0))
            })
            return .object(definition.displayName, fields)
        case .interfaceType:
            return .empty
        case .dictionary:
            return .dictionary(BASICDictionary())
        }
    }

    private func defaultValue(for field: BASICRecordField) -> BASICValue {
        defaultValue(type: field.type, arrayDimensions: field.arrayDimensions, explicitDefault: field.defaultValue)
    }

    private func defaultValue(for field: BASICClassField) -> BASICValue {
        defaultValue(type: field.type, arrayDimensions: field.arrayDimensions, explicitDefault: field.defaultValue)
    }

    private func defaultValue(type: BASICType, arrayDimensions: [Int?], explicitDefault: BASICValue?) -> BASICValue {
        guard !arrayDimensions.isEmpty else {
            return explicitDefault ?? defaultValue(for: type)
        }
        let dimensions = arrayDimensions.map { $0 ?? -1 }
        let count = dimensions.contains(-1) ? 0 : dimensions.reduce(1) { $0 * ($1 + 1) }
        return .array(BASICArray(
            dimensions: dimensions,
            type: type,
            isDynamic: arrayDimensions.contains(where: { $0 == nil }),
            values: Array(repeating: defaultValue(for: type), count: count)
        ))
    }

    private func arrayValue(_ array: BASICArray, at indexes: [BASICValue], name: String) throws -> BASICValue {
        try array.values[arrayOffset(dimensions: array.dimensions, indexes: indexes, name: name)]
    }

    private func dictionaryValue(_ dictionary: BASICDictionary, at indexes: [BASICValue], name: String) throws -> BASICValue {
        dictionary.values[try dictionaryKey(from: indexes, name: name)] ?? .empty
    }

    private func reflectedIndexedValue(_ value: BASICValue, indexes: [BASICValue], name: String) throws -> (value: BASICValue, type: BASICType) {
        switch value {
        case .array(let array):
            return (try arrayValue(array, at: indexes, name: name), array.type)
        case .dictionary(let dictionary):
            let element = try dictionaryValue(dictionary, at: indexes, name: name)
            return (element, inferredType(name: name, value: element))
        default:
            throw BASICError.runtime("\(name) is not an array")
        }
    }

    private func reflectionDictionary(
        metadata: BASICMetadata,
        name: String,
        typeName: String,
        path: String,
        parent: String?,
        index: String?
    ) -> BASICValue {
        var values = metadata
        values["name"] = .string(BASICString(name))
        values["type"] = .string(BASICString(typeName))
        values["path"] = .string(BASICString(path))
        if let parent {
            values["parent"] = .string(BASICString(parent))
        }
        if let index {
            values["index"] = .string(BASICString(index))
        }
        return .dictionary(BASICDictionary(values: values))
    }

    private func reflectionTypeName(type: BASICType, value: BASICValue) -> String {
        if case .array(let array) = value {
            return "ARRAY OF \(array.type.name)"
        }
        return type.name
    }

    private func reflectionIndexDescription(_ indexes: [BASICValue]) -> String {
        let rendered = indexes.map { value in
            if let string = value.string {
                return "\"\(string.description)\""
            }
            return value.description
        }
        return "(\(rendered.joined(separator: ",")))"
    }

    private func arrayOffset(dimensions: [Int], indexes: [BASICValue], name: String) throws -> Int {
        guard indexes.count == dimensions.count else {
            throw BASICError.runtime("\(name) expects \(dimensions.count) indexes")
        }
        var multiplier = 1
        var offset = 0
        for (indexValue, upperBound) in zip(indexes.reversed(), dimensions.reversed()) {
            let index = try arrayIndex(from: indexValue, name: name)
            guard (0...upperBound).contains(index) else {
                throw BASICError.runtime("\(name) subscript out of range")
            }
            offset += index * multiplier
            multiplier *= upperBound + 1
        }
        return offset
    }

    private func arrayIndex(from value: BASICValue, name: String) throws -> Int {
        guard let number = value.number, number.rounded() == number else {
            throw BASICError.runtime("\(name) array index must be numeric")
        }
        return Int(number)
    }

    private func dictionaryKey(from indexes: [BASICValue], name: String) throws -> String {
        guard indexes.count == 1 else {
            throw BASICError.runtime("\(name) expects 1 key")
        }
        if let string = indexes[0].string {
            return string.description
        }
        if let number = indexes[0].number {
            return BASICValue.number(number).description
        }
        throw BASICError.runtime("\(name) dictionary key must be a string or number")
    }

    private func assigningField(
        _ fields: [String],
        fieldIndexes: [[BASICValue]] = [],
        in recordValue: BASICValue,
        value: BASICValue?,
        accessClassName: String?,
        declaredType: BASICType? = nil
    ) throws -> BASICValue {
        guard let first = fields.first else {
            return value ?? recordValue
        }
        guard let composite = recordValue.compositeFields else {
            throw BASICError.runtime("Cannot assign field \(first) on non-record value")
        }
        let recordName = composite.name
        var recordFields = composite.fields
        let surfaceTypeName = declaredType?.name ?? recordName
        let fieldDefinitions = compositeFieldDefinitions(for: surfaceTypeName)
        guard !fieldDefinitions.isEmpty else { throw BASICError.runtime("Unknown TYPE or CLASS \(recordName)") }
        let normalized = first.uppercased()
        guard let field = fieldDefinitions.first(where: { $0.normalizedName == normalized }) else {
            throw BASICError.runtime("\(fieldLookupTypeName(declaredType, fallbackTypeName: recordName)) has no field \(first)")
        }
        try validateAccess(to: field, from: accessClassName)
        let current = recordFields[normalized] ?? defaultValue(for: field)
        let indexes = fieldIndexes.first ?? []
        if fields.count == 1 {
            if indexes.isEmpty {
                recordFields[normalized] = try coerce(value ?? defaultValue(for: field), to: field, variable: VariableName(name: field.displayName, column: 0))
            } else {
                recordFields[normalized] = try assigningIndexedValue(
                    in: current,
                    indexes: indexes,
                    value: value,
                    field: field
                )
            }
        } else if indexes.isEmpty {
            recordFields[normalized] = try assigningField(
                Array(fields.dropFirst()),
                fieldIndexes: Array(fieldIndexes.dropFirst()),
                in: current,
                value: value,
                accessClassName: accessClassName
            )
        } else {
            recordFields[normalized] = try assigningIndexedField(
                Array(fields.dropFirst()),
                fieldIndexes: Array(fieldIndexes.dropFirst()),
                in: current,
                indexes: indexes,
                value: value,
                accessClassName: accessClassName,
                field: field
            )
        }
        switch recordValue {
        case .object:
            return .object(recordName, recordFields)
        default:
            return .record(recordName, recordFields)
        }
    }

    private func assigningIndexedValue(
        in current: BASICValue,
        indexes: [BASICValue],
        value: BASICValue?,
        field: any BASICFieldDefinition
    ) throws -> BASICValue {
        switch current {
        case .array(var array):
            let offset = try arrayOffset(dimensions: array.dimensions, indexes: indexes, name: field.displayName)
            array.values[offset] = try coerce(value ?? defaultValue(for: array.type), to: array.type, variable: VariableName(name: field.displayName, column: 0))
            return .array(array)
        case .dictionary(var dictionary):
            let key = try dictionaryKey(from: indexes, name: field.displayName)
            dictionary.values[key] = value ?? .empty
            return .dictionary(dictionary)
        default:
            throw BASICError.runtime("\(field.displayName) is not an array")
        }
    }

    private func assigningIndexedField(
        _ fields: [String],
        fieldIndexes: [[BASICValue]],
        in current: BASICValue,
        indexes: [BASICValue],
        value: BASICValue?,
        accessClassName: String?,
        field: any BASICFieldDefinition
    ) throws -> BASICValue {
        switch current {
        case .array(var array):
            let offset = try arrayOffset(dimensions: array.dimensions, indexes: indexes, name: field.displayName)
            array.values[offset] = try assigningField(
                fields,
                fieldIndexes: fieldIndexes,
                in: array.values[offset],
                value: value,
                accessClassName: accessClassName
            )
            return .array(array)
        case .dictionary(var dictionary):
            let key = try dictionaryKey(from: indexes, name: field.displayName)
            dictionary.values[key] = try assigningField(
                fields,
                fieldIndexes: fieldIndexes,
                in: dictionary.values[key] ?? .empty,
                value: value,
                accessClassName: accessClassName
            )
            return .dictionary(dictionary)
        default:
            throw BASICError.runtime("\(field.displayName) is not an array")
        }
    }

    private func fieldSurfaceType(for reference: VariableReference) -> BASICType? {
        guard !reference.fields.isEmpty else { return nil }
        switch declaredType(for: reference) {
        case .classType(let name):
            return .classType(name)
        case .interfaceType(let name):
            return .interfaceType(name)
        default:
            return nil
        }
    }

    private func snapshots(from bindings: [String: VariableBinding], scope: BASICVariableScope) -> [BASICVariableSnapshot] {
        bindings.values
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map {
                snapshot(
                    name: $0.displayName,
                    type: $0.type,
                    value: $0.value,
                    scope: scope,
                    path: "\(scope.rawValue):\($0.displayName)"
                )
            }
    }

    private func snapshot(
        name: String,
        type: BASICType,
        value: BASICValue,
        scope: BASICVariableScope,
        path: String
    ) -> BASICVariableSnapshot {
        switch value {
        case .array(let array):
            let children = array.values.enumerated().map { offset, element in
                let elementName = elementName(for: offset, dimensions: array.dimensions)
                return snapshot(
                    name: elementName,
                    type: array.type,
                    value: element,
                    scope: scope,
                    path: "\(path)\(elementName)"
                )
            }
            return BASICVariableSnapshot(
                path: path,
                name: name,
                typeName: "ARRAY OF \(array.type.name)",
                value: arraySummary(array),
                scope: scope,
                children: children
            )
        case .dictionary(let dictionary):
            let children = dictionary.values.keys.sorted().map { key in
                let value = dictionary.values[key] ?? .empty
                return snapshot(
                    name: "\"\(key)\"",
                    type: inferredType(name: key, value: value),
                    value: value,
                    scope: scope,
                    path: "\(path)(\"\(key)\")"
                )
            }
            return BASICVariableSnapshot(
                path: path,
                name: name,
                typeName: "DICTIONARY",
                value: "\(dictionary.values.count) entries",
                scope: scope,
                children: children
            )
        case .record(let recordName, let fields):
            let children = compositeFieldSnapshots(typeName: recordName, fields: fields, scope: scope, parentPath: path)
            return BASICVariableSnapshot(
                path: path,
                name: name,
                typeName: recordName,
                value: "\(children.count) fields",
                scope: scope,
                children: children
            )
        case .object(let className, let fields):
            let fieldCount = compositeFieldDefinitions(for: className).count
            let children = objectFieldSnapshots(typeName: className, fields: fields, scope: scope, parentPath: path)
            return BASICVariableSnapshot(
                path: path,
                name: name,
                typeName: className,
                value: "\(fieldCount > 0 ? fieldCount : children.count) fields",
                scope: scope,
                children: children
            )
        case .systemObject(let typeName, _):
            return BASICVariableSnapshot(
                path: path,
                name: name,
                typeName: typeName,
                value: value.description,
                scope: scope,
                children: []
            )
        default:
            return BASICVariableSnapshot(
                path: path,
                name: name,
                typeName: type.name,
                value: value.description,
                scope: scope,
                children: []
            )
        }
    }

    private func objectFieldSnapshots(
        typeName: String,
        fields: [String: BASICValue],
        scope: BASICVariableScope,
        parentPath: String
    ) -> [BASICVariableSnapshot] {
        guard let classDefinition = classDefinitions[typeName.uppercased()] else {
            return compositeFieldSnapshots(typeName: typeName, fields: fields, scope: scope, parentPath: parentPath)
        }

        let chain = inheritanceChain(for: classDefinition)
        guard chain.count > 1 else {
            return compositeFieldSnapshots(typeName: typeName, fields: fields, scope: scope, parentPath: parentPath)
        }

        return chain.compactMap { definition in
            let classFields = definition.fields
            guard !classFields.isEmpty else { return nil }
            let children = classFields.map { field in
                let value = fields[field.normalizedName] ?? defaultValue(for: field)
                return snapshot(
                    name: field.displayName,
                    type: field.type,
                    value: value,
                    scope: scope,
                    path: "\(parentPath).\(definition.displayName).\(field.displayName)"
                )
            }
            return BASICVariableSnapshot(
                path: "\(parentPath).\(definition.displayName)",
                name: definition.displayName,
                typeName: "CLASS",
                value: "\(children.count) fields",
                scope: scope,
                children: children
            )
        }
    }

    private func compositeFieldSnapshots(
        typeName: String,
        fields: [String: BASICValue],
        scope: BASICVariableScope,
        parentPath: String
    ) -> [BASICVariableSnapshot] {
        let definitions = compositeFieldDefinitions(for: typeName)
        if !definitions.isEmpty {
            return definitions.map { field in
                let value = fields[field.normalizedName] ?? defaultValue(for: field)
                return snapshot(
                    name: field.displayName,
                    type: field.type,
                    value: value,
                    scope: scope,
                    path: "\(parentPath).\(field.displayName)"
                )
            }
        }

        return fields.keys.sorted().map { key in
            let value = fields[key] ?? .empty
            return snapshot(
                name: key,
                type: inferredType(name: key, value: value),
                value: value,
                scope: scope,
                path: "\(parentPath).\(key)"
            )
        }
    }

    private func compositeFieldDefinitions(for typeName: String) -> [BASICClassField] {
        if let classDefinition = classDefinitions[typeName.uppercased()] {
            return inheritedFields(for: classDefinition)
        }
        if let recordDefinition = recordDefinitions[typeName.uppercased()] {
            return recordDefinition.fields.map {
                BASICClassField(
                    displayName: $0.displayName,
                    normalizedName: $0.normalizedName,
                    type: $0.type,
                    arrayDimensions: $0.arrayDimensions,
                    visibility: .public,
                    declaringClassName: recordDefinition.normalizedName,
                    json: $0.json,
                    metadata: $0.metadata,
                    defaultValue: $0.defaultValue
                )
            }
        }
        return []
    }

    private func inheritedFields(for classDefinition: BASICClassDefinition) -> [BASICClassField] {
        var fields: [BASICClassField] = []
        if let baseName = classDefinition.baseClassName,
           let baseDefinition = classDefinitions[baseName.uppercased()] {
            fields.append(contentsOf: inheritedFields(for: baseDefinition))
        }
        fields.append(contentsOf: classDefinition.fields)
        return fields
    }

    private func inheritanceChain(for classDefinition: BASICClassDefinition) -> [BASICClassDefinition] {
        var chain: [BASICClassDefinition] = []
        if let baseName = classDefinition.baseClassName,
           let baseDefinition = classDefinitions[baseName.uppercased()] {
            chain.append(contentsOf: inheritanceChain(for: baseDefinition))
        }
        chain.append(classDefinition)
        return chain
    }

    private func validateFieldAccess(typeName: String, fieldName: String, accessClassName: String?) throws {
        guard let field = compositeFieldDefinitions(for: typeName).first(where: { $0.normalizedName == fieldName.uppercased() }) else {
            return
        }
        try validateAccess(to: field, from: accessClassName)
    }

    private func fieldExists(typeName: String, fieldName: String) -> Bool {
        compositeFieldDefinitions(for: typeName).contains {
            $0.normalizedName == fieldName.uppercased()
        }
    }

    private func fieldLookupTypeName(_ declaredType: BASICType?, fallbackTypeName: String) -> String {
        switch declaredType {
        case .interfaceType(let name):
            return "INTERFACE \(name)"
        case .classType(let name):
            return "CLASS \(name)"
        default:
            return fallbackTypeName
        }
    }

    private func validateAccess(to field: BASICClassField, from accessClassName: String?) throws {
        switch field.visibility {
        case .public:
            return
        case .private:
            guard accessClassName?.uppercased() == field.declaringClassName.uppercased() else {
                throw BASICError.runtime("\(field.displayName) is PRIVATE")
            }
        case .protected:
            guard let accessClassName,
                  accessClassName.uppercased() == field.declaringClassName.uppercased()
                    || isClass(accessClassName, subclassOf: field.declaringClassName) else {
                throw BASICError.runtime("\(field.displayName) is PROTECTED")
            }
        }
    }

    private func isClass(_ className: String, subclassOf baseName: String) -> Bool {
        var current = classDefinitions[className.uppercased()]?.baseClassName
        while let currentName = current {
            if currentName.uppercased() == baseName.uppercased() {
                return true
            }
            current = classDefinitions[currentName.uppercased()]?.baseClassName
        }
        return false
    }

    private func classConforms(_ className: String, toInterface interfaceName: String) -> Bool {
        guard let classDefinition = classDefinitions[className.uppercased()] else { return false }
        return inheritedInterfaceNames(for: classDefinition).contains {
            $0.uppercased() == interfaceName.uppercased()
        }
    }

    private func inheritedInterfaceNames(for classDefinition: BASICClassDefinition) -> [String] {
        var names: [String] = []
        if let baseName = classDefinition.baseClassName,
           let baseDefinition = classDefinitions[baseName.uppercased()] {
            names.append(contentsOf: inheritedInterfaceNames(for: baseDefinition))
        }
        for interfaceName in classDefinition.implementedInterfaces {
            names.append(interfaceName)
            if let interfaceDefinition = interfaceDefinitions[interfaceName.uppercased()] {
                names.append(contentsOf: inheritedInterfaceNames(for: interfaceDefinition))
            }
        }
        return names
    }

    private func inheritedInterfaceNames(for interfaceDefinition: BASICInterfaceDefinition) -> [String] {
        var names: [String] = []
        for interfaceName in interfaceDefinition.inheritedInterfaces {
            names.append(interfaceName)
            if let inheritedDefinition = interfaceDefinitions[interfaceName.uppercased()] {
                names.append(contentsOf: inheritedInterfaceNames(for: inheritedDefinition))
            }
        }
        return names
    }

    private func arraySummary(_ array: BASICArray) -> String {
        let bounds = array.dimensions.map { "0...\($0)" }.joined(separator: " x ")
        return "\(array.values.count) elements (\(bounds))"
    }

    private func elementName(for offset: Int, dimensions: [Int]) -> String {
        guard !dimensions.isEmpty else { return "(0)" }
        var remainder = offset
        var indexes = Array(repeating: 0, count: dimensions.count)
        for dimensionIndex in stride(from: dimensions.count - 1, through: 0, by: -1) {
            let size = dimensions[dimensionIndex] + 1
            indexes[dimensionIndex] = remainder % size
            remainder /= size
        }
        return "(\(indexes.map(String.init).joined(separator: ",")))"
    }
}

private extension BASICType {
    var name: String {
        switch self {
        case .scalar(let scalar): return scalar.rawValue
        case .void: return "VOID"
        case .record(let name): return name
        case .classType(let name): return name
        case .interfaceType(let name): return name
        case .dictionary: return "DICTIONARY"
        }
    }
}

/// Minimal host interface used by the interpreter for terminal-like I/O.
public protocol BASICHost: AnyObject {
    /// Writes text without forcing a line break.
    func print(_ text: String, terminator: String)
    /// Writes one complete line of text.
    func printLine(_ text: String)
    /// Reads one line of input for INPUT and LINE INPUT.
    func readLine(prompt: String) -> String?
}

/// Optional host capability for ANSI-colored LIST output.
public protocol BASICListingStyleHost: BASICHost {
    /// True when the host can safely render ANSI syntax coloring for LIST output.
    var usesColoredListing: Bool { get }
}

/// Result returned by hosts that can stop LINE INPUT on special keys.
public struct BASICLineInputResult: Equatable, Sendable {
    /// Text typed before completion or special-key exit.
    public let text: String
    /// Normalized special key that ended input, if any.
    public let exitKey: String?

    /// Creates a line-input result.
    public init(text: String, exitKey: String? = nil) {
        self.text = text
        self.exitKey = exitKey
    }
}

/// Field constraints for configured LINE INPUT operations.
public struct BASICLineInputOptions: Equatable, Sendable {
    /// Visible field width, if the host should render a fixed-width entry field.
    public let fieldLength: Int?
    /// Maximum accepted input length.
    public let maxLength: Int?
    /// Text used to prefill the input buffer.
    public let defaultText: String?

    /// Creates line-input rendering and validation options.
    public init(fieldLength: Int? = nil, maxLength: Int? = nil, defaultText: String? = nil) {
        self.fieldLength = fieldLength
        self.maxLength = maxLength
        self.defaultText = defaultText
    }
}

/// Host extension point for LINE INPUT EXITVAR support.
public protocol BASICLineInputHost: BASICHost {
    /// Reads one line, optionally exiting early on special keys.
    func readLine(prompt: String, exitOnSpecialKey: Bool) -> BASICLineInputResult?
}

/// Host extension point for configured LINE INPUT field behavior.
public protocol BASICConfiguredLineInputHost: BASICLineInputHost {
    /// Reads one configured line-input field.
    func readLine(prompt: String, exitOnSpecialKey: Bool, options: BASICLineInputOptions) -> BASICLineInputResult?
}

/// Host interface for BASIC file-system operations.
public protocol BASICFileHost: BASICHost {
    /// Loads a UTF-8 text file.
    func loadTextFile(path: String) throws -> String
    /// Saves a UTF-8 text file.
    func saveTextFile(path: String, text: String) throws
    /// Returns whether a path exists.
    func fileExists(path: String) throws -> Bool
    /// Returns the BASIC working directory.
    func currentDirectoryPath() throws -> String
    /// Changes the BASIC working directory.
    func changeDirectory(path: String) throws
    /// Lists files in the current BASIC working directory.
    func listFiles() throws -> [String]
    /// Lists files in a specific directory path.
    func listFiles(path: String) throws -> [String]
}

/// Host interface for SYSTEM and SYSTEM$ command execution.
public protocol BASICSystemHost: BASICHost {
    /// Runs a shell command and returns combined output.
    func runSystemCommand(_ command: String) throws -> String
}

/// Host interface for non-blocking INKEY$ keyboard input.
public protocol BASICKeyboardHost: BASICHost {
    /// Reads one pending raw key sequence, or nil when no key is pending.
    func readKey() -> String?
}

/// Optional host capability for INPUT$ keyboard reads that wait for key presses.
public protocol BASICBlockingKeyboardHost: BASICKeyboardHost {
    /// Reads one raw key sequence, waiting until a key is available or input is cancelled.
    func readBlockingKey() -> String?
}

/// Host interface for cursor positioning and screen-size queries.
public protocol BASICConsoleHost: BASICHost {
    /// Current console column count.
    func screenColumns() -> Int
    /// Current console row count.
    func screenRows() -> Int
    /// Moves the console cursor to a one-based row and column.
    func locate(row: Int, column: Int) throws
}

/// Host interface for BASIC and system log collection.
public protocol BASICLoggingHost: BASICHost {
    /// Whether BASIC LOG statements and interpreter log hooks should be emitted.
    var isBASICLoggingEnabled: Bool { get }
    /// Appends a log entry.
    func log(level: String, issuer: String, module: String, text: String)
}

public extension BASICConsoleHost {
    /// Default console width for hosts that do not report a live size.
    func screenColumns() -> Int { 80 }

    /// Default console height for hosts that do not report a live size.
    func screenRows() -> Int { 25 }

    /// Default ANSI cursor-positioning implementation.
    func locate(row: Int, column: Int) throws {
        let safeRow = max(1, row)
        let safeColumn = max(1, column)
        print("\u{001B}[\(safeRow);\(safeColumn)H", terminator: "")
    }
}

/// Raw key constants and helpers for terminal key sequences.
public enum BASICRawKey {
    /// Raw escape character.
    public static let escape = "\u{1B}"
    /// Raw delete character.
    public static let delete = "\u{7F}"
    /// Raw backspace character.
    public static let backspace = "\u{8}"

    /// Returns a terminal escape sequence for a function key number.
    public static func functionKeySequence(_ number: Int) -> String? {
        switch number {
        case 1: return "\u{1B}OP"
        case 2: return "\u{1B}OQ"
        case 3: return "\u{1B}OR"
        case 4: return "\u{1B}OS"
        case 5: return "\u{1B}[15~"
        case 6: return "\u{1B}[17~"
        case 7: return "\u{1B}[18~"
        case 8: return "\u{1B}[19~"
        case 9: return "\u{1B}[20~"
        case 10: return "\u{1B}[21~"
        case 11: return "\u{1B}[23~"
        case 12: return "\u{1B}[24~"
        case 13: return "\u{1B}[25~"
        case 14: return "\u{1B}[26~"
        case 15: return "\u{1B}[28~"
        case 16: return "\u{1B}[29~"
        case 17: return "\u{1B}[31~"
        case 18: return "\u{1B}[32~"
        case 19: return "\u{1B}[33~"
        case 20: return "\u{1B}[34~"
        case 21: return "\u{1B}[35~"
        case 22: return "\u{1B}[36~"
        default: return nil
        }
    }
}

/// Output encoding used when normalizing special keys for INKEY$.
public enum BASICKeyEncoding {
    /// AIBasic textual key names such as `[K`, `[F1`, and `[GP:A`.
    case aibasic
    /// IBM/GW-BASIC-style extended key strings prefixed with CHR$(0).
    case ibm
}

/// Converts raw terminal or gamepad key events into BASIC INKEY$ strings.
public struct BASICKeyNormalizer {
    /// Normalizes a raw key sequence using the requested BASIC key encoding.
    public static func normalize(_ rawKey: String, encoding: BASICKeyEncoding = .aibasic) -> String {
        guard !rawKey.isEmpty else { return "" }
        if rawKey.hasPrefix("[GP:") {
            return rawKey
        }
        if rawKey.count == 1 {
            if rawKey == BASICRawKey.delete { return BASICRawKey.backspace }
            return rawKey
        }

        if let normalized = normalizedEscapeSequence(rawKey, encoding: encoding) {
            return normalized
        }

        return extended(code: 255, encoding: encoding)
    }

    private static func normalizedEscapeSequence(_ rawKey: String, encoding: BASICKeyEncoding) -> String? {
        guard rawKey.first == Character(BASICRawKey.escape) else { return nil }
        if rawKey == BASICRawKey.escape { return BASICRawKey.escape }

        let suffix = String(rawKey.dropFirst())
        let modifiers = modifiers(from: suffix)

        if let modifiedCharacter = modifiedCharacter(from: suffix) {
            return modifiedCharacter
        }

        if let code = modifiedNavigationCode(from: suffix) {
            return extended(code: code, shift: modifiers.shift, command: modifiers.command, option: modifiers.option, encoding: encoding)
        }

        if let key = modifiedFunctionKey(from: suffix) {
            return functionKey(key.number, ibmCode: key.ibmCode, shift: modifiers.shift, command: modifiers.command, option: modifiers.option, encoding: encoding)
        }

        switch suffix {
        case "[Z": return shiftTab(encoding: encoding)
        case "[A": return extended(code: 72, encoding: encoding)
        case "[B": return extended(code: 80, encoding: encoding)
        case "[C": return extended(code: 77, encoding: encoding)
        case "[D": return extended(code: 75, encoding: encoding)
        case "[H", "OH", "[1~", "[7~": return extended(code: 71, encoding: encoding)
        case "[F", "OF", "[4~", "[8~": return extended(code: 79, encoding: encoding)
        case "[2~": return extended(code: 82, encoding: encoding)
        case "[3~": return extended(code: 83, encoding: encoding)
        case "[5~": return extended(code: 73, encoding: encoding)
        case "[6~": return extended(code: 81, encoding: encoding)
        case "OP": return functionKey(1, ibmCode: 59, encoding: encoding)
        case "OQ": return functionKey(2, ibmCode: 60, encoding: encoding)
        case "OR": return functionKey(3, ibmCode: 61, encoding: encoding)
        case "OS": return functionKey(4, ibmCode: 62, encoding: encoding)
        case "[15~": return functionKey(5, ibmCode: 63, encoding: encoding)
        case "[17~": return functionKey(6, ibmCode: 64, encoding: encoding)
        case "[18~": return functionKey(7, ibmCode: 65, encoding: encoding)
        case "[19~": return functionKey(8, ibmCode: 66, encoding: encoding)
        case "[20~": return functionKey(9, ibmCode: 67, encoding: encoding)
        case "[21~": return functionKey(10, ibmCode: 68, encoding: encoding)
        case "[23~": return functionKey(11, ibmCode: 133, encoding: encoding)
        case "[24~": return functionKey(12, ibmCode: 134, encoding: encoding)
        default:
            if let number = functionKeyNumber(from: suffix), (13...22).contains(number) {
                return functionKey(number, ibmCode: 255, encoding: encoding)
            }
            return nil
        }
    }

    private static func modifiedCharacter(from suffix: String) -> String? {
        guard suffix.hasPrefix("[") else { return nil }
        let body = suffix.dropFirst()
        guard body.count >= 2 else { return nil }
        var index = body.startIndex
        var sawModifier = false
        while index < body.endIndex {
            let character = body[index]
            guard character == "!" || character == "$" || character == "#" else { break }
            sawModifier = true
            index = body.index(after: index)
        }
        guard sawModifier, index < body.endIndex else { return nil }
        let character = body[index]
        guard character.unicodeScalars.allSatisfy({ (32...126).contains(Int($0.value)) }) else { return nil }
        guard body.index(after: index) == body.endIndex else { return nil }
        return suffix
    }

    private static func modifiedNavigationCode(from suffix: String) -> Int? {
        guard suffix.hasPrefix("[") else { return nil }
        if suffix.hasPrefix("[1;"), let last = suffix.last {
            switch last {
            case "A": return 72
            case "B": return 80
            case "C": return 77
            case "D": return 75
            case "H": return 71
            case "F": return 79
            default: return nil
            }
        }

        guard suffix.hasSuffix("~") else { return nil }
        let body = suffix.dropFirst().dropLast()
        let base = body.split(separator: ";").first ?? ""
        switch base {
        case "2": return 82
        case "3": return 83
        case "5": return 73
        case "6": return 81
        default: return nil
        }
    }

    private static func modifiedFunctionKey(from suffix: String) -> (number: Int, ibmCode: Int)? {
        if suffix.hasPrefix("[1;"), let last = suffix.last {
            switch last {
            case "P": return (1, 59)
            case "Q": return (2, 60)
            case "R": return (3, 61)
            case "S": return (4, 62)
            default: break
            }
        }

        guard suffix.hasPrefix("["), suffix.hasSuffix("~") else { return nil }
        let body = suffix.dropFirst().dropLast()
        guard let base = Int(body.split(separator: ";").first ?? "") else { return nil }
        switch base {
        case 15: return (5, 63)
        case 17: return (6, 64)
        case 18: return (7, 65)
        case 19: return (8, 66)
        case 20: return (9, 67)
        case 21: return (10, 68)
        case 23: return (11, 133)
        case 24: return (12, 134)
        default:
            guard let number = functionKeyNumber(from: suffix), (13...22).contains(number) else { return nil }
            return (number, 255)
        }
    }

    private static func modifiers(from suffix: String) -> (shift: Bool, command: Bool, option: Bool) {
        guard let parameter = modifierParameter(from: suffix) else {
            return (false, false, false)
        }

        switch parameter {
        case 2: return (true, false, false)
        case 3: return (false, false, true)
        case 4: return (true, false, true)
        case 5: return (false, false, false)
        case 6: return (true, false, false)
        case 7: return (false, false, true)
        case 8: return (true, false, true)
        case 9: return (false, true, false)
        case 10: return (true, true, false)
        case 11: return (false, true, true)
        case 12: return (true, true, true)
        default: return (false, false, false)
        }
    }

    private static func modifierParameter(from suffix: String) -> Int? {
        guard let semicolon = suffix.lastIndex(of: ";") else { return nil }
        var digits = ""
        var index = suffix.index(after: semicolon)
        while index < suffix.endIndex {
            let character = suffix[index]
            guard character.isNumber else { break }
            digits.append(character)
            index = suffix.index(after: index)
        }
        return Int(digits)
    }

    private static func functionKeyNumber(from suffix: String) -> Int? {
        guard suffix.hasPrefix("["), suffix.hasSuffix("~") else { return nil }
        let body = suffix.dropFirst().dropLast()
        guard let value = Int(body.split(separator: ";").first ?? "") else { return nil }
        switch value {
        case 25: return 13
        case 26: return 14
        case 28: return 15
        case 29: return 16
        case 31: return 17
        case 32: return 18
        case 33: return 19
        case 34: return 20
        case 35: return 21
        case 36: return 22
        default: return nil
        }
    }

    private static func functionKey(_ number: Int, ibmCode: Int, shift: Bool = false, command: Bool = false, option: Bool = false, encoding: BASICKeyEncoding) -> String {
        switch encoding {
        case .aibasic:
            var modifiers = ""
            if shift { modifiers += "!" }
            if command { modifiers += "$" }
            if option { modifiers += "#" }
            return "[\(modifiers)F\(number)"
        case .ibm:
            return extended(code: ibmCode, encoding: encoding)
        }
    }

    private static func shiftTab(encoding: BASICKeyEncoding) -> String {
        switch encoding {
        case .aibasic:
            return "[!T"
        case .ibm:
            return extended(code: 255, encoding: encoding)
        }
    }

    private static func extended(code: Int, shift: Bool = false, command: Bool = false, option: Bool = false, encoding: BASICKeyEncoding) -> String {
        let scalar = String(UnicodeScalar(code) ?? UnicodeScalar(255)!)
        switch encoding {
        case .aibasic:
            var modifiers = ""
            if shift { modifiers += "!" }
            if command { modifiers += "$" }
            if option { modifiers += "#" }
            return "[\(modifiers)\(scalar)"
        case .ibm:
            return "\u{0}\(scalar)"
        }
    }
}

public extension BASICFileHost {
    /// Default implementation for hosts that do not support saving.
    func saveTextFile(path: String, text: String) throws {
        throw BASICError.runtime("SAVE is not supported by this host")
    }

    /// Default implementation for hosts that do not expose file existence.
    func fileExists(path: String) throws -> Bool {
        false
    }

    /// Default current directory implementation backed by Foundation.
    func currentDirectoryPath() throws -> String {
        FileManager.default.currentDirectoryPath
    }

    /// Default current directory mutation backed by Foundation.
    func changeDirectory(path: String) throws {
        guard FileManager.default.changeCurrentDirectoryPath(path) else {
            throw BASICError.runtime("Could not change directory to \(path)")
        }
    }

    /// Default implementation for hosts that do not support FILES.
    func listFiles() throws -> [String] {
        throw BASICError.runtime("FILES is not supported by this host")
    }

    /// Default implementation for hosts that do not support directory imports.
    func listFiles(path: String) throws -> [String] {
        throw BASICError.runtime("Directory IMPORT is not supported by this host")
    }
}

public extension BASICSystemHost {
    /// Default SYSTEM implementation using `/bin/sh -lc`.
    func runSystemCommand(_ command: String) throws -> String {
        try BASICSystemCommand.run(command)
    }
}

/// Helper for running shell commands for hosts that allow SYSTEM support.
public enum BASICSystemCommand {
    /// Runs a command through `/bin/sh -lc` and returns combined stdout/stderr text.
    public static func run(_ command: String, workingDirectory: URL? = nil) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw BASICError.runtime("Could not execute command: \(error.localizedDescription)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Debugger execution mode.
public enum BASICExecutionMode: Sendable {
    /// Run normally until completion, break, or breakpoint.
    case run
    /// Pause after the next executed statement.
    case stepInto
    /// Pause after stepping over calls deeper than the provided call depth.
    case stepOver(depth: Int)
    /// Pause after returning out of the provided call depth.
    case stepOut(depth: Int)
}

/// Thread-safe execution-control object for breaks, breakpoints, and stepping.
public final class BASICExecutionControl: @unchecked Sendable {
    private let lock = NSLock()
    private var breakRequested = false
    private var currentLineNumber: Int?
    private var currentLocation: BASICBreakpointLocation?
    private var breakpoints: [BASICBreakpointLocation] = []
    private var ignoredBreakpointLocation: BASICBreakpointLocation?
    private var mode: BASICExecutionMode = .run

    /// Creates an execution control with no pending breakpoints or break request.
    public init() {}

    /// Clears pending break requests and the current source location.
    public func reset() {
        lock.lock()
        breakRequested = false
        currentLineNumber = nil
        currentLocation = nil
        lock.unlock()
    }

    /// Requests a cooperative break on the execution thread.
    public func requestBreak() {
        lock.lock()
        breakRequested = true
        lock.unlock()
    }

    /// Current BASIC display line number, if execution has started.
    public var lineNumber: Int? {
        lock.lock()
        defer { lock.unlock() }
        return currentLineNumber
    }

    /// Current precise breakpoint location, if execution has started.
    public var location: BASICBreakpointLocation? {
        lock.lock()
        defer { lock.unlock() }
        return currentLocation
    }

    /// Replaces the active breakpoint set.
    public func setBreakpoints(_ breakpoints: [BASICBreakpoint]) {
        lock.lock()
        self.breakpoints = breakpoints.filter(\.isEnabled).map(\.location)
        lock.unlock()
    }

    /// Sets the current debugger stepping mode.
    public func setMode(_ mode: BASICExecutionMode) {
        lock.lock()
        self.mode = mode
        lock.unlock()
    }

    /// Suppresses one breakpoint stop at a matching location.
    public func ignoreBreakpointOnce(at location: BASICBreakpointLocation?) {
        lock.lock()
        ignoredBreakpointLocation = location
        lock.unlock()
    }

    fileprivate func update(lineNumber: Int?, location: BASICBreakpointLocation) {
        lock.lock()
        currentLineNumber = lineNumber
        currentLocation = location
        lock.unlock()
    }

    fileprivate func checkBreak() throws {
        lock.lock()
        let shouldBreak = breakRequested
        let line = currentLineNumber
        var matchedBreakpoint: BASICBreakpointLocation?
        if let currentLocation, let breakpoint = breakpoints.first(where: { $0.matches(currentLocation) }) {
            if ignoredBreakpointLocation?.matches(currentLocation) == true {
                ignoredBreakpointLocation = nil
            } else {
                matchedBreakpoint = breakpoint
            }
        }
        lock.unlock()
        if shouldBreak {
            throw BASICError.breakRequested(line)
        }
        if let matchedBreakpoint {
            throw BASICError.breakpoint(matchedBreakpoint)
        }
    }

    fileprivate func shouldPauseAfterStep(callDepth: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch mode {
        case .run:
            return false
        case .stepInto:
            return true
        case .stepOver(let depth):
            return callDepth <= depth
        case .stepOut(let depth):
            return callDepth <= max(0, depth - 1)
        }
    }
}

/// Execution state for a logical BASIC task.
public enum BASICTaskState: String, Sendable {
    /// The task is queued and ready to run.
    case ready
    /// The task is currently executing.
    case running
    /// The task is paused at a debugger stop or future suspension point.
    case suspended
    /// The task reached normal completion.
    case completed
    /// The task stopped because cancellation or break was requested.
    case cancelled
    /// The task stopped with an error.
    case failed
}

/// Reason a logical BASIC task is suspended.
public enum BASICTaskSuspensionReason: Equatable, Sendable {
    /// The task stopped at a debugger boundary.
    case debugger
    /// The task is waiting for a host operation such as file, timer, or network work.
    case hostOperation(String)
    /// The task is waiting for another task to finish.
    case join(taskID: Int)
}

/// Immutable debugger-facing view of a logical BASIC task.
public struct BASICTaskSnapshot: Identifiable, Equatable, Sendable {
    /// Stable task identifier.
    public let id: Int
    /// Optional parent task identifier for future child tasks.
    public let parentID: Int?
    /// Human-readable task name.
    public let name: String
    /// Current task state.
    public let state: BASICTaskState
    /// Current suspension reason when the task is suspended.
    public let suspensionReason: BASICTaskSuspensionReason?
    /// Current source location, when execution has reached a statement.
    public let location: BASICBreakpointLocation?
    /// Whether cancellation has been requested.
    public let isCancellationRequested: Bool
    /// Number of cooperative yield boundaries reached by this task.
    public let yieldCount: Int
    /// Number of known child tasks parented by this task.
    public let childCount: Int
    /// Result value for completed tasks, when available.
    let resultValue: BASICValue?
    /// Optional error text for failed tasks.
    public let errorDescription: String?
}

/// Nonblocking join classification for a logical BASIC task.
public enum BASICTaskJoinState: Equatable, Sendable {
    /// No task with that id is known.
    case missing
    /// The task is not finished yet.
    case waiting
    /// The task reached normal completion.
    case completed
    /// The task was cancelled.
    case cancelled
    /// The task stopped with an error.
    case failed(String?)
}

/// Nonblocking await classification for a logical BASIC task.
enum BASICTaskAwaitState: Equatable, Sendable {
    /// No task with that id is known.
    case missing
    /// The task is not finished yet.
    case waiting
    /// The task completed with a BASIC value.
    case completed(BASICValue)
    /// The task was cancelled.
    case cancelled
    /// The task stopped with an error.
    case failed(String?)
}

/// Host-side work closure used by the async/thread runtime seed.
public typealias BASICTaskHostOperation = @Sendable () async throws -> Void

/// Host-side work closure that completes a logical task with a BASIC value.
typealias BASICTaskHostResultOperation = @Sendable () async throws -> BASICValue

/// Stable user/runtime handle for a logical BASIC task.
public struct BASICTaskHandle: Identifiable, Equatable, Sendable {
    /// Stable task identifier.
    public let id: Int
    /// Optional parent task identifier for future child tasks.
    public let parentID: Int?
    /// Human-readable task name.
    public let name: String

    /// Creates a task handle.
    public init(id: Int, parentID: Int? = nil, name: String) {
        self.id = id
        self.parentID = parentID
        self.name = name
    }
}

/// Logical BASIC execution unit used by the future thread/async runtime.
public final class BASICTask: @unchecked Sendable {
    private let lock = NSLock()
    private var currentState: BASICTaskState = .ready
    private var currentLocation: BASICBreakpointLocation?
    private var cancellationRequested = false
    private var yieldCountValue = 0
    private var suspensionReason: BASICTaskSuspensionReason?
    private var resultValue: BASICValue?
    private var errorDescription: String?

    /// Stable task identifier.
    public let id: Int
    /// Optional parent task identifier for future child tasks.
    public let parentID: Int?
    /// Human-readable task name.
    public let name: String

    /// Creates a logical BASIC task.
    public init(id: Int, parentID: Int? = nil, name: String = "Program") {
        self.id = id
        self.parentID = parentID
        self.name = name
    }

    /// Current task state.
    public var state: BASICTaskState {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    /// Current source location, when available.
    public var location: BASICBreakpointLocation? {
        lock.lock()
        defer { lock.unlock() }
        return currentLocation
    }

    /// Stable handle for addressing this task without exposing mutable internals.
    public var handle: BASICTaskHandle {
        BASICTaskHandle(id: id, parentID: parentID, name: name)
    }

    /// Requests cancellation at the next cooperative execution check.
    public func requestCancellation() {
        lock.lock()
        cancellationRequested = true
        lock.unlock()
    }

    /// Whether cancellation has been requested.
    public var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    /// Returns an immutable task snapshot.
    public func snapshot(childCount: Int = 0) -> BASICTaskSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return BASICTaskSnapshot(
            id: id,
            parentID: parentID,
            name: name,
            state: currentState,
            suspensionReason: suspensionReason,
            location: currentLocation,
            isCancellationRequested: cancellationRequested,
            yieldCount: yieldCountValue,
            childCount: childCount,
            resultValue: resultValue,
            errorDescription: errorDescription
        )
    }

    fileprivate func markRunning() {
        lock.lock()
        currentState = .running
        suspensionReason = nil
        resultValue = nil
        errorDescription = nil
        lock.unlock()
    }

    fileprivate func markReady() {
        lock.lock()
        currentState = .ready
        suspensionReason = nil
        resultValue = nil
        lock.unlock()
    }

    fileprivate func update(location: BASICBreakpointLocation) {
        lock.lock()
        currentLocation = location
        lock.unlock()
    }

    fileprivate func recordYield() {
        lock.lock()
        yieldCountValue += 1
        lock.unlock()
    }

    fileprivate func markSuspended(_ reason: BASICTaskSuspensionReason = .debugger) {
        lock.lock()
        currentState = .suspended
        suspensionReason = reason
        lock.unlock()
    }

    fileprivate func markCompleted(result: BASICValue? = nil) {
        lock.lock()
        currentState = .completed
        suspensionReason = nil
        resultValue = result
        lock.unlock()
    }

    fileprivate func markCancelled() {
        lock.lock()
        currentState = .cancelled
        suspensionReason = nil
        resultValue = nil
        lock.unlock()
    }

    fileprivate func markFailed(_ error: Error) {
        lock.lock()
        currentState = .failed
        suspensionReason = nil
        resultValue = nil
        errorDescription = String(describing: error)
        lock.unlock()
    }
}

/// Cooperative task registry and scheduler seed for BASIC execution.
public final class BASICTaskScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 1
    private var tasks: [Int: BASICTask] = [:]
    private var readyQueue: [Int] = []
    private var hostTasks: [Int: Task<Void, Never>] = [:]
    private var currentTaskID: Int?

    /// Creates an empty task scheduler.
    public init() {}

    /// Creates and queues a logical BASIC task.
    public func createTask(name: String = "Program", parentID: Int? = nil) -> BASICTask {
        lock.lock()
        defer { lock.unlock() }
        let task = BASICTask(id: nextID, parentID: parentID, name: name)
        nextID += 1
        tasks[task.id] = task
        readyQueue.append(task.id)
        return task
    }

    /// Returns immutable snapshots for all known tasks.
    public var snapshots: [BASICTaskSnapshot] {
        lock.lock()
        let ordered = tasks.values.sorted { $0.id < $1.id }
        let childCounts = Dictionary(grouping: tasks.values.compactMap(\.parentID), by: { $0 })
            .mapValues(\.count)
        lock.unlock()
        return ordered.map { $0.snapshot(childCount: childCounts[$0.id] ?? 0) }
    }

    /// Current running or suspended task, when one has been selected.
    public var currentTask: BASICTask? {
        lock.lock()
        defer { lock.unlock() }
        guard let currentTaskID else { return nil }
        return tasks[currentTaskID]
    }

    /// Stable handles for tasks queued to run.
    public var readyTaskHandles: [BASICTaskHandle] {
        lock.lock()
        let queuedIDs = readyQueue
        let queuedTasks = queuedIDs.compactMap { tasks[$0] }
        lock.unlock()
        return queuedTasks.map(\.handle)
    }

    /// Returns a stable handle for a known task id.
    public func handle(for id: Int) -> BASICTaskHandle? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[id]?.handle
    }

    /// Creates a child logical task and returns its stable handle.
    public func createChildTask(name: String, parentID: Int) -> BASICTaskHandle {
        createTask(name: name, parentID: parentID).handle
    }

    /// Returns the nonblocking join state for a task id.
    public func joinState(for id: Int) -> BASICTaskJoinState {
        lock.lock()
        let task = tasks[id]
        lock.unlock()
        guard let task else { return .missing }
        let snapshot = task.snapshot()
        if snapshot.isCancellationRequested {
            return .cancelled
        }
        switch snapshot.state {
        case .ready, .running, .suspended:
            return .waiting
        case .completed:
            return .completed
        case .cancelled:
            return .cancelled
        case .failed:
            return .failed(snapshot.errorDescription)
        }
    }

    /// Returns the nonblocking await state and result value for a task id.
    func awaitState(for id: Int) -> BASICTaskAwaitState {
        lock.lock()
        let task = tasks[id]
        lock.unlock()
        guard let task else { return .missing }
        let snapshot = task.snapshot()
        if snapshot.isCancellationRequested {
            return .cancelled
        }
        switch snapshot.state {
        case .ready, .running, .suspended:
            return .waiting
        case .completed:
            return .completed(snapshot.resultValue ?? .empty)
        case .cancelled:
            return .cancelled
        case .failed:
            return .failed(snapshot.errorDescription)
        }
    }

    /// Requests cooperative cancellation for a known task.
    @discardableResult
    public func requestCancellation(id: Int) -> Bool {
        lock.lock()
        let task = tasks[id]
        let hostTask = hostTasks[id]
        lock.unlock()
        guard let task else { return false }
        task.requestCancellation()
        hostTask?.cancel()
        return true
    }

    /// Starts a host-backed asynchronous operation represented as a logical BASIC task.
    public func startHostOperationTask(
        name: String,
        parentID: Int? = nil,
        operation: String,
        work: @escaping BASICTaskHostOperation
    ) -> BASICTaskHandle {
        startHostOperationTaskWithResult(name: name, parentID: parentID, operation: operation) {
            try await work()
            return .empty
        }
    }

    /// Starts a host-backed asynchronous operation that returns a BASIC value.
    func startHostOperationTaskWithResult(
        name: String,
        parentID: Int? = nil,
        operation: String,
        work: @escaping BASICTaskHostResultOperation
    ) -> BASICTaskHandle {
        let task = createTask(name: name, parentID: parentID)
        _ = suspendForHostOperation(id: task.id, operation: operation)
        let handle = task.handle
        let swiftTask = Task.detached { [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await work()
                try Task.checkCancellation()
                self?.finishHostOperationTask(id: handle.id, result: result, error: nil)
            } catch is CancellationError {
                self?.finishHostOperationTask(id: handle.id, cancelled: true, error: nil)
            } catch {
                self?.finishHostOperationTask(id: handle.id, error: error)
            }
        }
        lock.lock()
        hostTasks[handle.id] = swiftTask
        lock.unlock()
        return handle
    }

    /// Suspends a task while a host operation runs outside the interpreter.
    @discardableResult
    public func suspendForHostOperation(id: Int, operation: String) -> Bool {
        lock.lock()
        let task = tasks[id]
        readyQueue.removeAll { $0 == id }
        lock.unlock()
        guard let task else { return false }
        task.markSuspended(.hostOperation(operation))
        return true
    }

    /// Moves a suspended task back to the ready queue after its wait condition is satisfied.
    @discardableResult
    public func resumeTask(id: Int) -> Bool {
        lock.lock()
        guard let task = tasks[id] else {
            lock.unlock()
            return false
        }
        let isAlreadyQueued = readyQueue.contains(id)
        lock.unlock()

        let snapshot = task.snapshot()
        guard snapshot.state == .suspended, !snapshot.isCancellationRequested else {
            return false
        }

        task.markReady()
        lock.lock()
        if !isAlreadyQueued {
            readyQueue.append(id)
        }
        lock.unlock()
        return true
    }

    fileprivate func markRunning(_ task: BASICTask) {
        lock.lock()
        currentTaskID = task.id
        readyQueue.removeAll { $0 == task.id }
        lock.unlock()
        task.markRunning()
    }

    fileprivate func markSuspended(_ task: BASICTask, reason: BASICTaskSuspensionReason = .debugger) {
        task.markSuspended(reason)
    }

    fileprivate func markCompleted(_ task: BASICTask) {
        task.markCompleted()
    }

    fileprivate func markCancelled(_ task: BASICTask) {
        task.markCancelled()
    }

    fileprivate func markFailed(_ task: BASICTask, error: Error) {
        task.markFailed(error)
    }

    private func finishHostOperationTask(
        id: Int,
        cancelled: Bool = false,
        result: BASICValue? = nil,
        error: Error?
    ) {
        lock.lock()
        let task = tasks[id]
        hostTasks[id] = nil
        lock.unlock()
        guard let task else { return }
        if cancelled || task.isCancellationRequested {
            task.markCancelled()
        } else if let error {
            task.markFailed(error)
        } else {
            task.markCompleted(result: result)
        }
    }
}

/// Precise debugger location for breakpoints and execution state.
public struct BASICBreakpointLocation: Hashable, Sendable {
    /// Optional BASIC source file path.
    public var fileName: String?
    /// One-based source line number.
    public var lineNumber: Int
    /// Zero-based statement index within a colon-separated line.
    public var statementNumber: Int

    /// Creates a breakpoint location.
    public init(fileName: String? = nil, lineNumber: Int, statementNumber: Int = 0) {
        self.fileName = fileName
        self.lineNumber = lineNumber
        self.statementNumber = statementNumber
    }

    fileprivate func matches(_ currentLocation: BASICBreakpointLocation) -> Bool {
        let sameFile = fileName == nil
            || currentLocation.fileName == nil
            || fileName == currentLocation.fileName
        let sameLine = lineNumber == currentLocation.lineNumber
        let sameStatement = statementNumber == currentLocation.statementNumber
            || statementNumber == 0
        return sameFile && sameLine && sameStatement
    }
}

/// User-configurable breakpoint.
public struct BASICBreakpoint: Identifiable, Hashable, Sendable {
    /// Stable breakpoint identity.
    public var id: UUID
    /// Source location where the breakpoint should stop.
    public var location: BASICBreakpointLocation
    /// Whether the breakpoint participates in execution.
    public var isEnabled: Bool

    /// Creates a breakpoint at a location.
    public init(id: UUID = UUID(), location: BASICBreakpointLocation, isEnabled: Bool = true) {
        self.id = id
        self.location = location
        self.isEnabled = isEnabled
    }
}

/// Graphics screen configuration requested by the BASIC SCREEN statement.
public struct BASICScreenMode: Equatable, Sendable {
    /// BASIC screen mode number.
    public let number: Int
    /// Pixel width for graphics operations.
    public let width: Int
    /// Pixel height for graphics operations.
    public let height: Int
    /// Number of supported colors.
    public let colorCount: Int

    /// Creates a screen mode description.
    public init(number: Int, width: Int, height: Int, colorCount: Int) {
        self.number = number
        self.width = width
        self.height = height
        self.colorCount = colorCount
    }
}

/// Host interface for pixel graphics used by BASICStudio.
public protocol BASICGraphicsHost: BASICHost {
    /// Selects a graphics screen mode.
    func setScreenMode(_ mode: BASICScreenMode)
    /// Sets the current graphics drawing color.
    func setGraphicsColor(_ color: Int)
    /// Clears the graphics layer, optionally with a color.
    func clearGraphics(color: Int?)
    /// Sets one graphics pixel.
    func setPixel(x: Int, y: Int, color: Int)
    /// Reads one graphics pixel.
    func getPixel(x: Int, y: Int) -> Int
    /// Draws one line segment.
    func drawLine(x1: Int, y1: Int, x2: Int, y2: Int, color: Int)
}

public extension BASICHost {
    /// Convenience default that adapts `print(_:terminator:)` to `printLine(_:)`.
    func print(_ text: String, terminator: String) {
        printLine(text + terminator.trimmingCharacters(in: .newlines))
    }
}

/// Mutable BASIC source program, including numbered and unnumbered lines.
public final class BASICProgram: @unchecked Sendable {
    private var lines: [ProgramLine] = []

    /// Creates an empty program.
    public init() {}

    /// Whether the program contains no source lines.
    public var isEmpty: Bool { lines.isEmpty }

    /// Adds, replaces, or deletes a numbered source line.
    public func setLine(number: Int, source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            lines.removeAll { $0.number == number }
        } else {
            if let index = lines.firstIndex(where: { $0.number == number }) {
                lines[index].source = source
            } else {
                lines.append(ProgramLine(number: number, source: source, fileName: nil, sourceLineNumber: nil, isImported: false))
            }
            lines.sort { ($0.number ?? Int.max) < ($1.number ?? Int.max) }
        }
    }

    /// Replaces the program with line-numbered or line-number-free source.
    public func loadSource(_ source: String, fileName: String? = nil) {
        lines = Self.parseLines(from: source, fileName: fileName, isImported: false)
    }

    /// Removes all program lines.
    public func clear() {
        lines.removeAll()
    }

    /// Returns a LIST-style rendering of the current program.
    public func listing(begin: Int? = nil, end: Int? = nil, colorized: Bool = false) -> String {
        orderedLines.filter { line in
            guard begin != nil || end != nil else { return true }
            guard let number = line.number else { return false }
            if let begin, number < begin { return false }
            if let end, number > end { return false }
            return true
        }.map { line in
            let source = colorized ? Self.colorizedListingLine(line.source) : line.source
            if let number = line.number {
                return "\(colorized ? Self.ansiNumber : "")\(number)\(colorized ? Self.ansiReset : "") \(source)"
            }
            return source
        }.joined(separator: "\n")
    }

    /// Program lines in execution order with source metadata.
    public var orderedLines: [(number: Int?, source: String, fileName: String?, sourceLineNumber: Int?, isImported: Bool)] {
        lines.map { ($0.number, $0.source, $0.fileName, $0.sourceLineNumber, $0.isImported) }
    }

    fileprivate static func importedLines(from source: String, fileName: String) -> [ProgramLine] {
        parseLines(from: source, fileName: fileName, isImported: true)
    }

    private static func splitNumberedLine(_ source: String) -> (number: Int, source: String)? {
        var digits = ""
        var index = source.startIndex
        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
        while index < source.endIndex, source[index].isNumber {
            digits.append(source[index])
            index = source.index(after: index)
        }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        if index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
        let rest = String(source[index...])
        return (number, rest)
    }

    private static func parseLines(from source: String, fileName: String?, isImported: Bool) -> [ProgramLine] {
        var sourceLines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var sourceLineOffset = 0
        if let firstLine = sourceLines.first,
           firstLine.trimmingCharacters(in: .whitespaces).hasPrefix("#!") {
            sourceLines.removeFirst()
            sourceLineOffset = 1
        }

        let lineRecords = joinContinuationLines(
            sourceLines.enumerated().map { (lineNumber: $0.offset + 1 + sourceLineOffset, source: $0.element) }
        )

        return lineRecords
            .filter { !$0.source.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { record in
                if let numbered = splitNumberedLine(record.source) {
                    return ProgramLine(number: numbered.number, source: numbered.source, fileName: fileName, sourceLineNumber: record.lineNumber, isImported: isImported)
                }
                return ProgramLine(number: nil, source: record.source, fileName: fileName, sourceLineNumber: record.lineNumber, isImported: isImported)
            }
    }

    private static func joinContinuationLines(_ sourceLines: [(lineNumber: Int, source: String)]) -> [(lineNumber: Int, source: String)] {
        var joinedLines: [(lineNumber: Int, source: String)] = []
        var pending: (lineNumber: Int, source: String)?

        for sourceLine in sourceLines {
            let line = sourceLine.source
            let combined = [pending?.source, line]
                .compactMap { $0 }
                .joined(separator: pending == nil ? "" : " ")

            if let continued = removingTrailingContinuation(from: combined) {
                pending = (lineNumber: pending?.lineNumber ?? sourceLine.lineNumber, source: continued)
            } else {
                joinedLines.append((lineNumber: pending?.lineNumber ?? sourceLine.lineNumber, source: combined))
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

    private static let ansiReset = "\u{001B}[0m"
    private static let ansiKeyword = "\u{001B}[38;5;39m"
    private static let ansiString = "\u{001B}[38;5;215m"
    private static let ansiComment = "\u{001B}[38;5;71m"
    private static let ansiNumber = "\u{001B}[38;5;141m"

    private static let listingKeywords: Set<String> = [
        "AS", "ASYNC", "AWAIT", "CASE", "CLASS", "CLOSE", "COLOR", "DATA", "DIM", "ELSE", "ELSEIF",
        "END", "EXIT", "FOR", "FUNCTION", "GLOBAL", "GOSUB", "GOTO", "IF", "IMPORT", "INPUT", "INTERFACE",
        "LET", "LINE", "LIST", "LOCAL", "LOG", "MODULE", "NEXT", "ON", "OPEN", "OPTION", "PRINT",
        "PRIVATE", "PROTECTED", "PUBLIC", "READ", "REM", "RESTORE", "RETURN", "RUN", "SAVE", "SELECT",
        "STEP", "SYSTEM", "THEN", "TO", "TYPE", "USING", "VIRTUAL", "VOID", "YIELD"
    ]

    private static func colorizedListingLine(_ source: String) -> String {
        var output = ""
        var index = source.startIndex
        var atLineStart = true
        var previousWasIdentifier = false

        func appendComment(from commentStart: String.Index) {
            output += ansiComment + source[commentStart...] + ansiReset
            index = source.endIndex
        }

        while index < source.endIndex {
            let character = source[index]
            if character.isWhitespace {
                output.append(character)
                atLineStart = atLineStart && character != "\t" ? atLineStart : false
                index = source.index(after: index)
                previousWasIdentifier = false
                continue
            }
            if atLineStart && character == "#" {
                appendComment(from: index)
                break
            }
            if character == "'" {
                appendComment(from: index)
                break
            }
            if character == "/", source.index(after: index) < source.endIndex, source[source.index(after: index)] == "/" {
                appendComment(from: index)
                break
            }
            if character == "\"" {
                let start = index
                index = source.index(after: index)
                while index < source.endIndex {
                    let current = source[index]
                    index = source.index(after: index)
                    if current == "\"" { break }
                }
                output += ansiString + source[start..<index] + ansiReset
                atLineStart = false
                previousWasIdentifier = false
                continue
            }
            if character.isNumber {
                let start = index
                index = source.index(after: index)
                while index < source.endIndex, source[index].isNumber || source[index] == "." {
                    index = source.index(after: index)
                }
                output += ansiNumber + source[start..<index] + ansiReset
                atLineStart = false
                previousWasIdentifier = false
                continue
            }
            if character.isLetter {
                let start = index
                index = source.index(after: index)
                while index < source.endIndex, source[index].isLetter || source[index].isNumber || source[index] == "$" || source[index] == "%" || source[index] == "#" {
                    index = source.index(after: index)
                }
                let word = String(source[start..<index])
                let uppercased = word.uppercased()
                if uppercased == "REM" && !previousWasIdentifier {
                    output += ansiKeyword + word + ansiReset
                    if index < source.endIndex {
                        output += ansiComment + source[index...] + ansiReset
                    }
                    break
                }
                if listingKeywords.contains(uppercased) {
                    output += ansiKeyword + word + ansiReset
                } else {
                    output += word
                }
                atLineStart = false
                previousWasIdentifier = true
                continue
            }
            output.append(character)
            atLineStart = false
            previousWasIdentifier = false
            index = source.index(after: index)
        }
        return output + ansiReset
    }
}

private struct ProgramLine {
    let number: Int?
    var source: String
    var fileName: String?
    var sourceLineNumber: Int?
    var isImported: Bool
}

private final class BASICFileState {
    var lastFilePath: String?
}

/// Shared prompt-template persistence used by BASICStudio and BASICShell.
public enum BASICPromptTemplateStore {
    private struct Payload: Codable {
        var promptTemplate: String
    }

    private static let fileName = "PromptSettings.json"

    /// Location of the shared prompt settings file.
    public static var settingsURL: URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("AIBasic", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Loads the shared prompt template, falling back to the provided default.
    public static func load(default defaultTemplate: String) -> String {
        guard let data = try? Data(contentsOf: settingsURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.promptTemplate.isEmpty else {
            return defaultTemplate
        }
        return payload.promptTemplate
    }

    /// Saves the shared prompt template for all AIBasic hosts.
    public static func save(_ promptTemplate: String) {
        let url = settingsURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Payload(promptTemplate: promptTemplate))
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Unable to save AIBasic prompt settings: \(error.localizedDescription)")
        }
    }
}

/// High-level REPL/session facade for editing, running, and debugging BASIC programs.
public final class BASICSession: @unchecked Sendable {
    /// Default graphical prompt template used by BASICStudio.
    public static let defaultPromptTemplate = "\u{001B}[38;5;16;48;5;250m  \u{001B}[38;5;250;48;5;99m\u{001B}[38;5;15;48;5;99m  ${currentdir} \u{001B}[38;5;99;48;5;142m\u{001B}[38;5;16;48;5;142m git  ${gitstatus} \u{001B}[38;5;142;48;5;142m\u{001B}[38;5;16;48;5;142m !1 \u{001B}[38;5;142;48;5;40m\u{001B}[38;5;16;48;5;40m Ready \u{001B}[38;5;40;49m\u{001B}[0m "
    /// Plain text prompt template for hosts without powerline glyph support.
    public static let plainPromptTemplate = "${user}:${currentdir} ${gitstatus}> "
    /// Classic READY prompt template.
    public static let shellPromptTemplate = "READY%nl> "
    /// Legacy default prompt string.
    public static let defaultPrompt = "\(NSUserName()):~ > "
    /// Nerd-font prompt template for shell-style hosts.
    public static let nerdFontPromptTemplate = "    %cwd %gitSegment "

    /// Editable program associated with this session.
    public let program = BASICProgram()
    /// Template used to render prompts.
    public var promptTemplate: String
    /// Current rendered prompt.
    public var prompt: String {
        renderedPrompt()
    }

    private let host: BASICHost
    private let runtime = BASICRuntime()
    private let fileState = BASICFileState()
    private let taskScheduler = BASICTaskScheduler()
    private var activeInterpreter: BASICInterpreter?

    /// Creates a session bound to a host.
    public init(host: BASICHost, promptTemplate: String = BASICSession.defaultPromptTemplate) {
        self.host = host
        self.promptTemplate = promptTemplate
    }

    /// Submits one console line, returning false when the caller should exit.
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
                    program.loadSource(try fileHost.loadTextFile(path: path), fileName: path)
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
            if let cdCommand = try Self.cdPath(from: trimmed) {
                guard let fileHost = host as? BASICFileHost else {
                    throw BASICError.runtime("CD is not supported by this host")
                }
                if let path = cdCommand {
                    do {
                        try fileHost.changeDirectory(path: path)
                    } catch let error as BASICError {
                        throw error
                    } catch {
                        throw BASICError.runtime("Could not change directory to \(path): \(error.localizedDescription)")
                    }
                } else {
                    host.printLine(try fileHost.currentDirectoryPath())
                }
                return true
            }
            if let promptCommand = try Self.promptString(from: trimmed) {
                if let promptCommand {
                    promptTemplate = promptCommand
                } else {
                    host.printLine(promptTemplate)
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

            if let path = try Self.runPath(from: trimmed) {
                guard let fileHost = host as? BASICFileHost else {
                    throw BASICError.runtime("RUN from file is not supported by this host")
                }
                do {
                    program.loadSource(try fileHost.loadTextFile(path: path), fileName: path)
                    fileState.lastFilePath = path
                    let diagnostics = self.diagnostics()
                    if diagnostics.isEmpty {
                        try runProgram()
                    } else {
                        printDiagnostics()
                    }
                } catch let error as BASICError {
                    throw error
                } catch {
                    throw BASICError.runtime("Could not run \(path): \(error.localizedDescription)")
                }
                return true
            }

            if let startLine = try Self.runStartLine(from: trimmed) {
                try runProgram(startLine: startLine)
                return true
            }

            if let listCommand = try Self.listCommand(from: trimmed) {
                let colored = (host as? BASICListingStyleHost)?.usesColoredListing == true
                let listing = program.listing(begin: listCommand.begin, end: listCommand.end, colorized: colored)
                if !listing.isEmpty { host.printLine(listing) }
                if listCommand.check {
                    printDiagnostics()
                }
                return true
            }

            switch trimmed.uppercased() {
            case "NEW":
                program.clear()
                runtime.clearAll()
                fileState.lastFilePath = nil
            case "CLEAR":
                runtime.clearAll()
            case "HELP":
                host.printLine("Commands: RUN, LIST, LOAD, SAVE, CD, PROMPT, FILES, SYSTEM, NEW, CLEAR, HELP, QUIT")
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

    /// Starts the program from the beginning or an optional numbered line.
    public func runProgram(startLine: Int? = nil, executionControl: BASICExecutionControl? = nil) throws {
        runtime.resetForRun()
        let task = taskScheduler.createTask(name: "Program")
        let interpreter = BASICInterpreter(
            program: program,
            host: host,
            runtime: runtime,
            fileState: fileState,
            executionControl: executionControl,
            task: task,
            taskScheduler: taskScheduler
        )
        activeInterpreter = interpreter
        do {
            try interpreter.run(startLine: startLine)
            activeInterpreter = nil
        } catch let error as BASICError {
            switch error {
            case .breakRequested, .breakpoint, .stepComplete:
                break
            default:
                activeInterpreter = nil
            }
            throw error
        } catch {
            activeInterpreter = nil
            throw error
        }
    }

    /// Continues an interrupted program, or runs from the start when no program is paused.
    public func continueProgram(executionControl: BASICExecutionControl? = nil) throws {
        guard let activeInterpreter else {
            try runProgram(executionControl: executionControl)
            return
        }
        activeInterpreter.setExecutionControl(executionControl)
        do {
            try activeInterpreter.continueExecution()
            self.activeInterpreter = nil
        } catch let error as BASICError {
            switch error {
            case .breakRequested, .breakpoint, .stepComplete:
                break
            default:
                self.activeInterpreter = nil
            }
            throw error
        } catch {
            self.activeInterpreter = nil
            throw error
        }
    }

    /// Local variables visible in the active debugger frame.
    public var debugLocalVariables: [BASICVariableSnapshot] {
        activeInterpreter?.debugLocalVariables ?? runtime.localSnapshots()
    }

    /// Global variables visible to the program.
    public var debugGlobalVariables: [BASICVariableSnapshot] {
        activeInterpreter?.debugGlobalVariables ?? runtime.globalSnapshots()
    }

    /// Parses and validates the current program without running it.
    public func diagnostics() -> [BASICDiagnostic] {
        BASICInterpreter(program: program, host: host, runtime: runtime, fileState: fileState).diagnostics()
    }

    private func printDiagnostics() {
        let diagnostics = self.diagnostics()
        guard !diagnostics.isEmpty else {
            host.printLine("No diagnostics.")
            return
        }

        host.printLine("Diagnostics:")
        let indexedLines = program.orderedLines.enumerated().map { index, line in
            (
                sourceLineNumber: line.sourceLineNumber ?? index + 1,
                displayLineNumber: line.number ?? line.sourceLineNumber ?? index + 1,
                source: line.number.map { "\($0) \(line.source)" } ?? line.source
            )
        }
        for diagnostic in diagnostics {
            let source = diagnostic.fileName == nil
                ? indexedLines.first { $0.sourceLineNumber == diagnostic.lineNumber }
                : nil
            let displayLineNumber = source?.displayLineNumber ?? diagnostic.lineNumber
            let filePrefix = diagnostic.fileName.map { "\($0):" } ?? ""
            host.printLine("\(filePrefix)Line \(displayLineNumber), column \(diagnostic.column + 1): \(diagnostic.message)")
            if let sourceText = source?.source {
                host.printLine(sourceText)
                host.printLine(String(repeating: " ", count: max(0, diagnostic.column)) + "^")
            }
        }
    }

    /// Current debugger call stack.
    public var debugCallStack: [BASICCallStackFrame] {
        activeInterpreter?.debugCallStack ?? []
    }

    /// Logical BASIC task snapshots known to this session.
    public var debugTasks: [BASICTaskSnapshot] {
        taskScheduler.snapshots
    }

    /// Handles for logical BASIC tasks queued to run.
    public var readyTaskHandles: [BASICTaskHandle] {
        taskScheduler.readyTaskHandles
    }

    /// Handle for the current logical task, when one is selected.
    public var currentTaskHandle: BASICTaskHandle? {
        taskScheduler.currentTask?.handle
    }

    /// Creates a child logical task under an existing or current parent task.
    public func createChildTask(name: String, parentID: Int? = nil) -> BASICTaskHandle? {
        let resolvedParentID: Int?
        if let parentID {
            resolvedParentID = parentID
        } else {
            resolvedParentID = currentTaskHandle?.id
        }
        guard let resolvedParentID else { return nil }
        return taskScheduler.createChildTask(name: name, parentID: resolvedParentID)
    }

    /// Returns a nonblocking join classification for a logical task.
    public func taskJoinState(id: Int) -> BASICTaskJoinState {
        taskScheduler.joinState(for: id)
    }

    /// Returns the nonblocking await classification and result for a logical task.
    func taskAwaitState(id: Int) -> BASICTaskAwaitState {
        taskScheduler.awaitState(for: id)
    }

    /// Suspends a logical task while a host operation runs outside BASIC.
    @discardableResult
    public func suspendTaskForHostOperation(id: Int, operation: String) -> Bool {
        taskScheduler.suspendForHostOperation(id: id, operation: operation)
    }

    /// Resumes a suspended logical task after its wait condition is satisfied.
    @discardableResult
    public func resumeTask(id: Int) -> Bool {
        taskScheduler.resumeTask(id: id)
    }

    /// Starts host async work represented as a logical BASIC child task.
    public func startHostOperationTask(
        name: String,
        parentID: Int? = nil,
        operation: String,
        work: @escaping BASICTaskHostOperation
    ) -> BASICTaskHandle {
        let resolvedParentID = parentID ?? currentTaskHandle?.id
        return taskScheduler.startHostOperationTask(
            name: name,
            parentID: resolvedParentID,
            operation: operation,
            work: work
        )
    }

    /// Starts host async work that completes with a BASIC value.
    func startHostOperationTaskWithResult(
        name: String,
        parentID: Int? = nil,
        operation: String,
        work: @escaping BASICTaskHostResultOperation
    ) -> BASICTaskHandle {
        let resolvedParentID = parentID ?? currentTaskHandle?.id
        return taskScheduler.startHostOperationTaskWithResult(
            name: name,
            parentID: resolvedParentID,
            operation: operation,
            work: work
        )
    }

    /// Requests cooperative cancellation for a logical task.
    @discardableResult
    public func requestTaskCancellation(id: Int) -> Bool {
        taskScheduler.requestCancellation(id: id)
    }

    /// Local variables for each debugger stack frame.
    public var debugFrameLocalVariables: [[BASICVariableSnapshot]] {
        activeInterpreter?.debugFrameLocalVariables ?? []
    }

    /// Current debugger call depth.
    public var debugCallDepth: Int {
        activeInterpreter?.debugCallDepth ?? 0
    }

    /// Returns a user-facing pause message for break and step errors.
    public func debugPauseDescription(for error: BASICError) -> String {
        let baseDescription: String
        switch error {
        case .breakRequested(let line):
            if let line {
                baseDescription = "Break at \(line)"
            } else {
                baseDescription = "Break at unnumbered line"
            }
        case .breakpoint(let location), .stepComplete(let location):
            baseDescription = "Break at \(location.lineNumber)"
        default:
            return error.description
        }

        guard let frame = debugCallStack.first, frame.kind != "Program" else {
            return baseDescription
        }
        return "\(baseDescription) in \(frame.kind) \(frame.name)"
    }

    private func immediateProgram(for source: String) -> BASICProgram {
        let program = BASICProgram()
        program.loadSource(source)
        return program
    }

    private static func splitNumberedLine(_ source: String) -> (number: Int, source: String)? {
        var digits = ""
        var index = source.startIndex
        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
        while index < source.endIndex, source[index].isNumber {
            digits.append(source[index])
            index = source.index(after: index)
        }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        if index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
        let rest = String(source[index...])
        return (number, rest)
    }

    private static func loadPath(from source: String) throws -> String? {
        try commandPath(keyword: "LOAD", from: source, requiresPath: true)
    }

    private static func runPath(from source: String) throws -> String? {
        guard keywordPrefix("RUN", matches: source) else { return nil }
        let start = source.index(source.startIndex, offsetBy: 3)
        let rest = source[start...].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("\"") else { return nil }
        return try commandPath(keyword: "RUN", from: source, requiresPath: true)
    }

    private static func savePath(from source: String) throws -> String?? {
        guard keywordPrefix("SAVE", matches: source) else { return nil }
        return try commandPath(keyword: "SAVE", from: source, requiresPath: false)
    }

    private static func cdPath(from source: String) throws -> String?? {
        guard keywordPrefix("CD", matches: source) else { return nil }
        return try commandPath(keyword: "CD", from: source, requiresPath: false)
    }

    private static func promptString(from source: String) throws -> String?? {
        guard keywordPrefix("PROMPT", matches: source) else { return nil }
        return try commandPath(keyword: "PROMPT", from: source, requiresPath: false)
    }

    private struct ListCommand {
        var begin: Int?
        var end: Int?
        var check = false
    }

    private static func listCommand(from source: String) throws -> ListCommand? {
        guard keywordPrefix("LIST", matches: source) else { return nil }
        let start = source.index(source.startIndex, offsetBy: 4)
        var rest = source[start...].trimmingCharacters(in: .whitespaces)
        var command = ListCommand()

        if rest.uppercased().hasSuffix("CHECK") {
            let checkStart = rest.index(rest.endIndex, offsetBy: -5)
            let beforeCheck = rest[..<checkStart]
            if beforeCheck.isEmpty || beforeCheck.last?.isWhitespace == true {
                command.check = true
                rest = beforeCheck.trimmingCharacters(in: .whitespaces)
            }
        }

        guard !rest.isEmpty else { return command }
        if let dash = rest.firstIndex(of: "-") {
            let lower = rest[..<dash].trimmingCharacters(in: .whitespaces)
            let upper = rest[rest.index(after: dash)...].trimmingCharacters(in: .whitespaces)
            if !lower.isEmpty {
                guard let begin = Int(lower) else { throw BASICError.syntax("Expected beginning line number in LIST") }
                command.begin = begin
            }
            if !upper.isEmpty {
                guard let end = Int(upper) else { throw BASICError.syntax("Expected ending line number in LIST") }
                command.end = end
            }
            return command
        }

        guard let line = Int(rest) else { throw BASICError.syntax("Expected line range after LIST") }
        command.begin = line
        command.end = line
        return command
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

    private func renderedPrompt() -> String {
        let cwd = currentWorkingDirectoryForPrompt()
        var rendered = promptTemplate
        rendered = rendered.replacingOccurrences(of: "${currentdir}", with: abbreviatedPath(cwd))
        rendered = rendered.replacingOccurrences(of: "${gitstatus}", with: gitPrompt(for: cwd))
        rendered = rendered.replacingOccurrences(of: "${user}", with: NSUserName())
        rendered = rendered.replacingOccurrences(of: "%cwd", with: abbreviatedPath(cwd))
        rendered = rendered.replacingOccurrences(of: "%gitSegment", with: gitSegment(for: cwd))
        rendered = rendered.replacingOccurrences(of: "%git", with: gitPrompt(for: cwd))
        rendered = rendered.replacingOccurrences(of: "%nl", with: "\n")
        rendered = rendered.replacingOccurrences(of: "%%", with: "%")
        return rendered
    }

    private func currentWorkingDirectoryForPrompt() -> String {
        guard let fileHost = host as? BASICFileHost,
              let path = try? fileHost.currentDirectoryPath() else {
            return FileManager.default.currentDirectoryPath
        }
        return path
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func gitSegment(for path: String) -> String {
        let git = gitPrompt(for: path)
        guard !git.isEmpty else { return "" }
        return "   \(git) "
    }

    private func gitPrompt(for path: String) -> String {
        guard let branch = Self.gitOutput(arguments: ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !branch.isEmpty,
              branch != "HEAD" else { return "" }

        let status = Self.gitOutput(arguments: ["-C", path, "status", "--porcelain=v2", "--branch"]) ?? ""
        var suffix = ""
        for line in status.split(separator: "\n") where line.hasPrefix("# branch.ab ") {
            let pieces = line.split(separator: " ")
            for piece in pieces {
                if piece.hasPrefix("+"), piece.count > 1, piece != "+0" {
                    suffix += " ⇡\(piece.dropFirst())"
                } else if piece.hasPrefix("-"), piece.count > 1, piece != "-0" {
                    suffix += " ⇣\(piece.dropFirst())"
                }
            }
        }
        return branch + suffix
    }

    private static func gitOutput(arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Low-level interpreter for a prepared `BASICProgram`.
public final class BASICInterpreter {
    private let program: BASICProgram
    private weak var host: BASICHost?
    private let runtime: BASICRuntime
    private let fileState: BASICFileState
    private var executionControl: BASICExecutionControl?
    private let task: BASICTask?
    private weak var taskScheduler: BASICTaskScheduler?
    private var gosubStack: [GosubFrame] = []
    private var forStack: [ForFrame] = []
    private var functionStack: [FunctionFrame] = []
    private var functionDefinitions: [String: FunctionDefinition] = [:]
    private var recordDefinitions: [String: BASICRecordDefinition] = [:]
    private var interfaceDefinitions: [String: BASICInterfaceDefinition] = [:]
    private var classDefinitions: [String: BASICClassDefinition] = [:]
    private var legacyFiles: [Int: BASICOpenFile] = [:]
    private var lineIndexByNumber: [Int: Int] = [:]
    private var lineIndexByLabel: [String: Int] = [:]
    private var parsedLines: [ParsedLine] = []
    private var outputColumn = 0
    private var pausedDebugCallStack: [BASICCallStackFrame]?
    private var pausedDebugLocalVariables: [BASICVariableSnapshot]?
    private var pausedDebugFrameLocalVariables: [[BASICVariableSnapshot]]?
    private var pausedDebugGlobalVariables: [BASICVariableSnapshot]?
    private var pausedDebugCallDepth: Int?
    private var dataValues: [BASICValue] = []
    private var dataIndex = 0
    private var errorHandlerTarget: BranchTarget?
    private var isHandlingError = false
    private var lastErrorNumber = 0
    private var lastErrorLine = 0
    private var lastErrorMessage = ""
    private var errorResumePC: Int?
    private var errorResumeNextPC: Int?
    private var pc = 0
    private var isPrepared = false
    private var currentSourceFileName: String?
    private var currentLogModuleOverride: String?

    /// Creates an interpreter with fresh runtime state.
    public convenience init(program: BASICProgram, host: BASICHost) {
        self.init(program: program, host: host, runtime: BASICRuntime(), fileState: BASICFileState(), executionControl: nil, task: nil, taskScheduler: nil)
    }

    fileprivate init(
        program: BASICProgram,
        host: BASICHost,
        runtime: BASICRuntime,
        fileState: BASICFileState = BASICFileState(),
        executionControl: BASICExecutionControl? = nil,
        task: BASICTask? = nil,
        taskScheduler: BASICTaskScheduler? = nil
    ) {
        self.program = program
        self.host = host
        self.runtime = runtime
        self.fileState = fileState
        self.executionControl = executionControl
        self.task = task
        self.taskScheduler = taskScheduler
    }

    /// Starts execution, optionally from a numbered line.
    public func run(startLine: Int? = nil) throws {
        gosubStack.removeAll()
        forStack.removeAll()
        functionStack.removeAll()
        legacyFiles.removeAll()
        resetErrorTrap()
        outputColumn = 0
        try prepare(startLine: startLine)
        try continueExecution()
    }

    fileprivate func setExecutionControl(_ executionControl: BASICExecutionControl?) {
        self.executionControl = executionControl
    }

    /// Parses and validates the interpreter program without running it.
    public func diagnostics() -> [BASICDiagnostic] {
        var diagnostics: [BASICDiagnostic] = []
        let rootLines = program.orderedLines

        for (index, line) in rootLines.enumerated() {
            do {
                var parser = try Parser(source: line.source)
                _ = try parser.parseStatement()
            } catch let error as BASICError {
                diagnostics.append(
                    diagnostic(
                        for: error,
                        fileName: line.fileName,
                        sourceLineNumber: line.sourceLineNumber ?? index + 1,
                        fallbackColumn: 0
                    )
                )
            } catch {
                diagnostics.append(
                    BASICDiagnostic(
                        fileName: line.fileName,
                        lineNumber: line.sourceLineNumber ?? index + 1,
                        column: 0,
                        message: "Unexpected error: \(error)"
                    )
                )
            }
        }

        guard diagnostics.isEmpty else { return diagnostics }

        do {
            let sourceLines = try expandedProgramLines()
            var parsed: [ParsedLine] = []
            for (index, line) in sourceLines.enumerated() {
                do {
                    var parser = try Parser(source: line.source)
                    let statement = try parser.parseStatement()
                    parsed += ParsedLine.flatten(
                        number: line.number,
                        fileName: line.fileName,
                        sourceLineNumber: line.sourceLineNumber ?? index + 1,
                        isImported: line.isImported,
                        statement: statement
                    )
                } catch let error as BASICError {
                    diagnostics.append(
                        diagnostic(
                            for: error,
                            fileName: line.fileName,
                            sourceLineNumber: line.sourceLineNumber ?? index + 1,
                            fallbackColumn: 0
                        )
                    )
                } catch {
                    diagnostics.append(
                        BASICDiagnostic(
                            fileName: line.fileName,
                            lineNumber: line.sourceLineNumber ?? index + 1,
                            column: 0,
                            message: "Unexpected error: \(error)"
                        )
                    )
                }
            }
            guard diagnostics.isEmpty else { return diagnostics }

            do {
                recordDefinitions = try collectRecords(in: parsed)
                runtime.recordDefinitions = recordDefinitions
                interfaceDefinitions = try collectInterfaces(in: parsed)
                runtime.interfaceDefinitions = interfaceDefinitions
                classDefinitions = try collectClasses(in: parsed)
                try validateInterfaceInheritance()
                try validateClassInheritance()
                try validateClassInterfaces()
                _ = try collectFunctions(in: parsed)
            } catch let error as BASICError {
                diagnostics.append(diagnostic(for: error, parsed: parsed))
            } catch {
                diagnostics.append(BASICDiagnostic(lineNumber: 1, column: 0, message: "Unexpected error: \(error)"))
            }

            return diagnostics
        } catch let error as BASICError {
            return [diagnostic(for: error, sourceLineNumber: 1, fallbackColumn: 0)]
        } catch {
            return [BASICDiagnostic(lineNumber: 1, column: 0, message: "Unexpected error: \(error)")]
        }
    }

    private func diagnostic(
        for error: BASICError,
        fileName: String? = nil,
        sourceLineNumber: Int,
        fallbackColumn: Int
    ) -> BASICDiagnostic {
        switch error {
        case .contextualSyntax(let message, _, let column):
            return BASICDiagnostic(fileName: fileName, lineNumber: sourceLineNumber, column: column, message: "Syntax error: \(message)")
        case .contextualType(let message, _, let column):
            return BASICDiagnostic(fileName: fileName, lineNumber: sourceLineNumber, column: column, message: "Type error: \(message)")
        case .syntax(let message):
            return BASICDiagnostic(fileName: fileName, lineNumber: sourceLineNumber, column: fallbackColumn, message: "Syntax error: \(message)")
        case .type(let message):
            return BASICDiagnostic(fileName: fileName, lineNumber: sourceLineNumber, column: fallbackColumn, message: "Type error: \(message)")
        default:
            return BASICDiagnostic(fileName: fileName, lineNumber: sourceLineNumber, column: fallbackColumn, message: error.description)
        }
    }

    private func diagnostic(for error: BASICError, parsed: [ParsedLine]) -> BASICDiagnostic {
        let location = sourceLocation(for: error, parsed: parsed)
        return diagnostic(
            for: error,
            fileName: location?.fileName,
            sourceLineNumber: location?.lineNumber ?? 1,
            fallbackColumn: 0
        )
    }

    private func sourceLocation(for error: BASICError, parsed: [ParsedLine]) -> (fileName: String?, lineNumber: Int)? {
        let message = error.description
        var currentClassName: String?

        for line in parsed {
            switch line.statement {
            case .classDeclaration(let name):
                currentClassName = name
                if message.contains("CLASS \(name)") && !message.contains(" method ") {
                    return (line.fileName, line.sourceLineNumber)
                }
            case .endClass:
                currentClassName = nil
            case .interfaceDeclaration(let name):
                if message.contains("INTERFACE \(name)") {
                    return (line.fileName, line.sourceLineNumber)
                }
            case .typeDeclaration(let name):
                if message.contains("TYPE \(name)") {
                    return (line.fileName, line.sourceLineNumber)
                }
            case .functionDeclaration(let name, _, _, _, _, _, _):
                let classMatches = currentClassName.map { message.contains("CLASS \($0)") } ?? true
                if classMatches && (message.contains("method \(name.name)") || message.contains("Function \(name.name)")) {
                    return (line.fileName, line.sourceLineNumber)
                }
            case .classField(let name, _, _, _, _, _, _), .typeField(let name, _, _, _, _, _, _):
                if message.contains("field \(name)") || message.contains(" \(name) ") {
                    return (line.fileName, line.sourceLineNumber)
                }
            case .interfaceFunctionSignature(let name, _, _):
                if message.contains(".\(name.name)") || message.contains("member \(name.name)") {
                    return (line.fileName, line.sourceLineNumber)
                }
            default:
                continue
            }
        }

        if let rootLine = parsed.first(where: { !$0.isImported }) {
            return (rootLine.fileName, rootLine.sourceLineNumber)
        }
        return parsed.first.map { ($0.fileName, $0.sourceLineNumber) }
    }

    private func prepare(startLine: Int?) throws {
        let sourceLines = try expandedProgramLines()
        let parsed = try sourceLines.enumerated().flatMap { index, line in
            var parser = try Parser(source: line.source)
            let statement = try parser.parseStatement()
            return ParsedLine.flatten(
                number: line.number,
                fileName: line.fileName,
                sourceLineNumber: line.sourceLineNumber ?? index + 1,
                isImported: line.isImported,
                statement: statement
            )
        }
        parsedLines = parsed
        lineIndexByNumber = [:]
        lineIndexByLabel = [:]
        for (index, line) in parsed.enumerated() {
            if let number = line.number {
                lineIndexByNumber[number] = index
            }
            if let label = line.statement.label {
                lineIndexByLabel[label.uppercased()] = index
            }
        }
        recordDefinitions = try collectRecords(in: parsed)
        runtime.recordDefinitions = recordDefinitions
        interfaceDefinitions = try collectInterfaces(in: parsed)
        runtime.interfaceDefinitions = interfaceDefinitions
        classDefinitions = try collectClasses(in: parsed)
        try validateInterfaceInheritance()
        try validateClassInheritance()
        try validateClassInterfaces()
        runtime.classDefinitions = classDefinitions
        functionDefinitions = try collectFunctions(in: parsed)
        dataValues = collectData(in: parsed)
        dataIndex = 0
        try seedHostVariables()

        pc = 0
        if let startLine {
            guard let index = lineIndexByNumber[startLine] else { throw BASICError.missingLine(startLine) }
            pc = index
        }
        isPrepared = true
    }

    private func seedHostVariables() throws {
        let currentDirectory = try (host as? BASICFileHost)?.currentDirectoryPath() ?? FileManager.default.currentDirectoryPath
        let columns = (host as? BASICConsoleHost)?.screenColumns() ?? 80
        let rows = (host as? BASICConsoleHost)?.screenRows() ?? 25
        try runtime.assign(
            kind: .global,
            variable: VariableName(name: "CURRENTDIR$", column: 0),
            declaredType: .scalar(.string),
            value: .string(BASICString(currentDirectory))
        )
        try runtime.assign(
            kind: .global,
            variable: VariableName(name: "SCREENWIDTH", column: 0),
            declaredType: .scalar(.double),
            value: .number(Double(columns))
        )
        try runtime.assign(
            kind: .global,
            variable: VariableName(name: "SCREENHEIGHT", column: 0),
            declaredType: .scalar(.double),
            value: .number(Double(rows))
        )
    }

    private func expandedProgramLines() throws -> [ProgramLine] {
        var importedPaths: Set<String> = []
        var activeImportStack: [String] = []
        return try expandedProgramLines(from: program.orderedLines.map {
            ProgramLine(number: $0.number, source: $0.source, fileName: $0.fileName, sourceLineNumber: $0.sourceLineNumber, isImported: $0.isImported)
        }, importedPaths: &importedPaths, activeImportStack: &activeImportStack)
    }

    private func expandedProgramLines(
        from lines: [ProgramLine],
        importedPaths: inout Set<String>,
        activeImportStack: inout [String]
    ) throws -> [ProgramLine] {
        var expanded: [ProgramLine] = []
        for line in lines {
            let parsedStatement: Statement
            do {
                var parser = try Parser(source: line.source)
                parsedStatement = try parser.parseStatement()
            } catch {
                if line.isImported {
                    expanded.append(line)
                    continue
                }
                throw error
            }

            if case .importDirective(let path) = parsedStatement {
                guard let fileHost = host as? BASICFileHost else {
                    throw BASICError.runtime("IMPORT is not supported by this host")
                }
                let resolvedPath = Self.resolvedImportPath(path, relativeTo: line.fileName)
                if Self.isDirectoryImportPath(path) {
                    for importedFile in try Self.importedBasFiles(in: resolvedPath, using: fileHost) {
                        let normalizedImportedFile = Self.normalizedImportPath(importedFile)
                        try Self.validateImportCycle(for: normalizedImportedFile, activeImportStack: activeImportStack)
                        guard !importedPaths.contains(normalizedImportedFile) else { continue }
                        importedPaths.insert(normalizedImportedFile)
                        activeImportStack.append(normalizedImportedFile)
                        do {
                            let imported = BASICProgram.importedLines(from: try fileHost.loadTextFile(path: importedFile), fileName: importedFile)
                            expanded += try expandedProgramLines(
                                from: imported,
                                importedPaths: &importedPaths,
                                activeImportStack: &activeImportStack
                            )
                            _ = activeImportStack.popLast()
                        } catch {
                            _ = activeImportStack.popLast()
                            throw error
                        }
                    }
                } else {
                    try Self.validateImportCycle(for: resolvedPath, activeImportStack: activeImportStack)
                    guard !importedPaths.contains(resolvedPath) else { continue }
                    importedPaths.insert(resolvedPath)
                    activeImportStack.append(resolvedPath)
                    do {
                        let imported = BASICProgram.importedLines(from: try fileHost.loadTextFile(path: resolvedPath), fileName: resolvedPath)
                        expanded += try expandedProgramLines(
                            from: imported,
                            importedPaths: &importedPaths,
                            activeImportStack: &activeImportStack
                        )
                        _ = activeImportStack.popLast()
                    } catch {
                        _ = activeImportStack.popLast()
                        throw error
                    }
                }
            } else {
                expanded.append(line)
            }
        }
        return expanded
    }

    private static func validateImportCycle(for path: String, activeImportStack: [String]) throws {
        guard activeImportStack.contains(path) else { return }
        let cycle = (activeImportStack + [path]).joined(separator: " -> ")
        throw BASICError.runtime("Import cycle detected: \(cycle)")
    }

    private static func resolvedImportPath(_ path: String, relativeTo importer: String?) -> String {
        let normalizedPath = normalizedImportPath(path)
        guard !normalizedPath.hasPrefix("/"),
              let importer,
              let base = importDirectory(for: importer),
              !base.isEmpty
        else {
            return normalizedPath
        }
        return normalizedImportPath(base + "/" + normalizedPath)
    }

    private static func importDirectory(for fileName: String) -> String? {
        let normalized = normalizedImportPath(fileName)
        guard let separator = normalized.lastIndex(of: "/") else { return nil }
        return String(normalized[..<separator])
    }

    private static func normalizedImportPath(_ path: String) -> String {
        let usesTrailingSlash = path.hasSuffix("/") || path.hasSuffix("\\")
        let isAbsolute = path.hasPrefix("/") || path.hasPrefix("\\")
        let components = path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        var stack: [String] = []

        for component in components {
            switch component {
            case ".":
                continue
            case "..":
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append(component)
                }
            default:
                stack.append(component)
            }
        }

        let prefix = isAbsolute ? "/" : ""
        let joined = prefix + stack.joined(separator: "/")
        guard usesTrailingSlash, !joined.isEmpty, !joined.hasSuffix("/") else { return joined }
        return joined + "/"
    }

    private static func isDirectoryImportPath(_ path: String) -> Bool {
        path.hasSuffix("/") || path.hasSuffix("\\")
    }

    private static func importedBasFiles(in path: String, using fileHost: BASICFileHost) throws -> [String] {
        var directory = path.replacingOccurrences(of: "\\", with: "/")
        while directory.hasSuffix("/") {
            directory.removeLast()
        }
        return try fileHost.listFiles(path: path)
            .filter { $0.lowercased().hasSuffix(".bas") }
            .map { joinImportPath(directory: directory, relativePath: $0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func joinImportPath(directory: String, relativePath: String) -> String {
        let cleanRelative = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        guard !directory.isEmpty else { return cleanRelative }
        return "\(directory)/\(cleanRelative)"
    }

    /// Continues execution after a breakpoint, step, or break request.
    public func continueExecution() throws {
        clearPausedDebugSnapshots()
        if !isPrepared {
            try prepare(startLine: nil)
        }
        if let task {
            taskScheduler?.markRunning(task)
        }

        defer {
            if let task, pc >= parsedLines.count, task.state == .running {
                taskScheduler?.markCompleted(task)
            }
        }

        while pc < parsedLines.count {
            if let task, task.isCancellationRequested {
                taskScheduler?.markCancelled(task)
                throw BASICError.breakRequested(parsedLines[safe: pc]?.displayLineNumber)
            }
            do {
                let current = parsedLines[pc]
                if current.isImported {
                    pc += 1
                    continue
                }
                updateExecutionLocation(current)
                try executionControl?.checkBreak()
                let next = try execute(current.statement, pc: pc, parsed: parsedLines)
                try apply(flow: next, currentPC: pc, parsed: parsedLines)
            } catch let error as BASICError {
                if error.isDebugPause {
                    snapshotPausedDebugState()
                    if let task {
                        if task.isCancellationRequested {
                            taskScheduler?.markCancelled(task)
                        } else {
                            taskScheduler?.markSuspended(task)
                        }
                    }
                    throw error
                }
                if try handleRuntimeError(error, faultPC: pc, parsed: parsedLines) {
                    continue
                }
                if let task {
                    taskScheduler?.markFailed(task, error: error)
                }
                throw error
            } catch {
                if let task {
                    taskScheduler?.markFailed(task, error: error)
                }
                throw error
            }

            if executionControl?.shouldPauseAfterStep(callDepth: debugCallDepth) == true {
                if pc < parsedLines.count {
                    updateExecutionLocation(parsedLines[pc])
                    if let task {
                        taskScheduler?.markSuspended(task)
                    }
                    throw BASICError.stepComplete(parsedLines[pc].breakpointLocation)
                }
                return
            }
        }
    }

    private func apply(flow: Flow, currentPC: Int, parsed: [ParsedLine]) throws {
        switch flow {
        case .next:
            pc = currentPC + 1
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
            pc = parsed.count
        case .exitSelect:
            guard let index = matchingEndSelect(after: currentPC, in: parsed) else {
                throw BASICError.runtime("EXIT SELECT without SELECT")
            }
            pc = index + 1
        case .functionReturn:
            throw BASICError.runtime("RETURN outside FUNCTION")
        }
    }

    private func resetErrorTrap() {
        errorHandlerTarget = nil
        isHandlingError = false
        lastErrorNumber = 0
        lastErrorLine = 0
        lastErrorMessage = ""
        errorResumePC = nil
        errorResumeNextPC = nil
    }

    @discardableResult
    private func handleRuntimeError(_ error: BASICError, faultPC: Int, parsed: [ParsedLine]) throws -> Bool {
        guard errorHandlerTarget != nil, !isHandlingError else {
            return false
        }
        lastErrorNumber = errorNumber(for: error)
        lastErrorLine = parsed[safe: faultPC]?.displayLineNumber ?? 0
        lastErrorMessage = error.description
        errorResumePC = faultPC
        errorResumeNextPC = faultPC + 1
        isHandlingError = true
        try jumpToErrorHandler()
        return true
    }

    private func jumpToErrorHandler() throws {
        guard let target = errorHandlerTarget else {
            throw BASICError.runtime("No error handler")
        }
        switch target {
        case .line(let line):
            guard let index = lineIndexByNumber[line] else { throw BASICError.missingLine(line) }
            pc = index
        case .label(let label):
            guard let index = lineIndexByLabel[label.uppercased()] else { throw BASICError.missingLabel(label) }
            pc = index
        }
    }

    private func errorNumber(for error: BASICError) -> Int {
        switch error {
        case .numberedRuntime(let number):
            return number
        case .runtime(let message) where message.localizedCaseInsensitiveContains("division by zero"):
            return 11
        case .runtime(let message) where message.localizedCaseInsensitiveContains("type mismatch"):
            return 13
        case .type, .contextualType:
            return 13
        case .missingLine, .missingLabel:
            return 8
        default:
            return 5
        }
    }

    private func updateExecutionLocation(_ line: ParsedLine) {
        currentSourceFileName = line.fileName
        executionControl?.update(lineNumber: line.displayLineNumber, location: line.breakpointLocation)
        task?.update(location: line.breakpointLocation)
    }

    private func defaultLogModuleName() -> String {
        guard let fileName = currentSourceFileName, !fileName.isEmpty else {
            return "Immediate"
        }
        let normalized = fileName.replacingOccurrences(of: "\\", with: "/")
        return normalized.split(separator: "/").last.map(String.init) ?? fileName
    }

    fileprivate var debugCallDepth: Int {
        pausedDebugCallDepth ?? gosubStack.count + functionStack.count
    }

    private var currentClassContext: String? {
        functionStack.last?.definition.ownerClassName
    }

    fileprivate var debugLocalVariables: [BASICVariableSnapshot] {
        pausedDebugLocalVariables ?? runtime.localSnapshots()
    }

    fileprivate var debugGlobalVariables: [BASICVariableSnapshot] {
        pausedDebugGlobalVariables ?? runtime.globalSnapshots()
    }

    fileprivate var debugCallStack: [BASICCallStackFrame] {
        pausedDebugCallStack ?? currentDebugCallStack()
    }

    fileprivate var debugFrameLocalVariables: [[BASICVariableSnapshot]] {
        pausedDebugFrameLocalVariables ?? currentDebugFrameLocalVariables()
    }

    private func currentDebugCallStack() -> [BASICCallStackFrame] {
        var frames: [BASICCallStackFrame] = []

        for (offset, frame) in functionStack.reversed().enumerated() {
            frames.append(
                BASICCallStackFrame(
                    index: offset,
                    kind: debugFrameKind(for: frame.definition),
                    name: frame.definition.ownerClassName.map { "\($0).\((frame.definition.displayName))" } ?? frame.definition.displayName,
                    location: parsedLines[safe: frame.definition.startIndex]?.breakpointLocation,
                    declaringClassName: frame.definition.ownerClassName,
                    receiverClassName: frame.receiverClassName,
                    isOverride: frame.definition.isOverride
                )
            )
        }

        for (offset, frame) in gosubStack.reversed().enumerated() {
            frames.append(
                BASICCallStackFrame(
                    index: frames.count + offset,
                    kind: "GOSUB",
                    name: "Return",
                    location: parsedLines[safe: frame.returnIndex]?.breakpointLocation,
                    declaringClassName: nil,
                    receiverClassName: nil,
                    isOverride: false
                )
            )
        }

        frames.append(
            BASICCallStackFrame(
                index: frames.count,
                kind: "Program",
                name: "[main]",
                location: parsedLines[safe: pc]?.breakpointLocation,
                declaringClassName: nil,
                receiverClassName: nil,
                isOverride: false
            )
        )

        return frames
    }

    private func currentDebugFrameLocalVariables() -> [[BASICVariableSnapshot]] {
        var snapshots: [[BASICVariableSnapshot]] = []

        for frame in functionStack.reversed() {
            snapshots.append(runtime.localSnapshots(contextIndex: frame.localContextIndex))
        }

        for frame in gosubStack.reversed() {
            snapshots.append(runtime.localSnapshots(contextIndex: frame.localContextIndex))
        }

        snapshots.append([])
        return snapshots
    }

    private func debugFrameKind(for definition: FunctionDefinition) -> String {
        guard definition.ownerClassName != nil else { return "Function" }
        if definition.normalizedName == "NEW" { return "Constructor" }
        return "Method"
    }

    private func snapshotPausedDebugState() {
        guard pausedDebugCallStack == nil else { return }
        pausedDebugCallStack = currentDebugCallStack()
        pausedDebugLocalVariables = runtime.localSnapshots()
        pausedDebugFrameLocalVariables = currentDebugFrameLocalVariables()
        pausedDebugGlobalVariables = runtime.globalSnapshots()
        pausedDebugCallDepth = gosubStack.count + functionStack.count
    }

    private func clearPausedDebugSnapshots() {
        pausedDebugCallStack = nil
        pausedDebugLocalVariables = nil
        pausedDebugFrameLocalVariables = nil
        pausedDebugGlobalVariables = nil
        pausedDebugCallDepth = nil
    }

    private func execute(_ statement: Statement, pc: Int, parsed: [ParsedLine] = []) throws -> Flow {
        switch statement {
        case .empty, .remark, .data, .defFunction:
            return .next
        case .typeDeclaration:
            guard let index = matchingEndType(after: pc, in: parsed) else {
                throw BASICError.runtime("TYPE without END TYPE")
            }
            return .jump(index + 1)
        case .typeField, .endType:
            return .next
        case .interfaceDeclaration:
            guard let index = matchingEndInterface(after: pc, in: parsed) else {
                throw BASICError.runtime("INTERFACE without END INTERFACE")
            }
            return .jump(index + 1)
        case .interfaceFunctionSignature, .endInterface:
            return .next
        case .classDeclaration:
            guard let index = matchingEndClass(after: pc, in: parsed) else {
                throw BASICError.runtime("CLASS without END CLASS")
            }
            return .jump(index + 1)
        case .classField, .implementsDeclaration, .inheritsDeclaration, .endClass:
            return .next
        case .importDirective:
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
        case .functionDeclaration:
            guard let index = matchingEndFunction(after: pc, in: parsed) else {
                throw BASICError.runtime("FUNCTION without END FUNCTION")
            }
            return .jump(index + 1)
        case .endFunction:
            if !functionStack.isEmpty {
                return .functionReturn
            }
            return .next
        case .print(let parts):
            let rendered = try renderPrint(parts, startColumn: outputColumn)
            host?.print(rendered.text, terminator: rendered.terminator)
            updateOutputColumn(rendered)
            return .next
        case .printUsing(let format, let values, let trailingSeparator):
            let rendered = try renderUsing(format: format, values: values, trailingSeparator: trailingSeparator, startColumn: outputColumn)
            host?.print(rendered.text, terminator: rendered.terminator)
            updateOutputColumn(rendered)
            return .next
        case .log(let level, let parts):
            guard let loggingHost = host as? BASICLoggingHost,
                  loggingHost.isBASICLoggingEnabled else {
                return .next
            }
            let rendered = try renderPrint(parts, startColumn: 0)
            loggingHost.log(
                level: try string(level),
                issuer: "B",
                module: currentLogModuleOverride ?? defaultLogModuleName(),
                text: rendered.text
            )
            return .next
        case .module(let name):
            currentLogModuleOverride = try string(name)
            return .next
        case .printFile(let number, let parts):
            try printLegacyFile(number: number, parts: parts)
            return .next
        case .printFileUsing(let number, let format, let values, let trailingSeparator):
            try printLegacyFileUsing(number: number, format: format, values: values, trailingSeparator: trailingSeparator)
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
            outputColumn = 0
            return .next
        case .locate(let rowExpression, let columnExpression):
            let row = try integer(rowExpression)
            let column = try integer(columnExpression)
            if let consoleHost = host as? BASICConsoleHost {
                try consoleHost.locate(row: row, column: column)
            } else {
                let safeRow = max(1, row)
                let safeColumn = max(1, column)
                host?.print("\u{001B}[\(safeRow);\(safeColumn)H", terminator: "")
            }
            outputColumn = max(0, column - 1)
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
            if try assignFunctionReturnIfNeeded(variable: variable, declaredType: declaredType, value: value) {
                return .next
            }
            try runtime.assign(kind: kind, variable: variable, declaredType: declaredType, value: value)
            return .next
        case .referenceAssignment(let reference, let expression):
            let value = try expression.map(evaluate)
            try runtime.assign(
                reference: reference,
                indexes: try reference.indexes.map(evaluate),
                fieldIndexes: try evaluatedFieldIndexes(for: reference),
                value: value,
                accessClassName: currentClassContext
            )
            return .next
        case .expression(let expression):
            _ = try evaluate(expression)
            return .next
        case .dim(let kind, let variable, let dimensions, let declaredType):
            try runtime.dim(kind: kind, variable: variable, dimensions: try dimensions.map { try $0.map(integer) }, declaredType: declaredType)
            return .next
        case .optionLetMode(let mode):
            runtime.letMode = mode
            return .next
        case .optionKeyMode(let mode):
            runtime.keyMode = mode
            return .next
        case .input(let prompt, let target):
            let promptText = try prompt.map(string) ?? "\(inputTargetName(target))? "
            let raw = host?.readLine(prompt: promptText) ?? ""
            try assignReadValue(try inputValue(from: raw, to: target), to: target)
            return .next
        case .lineInput(let prompt, let target, let exitTarget, let fieldLength, let maxLength, let defaultValue):
            let promptText = try prompt.map(string) ?? ""
            let length = try fieldLength.map(integer)
            let maximum = try maxLength.map(integer)
            let defaultText = try defaultValue.map(string)
            if let length, length <= 0 {
                throw BASICError.runtime("LINE INPUT LENGTH must be greater than zero")
            }
            if let maximum, maximum < 0 {
                throw BASICError.runtime("LINE INPUT MAX must be zero or greater")
            }
            let options = BASICLineInputOptions(fieldLength: length, maxLength: maximum, defaultText: defaultText)
            let result: BASICLineInputResult
            if let lineInputHost = host as? BASICConfiguredLineInputHost {
                result = lineInputHost.readLine(prompt: promptText, exitOnSpecialKey: exitTarget != nil, options: options) ?? BASICLineInputResult(text: defaultText ?? "")
            } else if exitTarget != nil, let lineInputHost = host as? BASICLineInputHost {
                result = lineInputHost.readLine(prompt: promptText, exitOnSpecialKey: true) ?? BASICLineInputResult(text: defaultText ?? "")
            } else {
                result = BASICLineInputResult(text: host?.readLine(prompt: promptText) ?? defaultText ?? "")
            }
            let text = maximum.map { String(result.text.prefix($0)) } ?? result.text
            try assignReadValue(.string(BASICString(text)), to: target)
            if let exitTarget {
                try assignReadValue(.string(BASICString(result.exitKey ?? "")), to: exitTarget)
            }
            outputColumn = 0
            return .next
        case .openFile(let path, let mode, let number):
            try openLegacyFile(path: path, mode: mode, number: number)
            return .next
        case .closeFile(let number):
            try closeLegacyFile(number: number)
            return .next
        case .putFile(let number, let parts):
            try printLegacyFile(number: number, parts: parts)
            return .next
        case .getFile(let number, let targets):
            try inputLegacyFile(number: number, targets: targets)
            return .next
        case .resetFile(let number):
            try resetLegacyFile(number: number)
            return .next
        case .inputFile(let number, let targets):
            try inputLegacyFile(number: number, targets: targets)
            return .next
        case .lineInputFile(let number, let target):
            try lineInputLegacyFile(number: number, target: target)
            return .next
        case .read(let targets):
            try readData(into: targets)
            return .next
        case .restore:
            dataIndex = 0
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
        case .cd(let path):
            try changeDirectory(path: path)
            return .next
        case .files:
            try listFiles()
            return .next
        case .system(let command):
            let output = try runSystemCommand(command)
            if !output.isEmpty {
                host?.print(output, terminator: "")
                updateOutputColumn(text: output, terminator: "")
            }
            return .next
        case .yield:
            task?.recordYield()
            return .next
        case .randomize(let expression):
            let seed = try expression.map { try numeric(try evaluate($0)) } ?? Date().timeIntervalSince1970
            runtime.randomGenerator.randomize(seed: seed)
            return .next
        case .goto(let line):
            return .goto(line)
        case .gotoLabel(let label):
            return .gotoLabel(label)
        case .computedGoto(let targets, let selector):
            let selected = try integer(selector)
            guard selected >= 1, selected <= targets.count else {
                return .next
            }
            return targets[selected - 1].flow
        case .computedGosub(let targets, let selector):
            let selected = try integer(selector)
            guard selected >= 1, selected <= targets.count else {
                return .next
            }
            let localContextIndex = runtime.pushLocalContext()
            gosubStack.append(GosubFrame(returnIndex: pc + 1, localContextIndex: localContextIndex))
            return targets[selected - 1].flow
        case .onErrorGoto(let target):
            errorHandlerTarget = target
            isHandlingError = false
            errorResumePC = nil
            errorResumeNextPC = nil
            return .next
        case .error(let expression):
            throw BASICError.numberedRuntime(try integer(expression))
        case .resumeNext:
            guard isHandlingError else {
                throw BASICError.runtime("RESUME without error")
            }
            guard let resumeNextPC = errorResumeNextPC else {
                throw BASICError.runtime("No error to resume")
            }
            isHandlingError = false
            errorResumePC = nil
            errorResumeNextPC = nil
            return .jump(resumeNextPC)
        case .gosub(let target):
            let localContextIndex = runtime.pushLocalContext()
            gosubStack.append(GosubFrame(returnIndex: pc + 1, localContextIndex: localContextIndex))
            return target.flow
        case .returnFromSubroutine:
            if !functionStack.isEmpty {
                try setFunctionReturn(nil)
                return .functionReturn
            }
            guard let frame = gosubStack.popLast() else {
                throw BASICError.runtime("RETURN without GOSUB")
            }
            runtime.popLocalContext()
            return .returnTo(frame.returnIndex)
        case .returnValue(let expression):
            guard !functionStack.isEmpty else {
                throw BASICError.runtime("RETURN value outside FUNCTION")
            }
            try setFunctionReturn(try evaluate(expression))
            return .functionReturn
        case .pause:
            if host?.readLine(prompt: "PAUSE") == nil {
                host?.printLine("PAUSE")
                outputColumn = 0
            }
            return .next
        case .exitFunction:
            guard !functionStack.isEmpty else {
                throw BASICError.runtime("EXIT FUNCTION outside FUNCTION")
            }
            return .functionReturn
        case .ifThen(let condition, let thenAction, let elseAction):
            if try evaluate(condition).truthy {
                return try execute(thenAction, pc: pc, parsed: parsed)
            }
            guard let elseAction else { return .next }
            return try execute(elseAction, pc: pc, parsed: parsed)
        case .blockIf(let condition):
            return try blockIfFlow(condition, pc: pc, parsed: parsed)
        case .elseIf:
            guard let index = matchingEndIf(after: pc, in: parsed) else {
                throw BASICError.runtime("ELSEIF without END IF")
            }
            return .jump(index + 1)
        case .elseBlock:
            guard let index = matchingEndIf(after: pc, in: parsed) else {
                throw BASICError.runtime("ELSE without END IF")
            }
            return .jump(index + 1)
        case .endIf:
            return .next
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

    private func collectFunctions(in parsed: [ParsedLine]) throws -> [String: FunctionDefinition] {
        var definitions: [String: FunctionDefinition] = [:]
        var index = 0
        while index < parsed.count {
            switch parsed[index].statement {
            case .interfaceDeclaration:
                guard let endIndex = matchingEndInterface(after: index, in: parsed) else {
                    throw BASICError.runtime("INTERFACE without END INTERFACE")
                }
                index = endIndex + 1
                continue
            case .classDeclaration:
                guard let endIndex = matchingEndClass(after: index, in: parsed) else {
                    throw BASICError.runtime("CLASS without END CLASS")
                }
                index = endIndex + 1
                continue
            case .functionDeclaration(let name, let parameters, let returnType, let isAsync, _, _, _):
                guard let endIndex = matchingEndFunction(after: index, in: parsed) else {
                    throw BASICError.runtime("FUNCTION without END FUNCTION")
                }
                let definition = FunctionDefinition(
                    displayName: name.name,
                    normalizedName: name.normalized,
                    parameters: parameters,
                    returnType: returnType,
                    isAsync: isAsync,
                    startIndex: index,
                    endIndex: endIndex
                )
                if definitions[name.normalized] != nil {
                    throw BASICError.runtime("Function \(name.name) is already defined")
                }
                definitions[name.normalized] = definition
                index = endIndex + 1
                continue
            case .defFunction(let name, let parameter, let returnType, let body):
                let definition = FunctionDefinition(
                    displayName: name.name,
                    normalizedName: name.normalized,
                    parameters: [parameter],
                    returnType: returnType,
                    startIndex: index,
                    endIndex: index,
                    bodyExpression: body
                )
                if definitions[name.normalized] != nil {
                    throw BASICError.runtime("Function \(name.name) is already defined")
                }
                definitions[name.normalized] = definition
            default:
                break
            }
            index += 1
        }
        return definitions
    }

    private func collectData(in parsed: [ParsedLine]) -> [BASICValue] {
        parsed
            .filter { !$0.isImported }
            .flatMap { line -> [BASICValue] in
                if case .data(let values) = line.statement {
                    return values
                }
                return []
            }
    }

    private func readData(into targets: [ReadTarget]) throws {
        for target in targets {
            guard dataIndex < dataValues.count else {
                throw BASICError.runtime("Out of DATA")
            }
            let value = dataValues[dataIndex]
            dataIndex += 1
            switch target {
            case .variable(let variable):
                try runtime.assign(kind: .bare, variable: variable, declaredType: nil, value: value)
            case .reference(let reference):
                try runtime.assign(
                    reference: reference,
                    indexes: try reference.indexes.map(evaluate),
                    fieldIndexes: try evaluatedFieldIndexes(for: reference),
                    value: value,
                    accessClassName: currentClassContext
                )
            }
        }
    }

    private func collectRecords(in parsed: [ParsedLine]) throws -> [String: BASICRecordDefinition] {
        var definitions: [String: BASICRecordDefinition] = [:]
        var index = 0
        while index < parsed.count {
            guard case .typeDeclaration(let name) = parsed[index].statement else {
                index += 1
                continue
            }

            let normalized = name.uppercased()
            guard definitions[normalized] == nil else {
                throw BASICError.runtime("TYPE \(name) is already defined")
            }

            var fields: [BASICRecordField] = []
            index += 1
            while index < parsed.count {
                switch parsed[index].statement {
                case .typeField(let fieldName, let type, let fixedLength, let arrayDimensions, let json, let metadata, let defaultValue):
                    let normalizedField = fieldName.uppercased()
                    guard !fields.contains(where: { $0.normalizedName == normalizedField }) else {
                        throw BASICError.runtime("TYPE \(name) field \(fieldName) is already defined")
                    }
                    fields.append(
                        BASICRecordField(
                            displayName: fieldName,
                            normalizedName: normalizedField,
                            type: type,
                            fixedLength: fixedLength,
                            arrayDimensions: arrayDimensions,
                            json: json,
                            metadata: metadata,
                            defaultValue: defaultValue
                        )
                    )
                case .endType:
                    definitions[normalized] = BASICRecordDefinition(
                        displayName: name,
                        normalizedName: normalized,
                        fields: fields
                    )
                    break
                default:
                    throw BASICError.runtime("Unexpected statement inside TYPE \(name)")
                }
                if case .endType = parsed[index].statement {
                    break
                }
                index += 1
            }
            guard index < parsed.count, case .endType = parsed[index].statement else {
                throw BASICError.runtime("TYPE without END TYPE")
            }
            index += 1
        }
        return definitions
    }

    private func collectInterfaces(in parsed: [ParsedLine]) throws -> [String: BASICInterfaceDefinition] {
        var definitions: [String: BASICInterfaceDefinition] = [:]
        var index = 0
        while index < parsed.count {
            guard case .interfaceDeclaration(let name) = parsed[index].statement else {
                index += 1
                continue
            }

            let normalized = name.uppercased()
            guard definitions[normalized] == nil else {
                throw BASICError.runtime("INTERFACE \(name) is already defined")
            }

            var inheritedInterfaces: [String] = []
            var members: [BASICInterfaceMember] = []
            index += 1
            while index < parsed.count {
                switch parsed[index].statement {
                case .inheritsDeclaration(let interfaceName):
                    inheritedInterfaces.append(interfaceName)
                case .interfaceFunctionSignature(let memberName, let parameters, let returnType):
                    let normalizedMember = memberName.normalized
                    guard !members.contains(where: { $0.normalizedName == normalizedMember }) else {
                        throw BASICError.runtime("INTERFACE \(name) member \(memberName.name) is already defined")
                    }
                    members.append(
                        BASICInterfaceMember(
                            displayName: memberName.name,
                            normalizedName: normalizedMember,
                            parameters: parameters,
                            returnType: returnType
                        )
                    )
                case .functionDeclaration(let memberName, let parameters, let returnType, _, _, _, _):
                    let normalizedMember = memberName.normalized
                    guard !members.contains(where: { $0.normalizedName == normalizedMember }) else {
                        throw BASICError.runtime("INTERFACE \(name) member \(memberName.name) is already defined")
                    }
                    members.append(
                        BASICInterfaceMember(
                            displayName: memberName.name,
                            normalizedName: normalizedMember,
                            parameters: parameters,
                            returnType: returnType
                        )
                    )
                case .endInterface:
                    definitions[normalized] = BASICInterfaceDefinition(
                        displayName: name,
                        normalizedName: normalized,
                        inheritedInterfaces: inheritedInterfaces,
                        members: members
                    )
                    break
                default:
                    throw BASICError.runtime("Unexpected statement inside INTERFACE \(name)")
                }
                if case .endInterface = parsed[index].statement {
                    break
                }
                index += 1
            }
            guard index < parsed.count, case .endInterface = parsed[index].statement else {
                throw BASICError.runtime("INTERFACE without END INTERFACE")
            }
            index += 1
        }
        return definitions
    }

    private func collectClasses(in parsed: [ParsedLine]) throws -> [String: BASICClassDefinition] {
        var definitions: [String: BASICClassDefinition] = [:]
        var index = 0
        while index < parsed.count {
            guard case .classDeclaration(let name) = parsed[index].statement else {
                index += 1
                continue
            }

            let normalized = name.uppercased()
            guard definitions[normalized] == nil else {
                throw BASICError.runtime("CLASS \(name) is already defined")
            }

            var fields: [BASICClassField] = []
            var interfaces: [String] = []
            var methods: [String: FunctionDefinition] = [:]
            var baseClass: String?
            index += 1
            while index < parsed.count {
                switch parsed[index].statement {
                case .classField(let fieldName, let type, let visibility, let arrayDimensions, let json, let metadata, let defaultValue):
                    let normalizedField = fieldName.uppercased()
                    guard !fields.contains(where: { $0.normalizedName == normalizedField }) else {
                        throw BASICError.runtime("CLASS \(name) field \(fieldName) is already defined")
                    }
                    fields.append(BASICClassField(displayName: fieldName, normalizedName: normalizedField, type: type, arrayDimensions: arrayDimensions, visibility: visibility, declaringClassName: normalized, json: json, metadata: metadata, defaultValue: defaultValue))
                case .typeField(let fieldName, let type, _, let arrayDimensions, let json, let metadata, let defaultValue):
                    let normalizedField = fieldName.uppercased()
                    guard !fields.contains(where: { $0.normalizedName == normalizedField }) else {
                        throw BASICError.runtime("CLASS \(name) field \(fieldName) is already defined")
                    }
                    fields.append(BASICClassField(displayName: fieldName, normalizedName: normalizedField, type: type, arrayDimensions: arrayDimensions, visibility: .public, declaringClassName: normalized, json: json, metadata: metadata, defaultValue: defaultValue))
                case .implementsDeclaration(let interfaceName):
                    interfaces.append(interfaceName)
                case .inheritsDeclaration(let baseClassName):
                    guard baseClassName.uppercased() != normalized else {
                        throw BASICError.runtime("CLASS \(name) cannot inherit itself")
                    }
                    baseClass = baseClassName
                case .functionDeclaration(let methodName, let parameters, let returnType, let isAsync, let visibility, let isOverride, let explicitInterfaceImplementations):
                    guard let endIndex = matchingEndFunction(after: index, in: parsed) else {
                        throw BASICError.runtime("FUNCTION without END FUNCTION")
                    }
                    guard methods[methodName.normalized] == nil else {
                        throw BASICError.runtime("CLASS \(name) method \(methodName.name) is already defined")
                    }
                    methods[methodName.normalized] = FunctionDefinition(
                        displayName: methodName.name,
                        normalizedName: methodName.normalized,
                        parameters: parameters,
                        returnType: returnType,
                        isAsync: isAsync,
                        startIndex: index,
                        endIndex: endIndex,
                        ownerClassName: name,
                        visibility: visibility,
                        isOverride: isOverride,
                        explicitInterfaceImplementations: explicitInterfaceImplementations
                    )
                    index = endIndex
                case .endClass:
                    definitions[normalized] = BASICClassDefinition(
                        displayName: name,
                        normalizedName: normalized,
                        baseClassName: baseClass,
                        fields: fields,
                        implementedInterfaces: interfaces,
                        methods: methods
                    )
                    break
                default:
                    throw BASICError.runtime("Unexpected statement inside CLASS \(name)")
                }
                if case .endClass = parsed[index].statement {
                    break
                }
                index += 1
            }
            guard index < parsed.count, case .endClass = parsed[index].statement else {
                throw BASICError.runtime("CLASS without END CLASS")
            }
            index += 1
        }
        return definitions
    }

    private func validateClassInterfaces() throws {
        for classDefinition in classDefinitions.values {
            for interfaceName in inheritedInterfaceNames(for: classDefinition) {
                guard let interfaceDefinition = interfaceDefinitions[interfaceName.uppercased()] else {
                    throw BASICError.runtime("CLASS \(classDefinition.displayName) implements unknown INTERFACE \(interfaceName)")
                }
                for member in interfaceMembers(for: interfaceDefinition) {
                    guard let method = method(for: member, interface: interfaceDefinition, in: classDefinition) else {
                        throw BASICError.runtime("CLASS \(classDefinition.displayName) does not implement \(interfaceDefinition.displayName).\(member.displayName)")
                    }
                    guard method.parameters.map(\.type) == member.parameters.map(\.type),
                          method.returnType == member.returnType else {
                        throw BASICError.runtime("CLASS \(classDefinition.displayName) method \(method.displayName) does not match INTERFACE \(interfaceDefinition.displayName)")
                    }
                }
            }
        }
    }

    private func validateInterfaceInheritance() throws {
        for interfaceDefinition in interfaceDefinitions.values.sorted(by: { $0.displayName < $1.displayName }) {
            for inheritedName in interfaceDefinition.inheritedInterfaces {
                guard interfaceDefinitions[inheritedName.uppercased()] != nil else {
                    throw BASICError.runtime("INTERFACE \(interfaceDefinition.displayName) inherits unknown INTERFACE \(inheritedName)")
                }
            }
            try validateInterfaceCycle(interfaceDefinition, path: [])
        }
    }

    private func validateInterfaceCycle(_ interfaceDefinition: BASICInterfaceDefinition, path: [String]) throws {
        if path.contains(interfaceDefinition.normalizedName) {
            throw BASICError.runtime("INTERFACE \(interfaceDefinition.displayName) has an inheritance cycle")
        }
        let nextPath = path + [interfaceDefinition.normalizedName]
        for inheritedName in interfaceDefinition.inheritedInterfaces {
            guard let inherited = interfaceDefinitions[inheritedName.uppercased()] else { continue }
            try validateInterfaceCycle(inherited, path: nextPath)
        }
    }

    private func validateClassInheritance() throws {
        for classDefinition in classDefinitions.values {
            if let baseName = classDefinition.baseClassName,
               classDefinitions[baseName.uppercased()] == nil {
                throw BASICError.runtime("CLASS \(classDefinition.displayName) inherits unknown CLASS \(baseName)")
            }
            var seen: Set<String> = []
            var current = classDefinition.baseClassName
            while let currentName = current {
                let normalized = currentName.uppercased()
                guard seen.insert(normalized).inserted else {
                    throw BASICError.runtime("CLASS \(classDefinition.displayName) has an inheritance cycle")
                }
                current = classDefinitions[normalized]?.baseClassName
            }

            let inherited = inheritedFields(for: classDefinition).dropLast(classDefinition.fields.count)
            for field in classDefinition.fields where inherited.contains(where: { $0.normalizedName == field.normalizedName }) {
                throw BASICError.runtime("CLASS \(classDefinition.displayName) field \(field.displayName) shadows an inherited field")
            }

            for method in classDefinition.methods.values {
                let inheritedMethod = inheritedMethod(named: method.normalizedName, for: classDefinition)
                if method.isOverride {
                    guard let inheritedMethod else {
                        throw BASICError.runtime("CLASS \(classDefinition.displayName) method \(method.displayName) is OVERRIDES but no inherited method exists")
                    }
                    guard methodSignature(method, matches: inheritedMethod) else {
                        throw BASICError.runtime("CLASS \(classDefinition.displayName) method \(method.displayName) OVERRIDES signature does not match inherited method")
                    }
                } else if inheritedMethod != nil {
                    throw BASICError.runtime("CLASS \(classDefinition.displayName) method \(method.displayName) overrides an inherited method; add OVERRIDES")
                }
            }
        }
    }

    private func methodSignature(_ method: FunctionDefinition, matches inheritedMethod: FunctionDefinition) -> Bool {
        method.parameters.map(\.type) == inheritedMethod.parameters.map(\.type)
            && method.returnType == inheritedMethod.returnType
    }

    private func inheritedInterfaceNames(for classDefinition: BASICClassDefinition) -> [String] {
        var names: [String] = []
        if let baseName = classDefinition.baseClassName,
           let baseDefinition = classDefinitions[baseName.uppercased()] {
            names.append(contentsOf: inheritedInterfaceNames(for: baseDefinition))
        }
        names.append(contentsOf: classDefinition.implementedInterfaces)
        return names
    }

    private func interfaceMembers(for interfaceDefinition: BASICInterfaceDefinition) -> [BASICInterfaceMember] {
        var members: [BASICInterfaceMember] = []
        for inheritedName in interfaceDefinition.inheritedInterfaces {
            if let inherited = interfaceDefinitions[inheritedName.uppercased()] {
                members.append(contentsOf: interfaceMembers(for: inherited))
            }
        }
        members.append(contentsOf: interfaceDefinition.members)
        return members
    }

    private func lookupMethod(named normalizedName: String, in classDefinition: BASICClassDefinition) -> FunctionDefinition? {
        if let method = classDefinition.methods[normalizedName] {
            return method
        }
        if let baseName = classDefinition.baseClassName,
           let baseDefinition = classDefinitions[baseName.uppercased()] {
            return lookupMethod(named: normalizedName, in: baseDefinition)
        }
        return nil
    }

    private func method(
        for member: BASICInterfaceMember,
        interface: BASICInterfaceDefinition,
        in classDefinition: BASICClassDefinition
    ) -> FunctionDefinition? {
        if let direct = lookupMethod(named: member.normalizedName, in: classDefinition) {
            return direct
        }
        return allMethods(in: classDefinition).first { method in
            method.explicitInterfaceImplementations.contains {
                $0.normalizedInterfaceName == interface.normalizedName
                    && $0.normalizedMemberName == member.normalizedName
            }
        }
    }

    private func allMethods(in classDefinition: BASICClassDefinition) -> [FunctionDefinition] {
        var methods: [FunctionDefinition] = []
        if let baseName = classDefinition.baseClassName,
           let baseDefinition = classDefinitions[baseName.uppercased()] {
            methods.append(contentsOf: allMethods(in: baseDefinition))
        }
        methods.append(contentsOf: classDefinition.methods.values)
        return methods
    }

    private func inheritedMethod(named normalizedName: String, for classDefinition: BASICClassDefinition) -> FunctionDefinition? {
        guard let baseName = classDefinition.baseClassName,
              let baseDefinition = classDefinitions[baseName.uppercased()] else {
            return nil
        }
        return lookupMethod(named: normalizedName, in: baseDefinition)
    }

    private func inheritedFields(for classDefinition: BASICClassDefinition) -> [BASICClassField] {
        var fields: [BASICClassField] = []
        if let baseName = classDefinition.baseClassName,
           let baseDefinition = classDefinitions[baseName.uppercased()] {
            fields.append(contentsOf: inheritedFields(for: baseDefinition))
        }
        fields.append(contentsOf: classDefinition.fields)
        return fields
    }

    private func matchingEndFunction(after pc: Int, in parsed: [ParsedLine]) -> Int? {
        var depth = 0
        var index = pc + 1
        while index < parsed.count {
            switch parsed[index].statement {
            case .functionDeclaration:
                depth += 1
            case .endFunction:
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

    private func matchingEndType(after pc: Int, in parsed: [ParsedLine]) -> Int? {
        var index = pc + 1
        while index < parsed.count {
            if case .endType = parsed[index].statement {
                return index
            }
            index += 1
        }
        return nil
    }

    private func matchingEndInterface(after pc: Int, in parsed: [ParsedLine]) -> Int? {
        var index = pc + 1
        while index < parsed.count {
            if case .endInterface = parsed[index].statement {
                return index
            }
            index += 1
        }
        return nil
    }

    private func matchingEndClass(after pc: Int, in parsed: [ParsedLine]) -> Int? {
        var index = pc + 1
        while index < parsed.count {
            if case .endClass = parsed[index].statement {
                return index
            }
            index += 1
        }
        return nil
    }

    private static let intrinsicFunctionNames: Set<String> = [
        "ABS", "ACS", "ASC", "ASN", "ATN", "BINARY$", "CINT", "COS", "COT", "CSC", "DEC",
        "EXP", "FIX", "HCS", "HEX$", "HSN", "HTN", "INKEY$", "INPUT$", "INSTR", "INT", "EOF", "LCT", "LEFT$",
        "LOG", "LOC", "LTW", "MID$", "RAD", "RIGHT$", "RND", "SCN", "SEC", "SGN",
        "FILEEXISTS", "SIN", "SPACE$", "SPC", "SQR", "STR$", "STRING$", "TAB", "TAN", "POS",
        "TOJSONSTRING", "VAL", "FROMJSONSTRING", "USING$", "REFLECT",
        "FIELDCOUNT", "FIELDNAME$", "FIELDMETA", "FIELDVALUE", "FIELDVALUE$", "SETFIELD"
    ]

    private func callIntrinsicFunction(name: VariableName, arguments: [Expression]) throws -> BASICValue {
        let normalized = name.normalized

        switch normalized {
        case "ABS":
            let value = try singleNumericArgument(name: name.name, arguments: arguments)
            return .number(abs(value))
        case "ACS":
            return .number(acos(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "ASC":
            let value = try singleRawStringArgument(name: name.name, arguments: arguments)
            guard let scalar = value.unicodeScalars.first else {
                throw BASICError.runtime("ASC requires a non-empty string")
            }
            return .number(Double(scalar.value))
        case "ASN":
            return .number(asin(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "ATN":
            return .number(atan(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "BINARY$":
            let value = try singleIntegerArgument(name: name.name, arguments: arguments)
            guard value >= 0 else {
                throw BASICError.runtime("BINARY$ requires a non-negative value")
            }
            return .string(BASICString(String(value, radix: 2)))
        case "CINT":
            return .number(try singleNumericArgument(name: name.name, arguments: arguments).rounded())
        case "COS":
            return .number(cos(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "COT":
            return .number(1 / tan(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "CSC":
            return .number(1 / sin(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "DEC":
            return .number(try singleNumericArgument(name: name.name, arguments: arguments) * 180 / Double.pi)
        case "EXP":
            return .number(exp(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "FILEEXISTS":
            try requireArgumentCount(name.name, arguments, 1)
            guard let fileHost = host as? BASICFileHost else {
                throw BASICError.runtime("FILEEXISTS is not supported by this host")
            }
            return .number(try fileHost.fileExists(path: string(arguments[0])) ? 1 : 0)
        case "EOF":
            try requireArgumentCount(name.name, arguments, 1)
            return try legacyEOF(arguments[0])
        case "FIX":
            let value = try singleNumericArgument(name: name.name, arguments: arguments)
            return .number(value < 0 ? ceil(value) : floor(value))
        case "HCS":
            return .number(cosh(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "HEX$":
            let value = try singleIntegerArgument(name: name.name, arguments: arguments)
            guard value >= 0 else {
                throw BASICError.runtime("HEX$ requires a non-negative value")
            }
            return .string(BASICString(String(value, radix: 16, uppercase: true)))
        case "HSN":
            return .number(sinh(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "HTN":
            return .number(tanh(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "INKEY$":
            try requireArgumentCount(name.name, arguments, 0)
            let rawKey = (host as? BASICKeyboardHost)?.readKey() ?? ""
            let encoding: BASICKeyEncoding = runtime.keyMode == .ibm ? .ibm : .aibasic
            return .string(BASICString(BASICKeyNormalizer.normalize(rawKey, encoding: encoding)))
        case "INPUT$":
            return try intrinsicInputString(name: name.name, arguments: arguments)
        case "INSTR":
            return .number(Double(try intrinsicInstr(arguments: arguments)))
        case "INT":
            return .number(floor(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "LCT":
            return .number(log10(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "LEFT$":
            try requireArgumentCount(name.name, arguments, 2)
            let value = try rawString(arguments[0])
            let count = max(0, try integer(arguments[1]))
            return .string(BASICString(String(value.prefix(count))))
        case "LOG", "LOC":
            return .number(log(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "LTW":
            return .number(log2(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "MID$":
            return try intrinsicMid(arguments: arguments)
        case "POS":
            try requireArgumentCount(name.name, arguments, 1)
            return .number(Double(outputColumn + 1))
        case "RIGHT$":
            try requireArgumentCount(name.name, arguments, 2)
            let value = try rawString(arguments[0])
            let count = max(0, try integer(arguments[1]))
            return .string(BASICString(String(value.suffix(count))))
        case "REFLECT":
            try requireArgumentCount(name.name, arguments, 1)
            return try reflect(arguments[0])
        case "FIELDCOUNT":
            try requireArgumentCount(name.name, arguments, 1)
            return .number(Double(try runtime.reflectedFieldCount(for: evaluate(arguments[0]))))
        case "FIELDNAME$":
            try requireArgumentCount(name.name, arguments, 2)
            return .string(BASICString(try runtime.reflectedFieldName(for: evaluate(arguments[0]), selector: evaluate(arguments[1]))))
        case "FIELDMETA":
            try requireArgumentCount(name.name, arguments, 2)
            return try runtime.reflectedFieldMetadata(for: evaluate(arguments[0]), selector: evaluate(arguments[1]))
        case "FIELDVALUE":
            try requireArgumentCount(name.name, arguments, 2)
            return try runtime.reflectedFieldValue(for: evaluate(arguments[0]), selector: evaluate(arguments[1]))
        case "FIELDVALUE$":
            try requireArgumentCount(name.name, arguments, 2)
            return .string(BASICString(try runtime.reflectedFieldValue(for: evaluate(arguments[0]), selector: evaluate(arguments[1])).description))
        case "SETFIELD":
            try requireArgumentCount(name.name, arguments, 3)
            return try runtime.settingReflectedField(value: evaluate(arguments[0]), selector: evaluate(arguments[1]), newValue: evaluate(arguments[2]))
        case "RAD":
            return .number(try singleNumericArgument(name: name.name, arguments: arguments) * Double.pi / 180)
        case "RND":
            try requireArgumentRange(name.name, arguments, 0...1)
            let argument = try arguments.first.map { try numeric(try evaluate($0)) }
            return .number(runtime.randomGenerator.next(argument: argument))
        case "SCN", "SGN":
            let value = try singleNumericArgument(name: name.name, arguments: arguments)
            return .number(value == 0 ? 0 : (value < 0 ? -1 : 1))
        case "SEC":
            return .number(1 / cos(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "SIN":
            return .number(sin(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "SPACE$":
            let count = max(0, try singleIntegerArgument(name: name.name, arguments: arguments))
            return .string(BASICString(String(repeating: " ", count: count)))
        case "SPC":
            let count = max(0, try singleIntegerArgument(name: name.name, arguments: arguments))
            return .string(BASICString(String(repeating: " ", count: count)))
        case "SQR":
            return .number(sqrt(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "STR$":
            let value = try singleNumericArgument(name: name.name, arguments: arguments)
            let rendered = BASICValue.number(value).description
            return .string(BASICString(value >= 0 ? " " + rendered : rendered))
        case "STRING$":
            return try intrinsicString(arguments: arguments)
        case "TAB":
            let target = max(1, try singleIntegerArgument(name: name.name, arguments: arguments))
            return .string(BASICString(String(repeating: " ", count: target - 1)))
        case "TAN":
            return .number(tan(try singleNumericArgument(name: name.name, arguments: arguments)))
        case "TOJSONSTRING":
            try requireArgumentCount(name.name, arguments, 2)
            let value = try evaluate(arguments[0])
            let pretty = try boolean(try evaluate(arguments[1]))
            do {
                return .string(BASICString(try runtime.jsonString(for: value, pretty: pretty)))
            } catch let error as BASICError {
                throw error
            } catch {
                throw BASICError.runtime("JSON encode failed: \(error.localizedDescription)")
            }
        case "VAL":
            let value = try singleStringArgument(name: name.name, arguments: arguments)
            return .number(Self.leadingNumber(in: value) ?? 0)
        case "USING$":
            guard arguments.count >= 2 else {
                throw BASICError.runtime("USING$ expects at least 2 arguments")
            }
            let format = try string(arguments[0])
            let values = try arguments.dropFirst().map(evaluate)
            return .string(BASICString(try formatUsing(format: format, values: values)))
        case "FROMJSONSTRING":
            try requireArgumentCount(name.name, arguments, 2)
            let source = try string(arguments[0])
            let permissive = try boolean(try evaluate(arguments[1]))
            do {
                return try runtime.valueFromJSONString(source, permissive: permissive)
            } catch let error as BASICError {
                throw error
            } catch {
                throw BASICError.runtime("JSON parse failed: \(error.localizedDescription)")
            }
        default:
            throw BASICError.runtime("Unknown function \(name.name)")
        }
    }

    private func callFunction(name: VariableName, arguments: [Expression]) throws -> BASICValue {
        if Self.intrinsicFunctionNames.contains(name.normalized) {
            return try callIntrinsicFunction(name: name, arguments: arguments)
        }
        guard let definition = functionDefinitions[name.normalized] else {
            throw BASICError.runtime("Unknown function \(name.name)")
        }
        return try callFunction(definition: definition, receiver: nil, receiverClassName: nil, arguments: arguments, allowVoid: false).value
    }

    private func singleNumericArgument(name: String, arguments: [Expression]) throws -> Double {
        try requireArgumentCount(name, arguments, 1)
        return try numeric(try evaluate(arguments[0]))
    }

    private func singleIntegerArgument(name: String, arguments: [Expression]) throws -> Int {
        try requireArgumentCount(name, arguments, 1)
        return try integer(arguments[0])
    }

    private func singleStringArgument(name: String, arguments: [Expression]) throws -> String {
        try requireArgumentCount(name, arguments, 1)
        return try string(arguments[0])
    }

    private func singleRawStringArgument(name: String, arguments: [Expression]) throws -> String {
        try requireArgumentCount(name, arguments, 1)
        return try rawString(arguments[0])
    }

    private func reflect(_ expression: Expression) throws -> BASICValue {
        switch expression {
        case .variable(let variable):
            return try runtime.metadata(
                for: VariableReference(base: variable),
                indexes: [],
                accessClassName: currentClassContext
            )
        case .variableReference(let reference):
            return try runtime.metadata(
                for: reference,
                indexes: try reference.indexes.map(evaluate),
                fieldIndexes: try evaluatedFieldIndexes(for: reference),
                accessClassName: currentClassContext
            )
        case .callOrArray(let name, let arguments):
            return try runtime.metadata(
                for: VariableReference(base: name, indexes: arguments),
                indexes: try arguments.map(evaluate),
                accessClassName: currentClassContext
            )
        default:
            throw BASICError.runtime("REFLECT expects a variable")
        }
    }

    private func requireArgumentCount(_ name: String, _ arguments: [Expression], _ count: Int) throws {
        guard arguments.count == count else {
            throw BASICError.runtime("\(name) expects \(count) argument\(count == 1 ? "" : "s")")
        }
    }

    private func requireArgumentRange(_ name: String, _ arguments: [Expression], _ range: ClosedRange<Int>) throws {
        guard range.contains(arguments.count) else {
            throw BASICError.runtime("\(name) expects \(range.lowerBound) to \(range.upperBound) arguments")
        }
    }

    private func intrinsicInstr(arguments: [Expression]) throws -> Int {
        try requireArgumentRange("INSTR", arguments, 2...3)
        let start: Int
        let haystack: String
        let needle: String
        if arguments.count == 2 {
            start = 1
            haystack = try rawString(arguments[0])
            needle = try rawString(arguments[1])
        } else {
            start = max(1, try integer(arguments[0]))
            haystack = try rawString(arguments[1])
            needle = try rawString(arguments[2])
        }

        guard !needle.isEmpty else { return start }
        guard start <= haystack.count else { return 0 }
        let startIndex = haystack.index(haystack.startIndex, offsetBy: start - 1)
        guard let range = haystack[startIndex...].range(of: needle) else { return 0 }
        return haystack.distance(from: haystack.startIndex, to: range.lowerBound) + 1
    }

    private func intrinsicMid(arguments: [Expression]) throws -> BASICValue {
        try requireArgumentRange("MID$", arguments, 2...3)
        let value = try rawString(arguments[0])
        let start = max(1, try integer(arguments[1]))
        guard start <= value.count else { return .string(BASICString("")) }
        let startIndex = value.index(value.startIndex, offsetBy: start - 1)
        let suffix = value[startIndex...]
        if arguments.count == 2 {
            return .string(BASICString(String(suffix)))
        }
        let count = max(0, try integer(arguments[2]))
        return .string(BASICString(String(suffix.prefix(count))))
    }

    private func intrinsicString(arguments: [Expression]) throws -> BASICValue {
        try requireArgumentCount("STRING$", arguments, 2)
        let count = max(0, try integer(arguments[0]))
        let value = try evaluate(arguments[1])
        let character: String
        if let number = value.number {
            let code = Int(number.rounded())
            character = code == 0 ? "\0" : try BASICString.character(code: code).description
        } else if let string = value.string?.description, let first = string.first {
            character = String(first)
        } else {
            throw BASICError.runtime("STRING$ requires a character code or non-empty string")
        }
        return .string(BASICString(String(repeating: character, count: count)))
    }

    private static func leadingNumber(in value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        var index = trimmed.startIndex
        if index < trimmed.endIndex, trimmed[index] == "+" || trimmed[index] == "-" {
            index = trimmed.index(after: index)
        }

        var hasDigits = false
        while index < trimmed.endIndex, trimmed[index].isNumber {
            hasDigits = true
            index = trimmed.index(after: index)
        }
        if index < trimmed.endIndex, trimmed[index] == "." {
            index = trimmed.index(after: index)
            while index < trimmed.endIndex, trimmed[index].isNumber {
                hasDigits = true
                index = trimmed.index(after: index)
            }
        }
        guard hasDigits else { return nil }
        if index < trimmed.endIndex, trimmed[index].uppercased() == "E" {
            var exponentIndex = trimmed.index(after: index)
            if exponentIndex < trimmed.endIndex, trimmed[exponentIndex] == "+" || trimmed[exponentIndex] == "-" {
                exponentIndex = trimmed.index(after: exponentIndex)
            }
            let exponentStart = exponentIndex
            while exponentIndex < trimmed.endIndex, trimmed[exponentIndex].isNumber {
                exponentIndex = trimmed.index(after: exponentIndex)
            }
            if exponentIndex > exponentStart {
                index = exponentIndex
            }
        }
        return Double(trimmed[..<index])
    }

    private func callMethod(receiver: VariableReference, method: VariableName, arguments: [Expression]) throws -> BASICValue {
        let receiverDeclaredType = runtime.declaredType(for: receiver)
        let receiverValue = try runtime.value(
            for: receiver,
            indexes: try receiver.indexes.map(evaluate),
            fieldIndexes: try evaluatedFieldIndexes(for: receiver),
            accessClassName: currentClassContext
        )
        if case .systemObject(let typeName, let id) = receiverValue {
            return try runtime.callSystemObjectMethod(
                typeName: typeName,
                id: id,
                method: method.name,
                arguments: try arguments.map(evaluate),
                fileHost: host as? BASICFileHost,
                jsonDecoder: { [runtime] source in try runtime.valueFromJSONString(source, permissive: true) },
                jsonEncoder: { [runtime] value, pretty in try runtime.jsonString(for: value, pretty: pretty) }
            )
        }
        var missingMethodError: BASICError?
        if case .object(let className, _) = receiverValue {
            guard let classDefinition = classDefinitions[className.uppercased()] else {
                throw BASICError.runtime("Unknown CLASS \(className)")
            }
            if let definition = lookupMethod(named: method.normalized, receiverDeclaredType: receiverDeclaredType, in: classDefinition) {
                try validateMethodAccess(definition, receiverClass: classDefinition.displayName)
                let result = try callFunction(
                    definition: definition,
                    receiver: receiverValue,
                    receiverClassName: classDefinition.displayName,
                    arguments: arguments,
                    allowVoid: false
                )
                if let updatedReceiver = result.receiver {
                    try runtime.assign(
                        reference: receiver,
                        indexes: try receiver.indexes.map(evaluate),
                        fieldIndexes: try evaluatedFieldIndexes(for: receiver),
                        value: updatedReceiver,
                        accessClassName: currentClassContext
                    )
                }
                return result.value
            }
            missingMethodError = BASICError.runtime("\(methodLookupTypeName(receiverDeclaredType, fallbackClassName: classDefinition.displayName)) has no method \(method.name)")
        }
        var fieldReference = receiver
        fieldReference.fields.append(method.name)
        fieldReference.fieldIndexes.append(arguments)
        do {
            return try runtime.value(
                for: fieldReference,
                indexes: try fieldReference.indexes.map(evaluate),
                fieldIndexes: try evaluatedFieldIndexes(for: fieldReference),
                accessClassName: currentClassContext
            )
        } catch {
            if let missingMethodError {
                throw missingMethodError
            }
            throw error
        }
    }

    private func lookupMethod(
        named normalizedName: String,
        receiverDeclaredType: BASICType?,
        in classDefinition: BASICClassDefinition
    ) -> FunctionDefinition? {
        switch receiverDeclaredType {
        case .interfaceType(let interfaceName):
            return lookupInterfaceMethod(
                named: normalizedName,
                interfaceName: interfaceName,
                in: classDefinition
            )
        case .classType(let declaredClassName):
            guard let declaredClass = classDefinitions[declaredClassName.uppercased()],
                  lookupMethod(named: normalizedName, in: declaredClass) != nil else {
                return nil
            }
            return lookupMethod(named: normalizedName, in: classDefinition)
        default:
            if let direct = lookupMethod(named: normalizedName, in: classDefinition) {
                return direct
            }
            return nil
        }
    }

    private func methodLookupTypeName(_ receiverDeclaredType: BASICType?, fallbackClassName: String) -> String {
        switch receiverDeclaredType {
        case .interfaceType(let name):
            return "INTERFACE \(name)"
        case .classType(let name):
            return "CLASS \(name)"
        default:
            return "CLASS \(fallbackClassName)"
        }
    }

    private func lookupInterfaceMethod(
        named normalizedName: String,
        interfaceName: String,
        in classDefinition: BASICClassDefinition
    ) -> FunctionDefinition? {
        guard let interfaceDefinition = interfaceDefinitions[interfaceName.uppercased()] else {
            return nil
        }
        return interfaceMember(named: normalizedName, in: interfaceDefinition).flatMap {
            method(for: $0.member, interface: $0.interface, in: classDefinition)
        }
    }

    private func interfaceMember(
        named normalizedName: String,
        in interfaceDefinition: BASICInterfaceDefinition
    ) -> (member: BASICInterfaceMember, interface: BASICInterfaceDefinition)? {
        for inheritedName in interfaceDefinition.inheritedInterfaces {
            if let inherited = interfaceDefinitions[inheritedName.uppercased()],
               let match = interfaceMember(named: normalizedName, in: inherited) {
                return match
            }
        }
        if let member = interfaceDefinition.members.first(where: { $0.normalizedName == normalizedName }) {
            return (member, interfaceDefinition)
        }
        return nil
    }

    private func validateMethodAccess(_ method: FunctionDefinition, receiverClass: String) throws {
        switch method.visibility {
        case .public:
            return
        case .private:
            guard currentClassContext?.uppercased() == method.ownerClassName?.uppercased() else {
                throw BASICError.runtime("\(method.displayName) is PRIVATE")
            }
        case .protected:
            guard let ownerClassName = method.ownerClassName,
                  let currentClassContext,
                  currentClassContext.uppercased() == ownerClassName.uppercased()
                    || isClass(currentClassContext, subclassOf: ownerClassName) else {
                throw BASICError.runtime("\(method.displayName) is PROTECTED")
            }
        }
    }

    private func isClass(_ className: String, subclassOf baseName: String) -> Bool {
        var current = classDefinitions[className.uppercased()]?.baseClassName
        while let currentName = current {
            if currentName.uppercased() == baseName.uppercased() {
                return true
            }
            current = classDefinitions[currentName.uppercased()]?.baseClassName
        }
        return false
    }

    private func callFunction(
        definition: FunctionDefinition,
        receiver: BASICValue?,
        receiverClassName: String?,
        arguments: [Expression],
        allowVoid: Bool
    ) throws -> FunctionCallResult {
        guard allowVoid || definition.returnType != .void else {
            throw BASICError.runtime("VOID function \(definition.displayName) cannot be used in an expression")
        }
        guard arguments.count == definition.parameters.count else {
            throw BASICError.runtime("Function \(definition.displayName) expects \(definition.parameters.count) arguments, got \(arguments.count)")
        }
        guard functionStack.count < 512 else {
            throw BASICError.runtime("Function call depth exceeded")
        }

        let values = try arguments.map(evaluate)
        let localContextIndex = runtime.pushLocalContext()
        if let receiver {
            try runtime.assign(
                kind: .local,
                variable: VariableName(name: "ME", column: 0),
                declaredType: definition.ownerClassName.map(BASICType.classType),
                value: receiver
            )
        }
        for (parameter, value) in zip(definition.parameters, values) {
            try runtime.assign(kind: .local, variable: parameter.variable, declaredType: parameter.type, value: value)
        }

        functionStack.append(FunctionFrame(
            definition: definition,
            receiverClassName: receiverClassName,
            localContextIndex: localContextIndex,
            returnValue: runtime.defaultValue(for: definition.returnType)
        ))
        defer {
            _ = functionStack.popLast()
            runtime.popLocalContext()
        }

        if let bodyExpression = definition.bodyExpression {
            let value = try runtime.coerce(
                try evaluate(bodyExpression),
                to: definition.returnType,
                variable: VariableName(name: definition.displayName, column: 0)
            )
            return FunctionCallResult(value: value, receiver: receiver)
        }

        func resultValue() -> FunctionCallResult {
            let value = functionStack.last?.returnValue ?? runtime.defaultValue(for: definition.returnType)
            let receiver = receiver == nil ? nil : runtime.value(for: VariableName(name: "ME", column: 0))
            return FunctionCallResult(value: value, receiver: receiver)
        }

        var labelIndexByName: [String: Int] = [:]
        if definition.startIndex < definition.endIndex {
            for index in (definition.startIndex + 1)..<definition.endIndex {
                if let label = parsedLines[index].statement.label {
                    labelIndexByName[label.uppercased()] = index
                }
            }
        }

        var pc = definition.startIndex + 1
        let parsed = parsedLines
        do {
            while pc < definition.endIndex {
                updateExecutionLocation(parsed[pc])
                try executionControl?.checkBreak()
                let flow = try execute(parsed[pc].statement, pc: pc, parsed: parsed)
                switch flow {
                case .next:
                    pc += 1
                case .jump(let index):
                    pc = index
                case .goto(let line):
                    guard let index = lineIndexByNumber[line] else { throw BASICError.missingLine(line) }
                    pc = index
                case .gotoLabel(let label):
                    guard let index = labelIndexByName[label.uppercased()] ?? lineIndexByLabel[label.uppercased()] else {
                        throw BASICError.missingLabel(label)
                    }
                    pc = index
                case .returnTo(let index):
                    pc = index
                case .exitSelect:
                    guard let index = matchingEndSelect(after: pc, in: parsed) else {
                        throw BASICError.runtime("EXIT SELECT without SELECT")
                    }
                    pc = index + 1
                case .functionReturn:
                    return resultValue()
                case .end:
                    return resultValue()
                }

                if executionControl?.shouldPauseAfterStep(callDepth: debugCallDepth) == true {
                    if pc < definition.endIndex {
                        updateExecutionLocation(parsed[pc])
                        throw BASICError.stepComplete(parsed[pc].breakpointLocation)
                    }
                }
            }
        } catch let error as BASICError {
            if error.isDebugPause {
                snapshotPausedDebugState()
            }
            throw error
        }

        return resultValue()
    }

    private func assignFunctionReturnIfNeeded(variable: VariableName, declaredType: BASICType?, value: BASICValue?) throws -> Bool {
        guard let frame = functionStack.last, variable.normalized == frame.definition.normalizedName else {
            return false
        }
        guard declaredType == nil else {
            throw BASICError.type(message: "Cannot redeclare function return \(variable.name)")
        }
        try setFunctionReturn(value)
        return true
    }

    private func setFunctionReturn(_ value: BASICValue?) throws {
        guard var frame = functionStack.popLast() else {
            throw BASICError.runtime("RETURN outside FUNCTION")
        }
        if frame.definition.returnType == .void {
            if value != nil {
                functionStack.append(frame)
                throw BASICError.type(message: "VOID function \(frame.definition.displayName) cannot return a value")
            }
            frame.didReturn = true
            functionStack.append(frame)
            return
        }
        let coerced = try runtime.coerce(
            value ?? runtime.defaultValue(for: frame.definition.returnType),
            to: frame.definition.returnType,
            variable: VariableName(name: frame.definition.displayName, column: 0)
        )
        frame.returnValue = coerced
        frame.didReturn = true
        functionStack.append(frame)
    }

    private func blockIfFlow(_ condition: Expression, pc: Int, parsed: [ParsedLine]) throws -> Flow {
        if try evaluate(condition).truthy {
            return .next
        }

        var depth = 0
        var index = pc + 1
        while index < parsed.count {
            switch parsed[index].statement {
            case .blockIf:
                depth += 1
            case .endIf:
                if depth == 0 {
                    return .jump(index + 1)
                }
                depth -= 1
            case .elseIf(let condition) where depth == 0:
                if try evaluate(condition).truthy {
                    return .jump(index + 1)
                }
            case .elseBlock where depth == 0:
                return .jump(index + 1)
            default:
                break
            }
            index += 1
        }

        throw BASICError.runtime("IF without END IF")
    }

    private func matchingEndIf(after pc: Int, in parsed: [ParsedLine]) -> Int? {
        var depth = 0
        var index = pc + 1
        while index < parsed.count {
            switch parsed[index].statement {
            case .blockIf:
                depth += 1
            case .endIf:
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

    private func loadProgram(path: String) throws {
        guard let fileHost = host as? BASICFileHost else {
            throw BASICError.runtime("LOAD is not supported by this host")
        }
        do {
            program.loadSource(try fileHost.loadTextFile(path: path), fileName: path)
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

    private func changeDirectory(path: Expression?) throws {
        guard let fileHost = host as? BASICFileHost else {
            throw BASICError.runtime("CD is not supported by this host")
        }
        guard let path else {
            host?.printLine(try fileHost.currentDirectoryPath())
            return
        }
        let resolvedPath = try string(path)
        do {
            try fileHost.changeDirectory(path: resolvedPath)
        } catch let error as BASICError {
            throw error
        } catch {
            throw BASICError.runtime("Could not change directory to \(resolvedPath): \(error.localizedDescription)")
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

    private func openLegacyFile(path: Expression, mode: BASICLegacyFileMode, number: Expression) throws {
        guard let fileHost = host as? BASICFileHost else {
            throw BASICError.runtime("File I/O is not supported by this host")
        }
        let handle = try legacyFileHandle(number)
        guard legacyFiles[handle]?.isOpen != true else {
            throw BASICError.runtime("File Already Open")
        }
        let resolvedPath = try string(path)
        let exists = try fileHost.fileExists(path: resolvedPath)
        let content: BASICString
        let position: Int
        let access: BASICFileAccess
        switch mode {
        case .input:
            guard exists else { throw BASICError.runtime("File Not Found") }
            let text = try fileHost.loadTextFile(path: resolvedPath)
            content = BASICString(text)
            position = 0
            access = .read
        case .output:
            content = BASICString("")
            position = 0
            access = .write
            try fileHost.saveTextFile(path: resolvedPath, text: "")
        case .append:
            let text = exists ? try fileHost.loadTextFile(path: resolvedPath) : ""
            content = BASICString(text)
            position = text.count
            access = .write
        }
        legacyFiles[handle] = BASICOpenFile(
            path: resolvedPath,
            access: access,
            contentType: .text,
            isOpen: true,
            content: content,
            position: position
        )
    }

    private func closeLegacyFile(number: Expression?) throws {
        if let number {
            let handle = try legacyFileHandle(number)
            guard var file = legacyFiles[handle], file.isOpen else {
                throw BASICError.runtime("Bad file number")
            }
            file.isOpen = false
            legacyFiles[handle] = file
            return
        }

        for handle in legacyFiles.keys {
            legacyFiles[handle]?.isOpen = false
        }
    }

    private func resetLegacyFile(number: Expression) throws {
        let handle = try legacyFileHandle(number)
        guard var file = legacyFiles[handle], file.isOpen else {
            throw BASICError.runtime("Bad file number")
        }
        file.position = 0
        legacyFiles[handle] = file
    }

    private func printLegacyFile(number: Expression, parts: [PrintPart]) throws {
        let handle = try legacyFileHandle(number)
        var file = try writableLegacyFile(handle: handle)
        let rendered = try renderPrint(parts)
        let path = try legacyOpenPath(file)
        let text = rendered.text + rendered.terminator
        file.content = file.content.concatenating(BASICString(text))
        file.position = file.content.rawString.count
        try legacyFileHost().saveTextFile(path: path, text: file.content.rawString)
        legacyFiles[handle] = file
    }

    private func printLegacyFileUsing(number: Expression, format: Expression, values: [Expression], trailingSeparator: PrintSeparator?) throws {
        let handle = try legacyFileHandle(number)
        var file = try writableLegacyFile(handle: handle)
        let rendered = try renderUsing(format: format, values: values, trailingSeparator: trailingSeparator)
        let path = try legacyOpenPath(file)
        let text = rendered.text + rendered.terminator
        file.content = file.content.concatenating(BASICString(text))
        file.position = file.content.rawString.count
        try legacyFileHost().saveTextFile(path: path, text: file.content.rawString)
        legacyFiles[handle] = file
    }

    private func inputLegacyFile(number: Expression, targets: [ReadTarget]) throws {
        let handle = try legacyFileHandle(number)
        var fields: [String] = []
        while fields.count < targets.count {
            guard let line = try readLegacyLine(handle: handle) else {
                throw BASICError.runtime("Input past end")
            }
            fields.append(contentsOf: parseLegacyInputFields(line))
        }
        for (target, field) in zip(targets, fields) {
            try assignLegacyInput(field, to: target)
        }
    }

    private func lineInputLegacyFile(number: Expression, target: ReadTarget) throws {
        let handle = try legacyFileHandle(number)
        guard let line = try readLegacyLine(handle: handle) else {
            throw BASICError.runtime("Input past end")
        }
        try assignReadValue(.string(BASICString(line)), to: target)
    }

    private func legacyEOF(_ number: Expression) throws -> BASICValue {
        let handle = try legacyFileHandle(number)
        let file = try readableLegacyFile(handle: handle)
        return .boolean(file.position >= file.content.rawString.count)
    }

    private func intrinsicInputString(name: String, arguments: [Expression]) throws -> BASICValue {
        try requireArgumentRange(name, arguments, 1...2)
        let count = try integer(arguments[0])
        guard count >= 0 else { throw BASICError.runtime("INPUT$ requires a non-negative length") }
        guard count > 0 else { return .string(BASICString("")) }

        if arguments.count == 2 {
            let handle = try legacyFileHandle(arguments[1])
            return .string(try readLegacyCharacters(handle: handle, count: count))
        }

        let encoding: BASICKeyEncoding = runtime.keyMode == .ibm ? .ibm : .aibasic
        var result = ""
        if let keyboardHost = host as? BASICBlockingKeyboardHost {
            while result.count < count, let rawKey = keyboardHost.readBlockingKey() {
                result += BASICKeyNormalizer.normalize(rawKey, encoding: encoding)
            }
        } else if let keyboardHost = host as? BASICKeyboardHost {
            while result.count < count, let rawKey = keyboardHost.readKey(), !rawKey.isEmpty {
                result += BASICKeyNormalizer.normalize(rawKey, encoding: encoding)
            }
        }
        return .string(BASICString(String(result.prefix(count))))
    }

    private func readLegacyCharacters(handle: Int, count: Int) throws -> BASICString {
        var file = try readableLegacyFile(handle: handle)
        let raw = file.content.rawString
        guard file.position < raw.count else {
            legacyFiles[handle] = file
            throw BASICError.runtime("Input past end")
        }
        let start = raw.index(raw.startIndex, offsetBy: file.position)
        let end = raw.index(start, offsetBy: count, limitedBy: raw.endIndex) ?? raw.endIndex
        let value = String(raw[start..<end])
        file.position = raw.distance(from: raw.startIndex, to: end)
        legacyFiles[handle] = file
        return BASICString(value)
    }

    private func readLegacyLine(handle: Int) throws -> String? {
        var file = try readableLegacyFile(handle: handle)
        let raw = file.content.rawString
        guard file.position < raw.count else {
            legacyFiles[handle] = file
            return nil
        }
        let start = raw.index(raw.startIndex, offsetBy: file.position)
        if let newline = raw[start...].firstIndex(of: "\n") {
            let lineEnd = newline > start && raw[raw.index(before: newline)] == "\r" ? raw.index(before: newline) : newline
            let line = String(raw[start..<lineEnd])
            file.position = raw.distance(from: raw.startIndex, to: raw.index(after: newline))
            legacyFiles[handle] = file
            return line
        }
        let line = String(raw[start...])
        file.position = raw.count
        legacyFiles[handle] = file
        return line
    }

    private func parseLegacyInputFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let character = iterator.next() {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == "," && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    private func assignLegacyInput(_ field: String, to target: ReadTarget) throws {
        try assignReadValue(try inputValue(from: field, to: target), to: target)
    }

    private func assignReadValue(_ value: BASICValue, to target: ReadTarget) throws {
        switch target {
        case .variable(let variable):
            try runtime.assign(kind: .bare, variable: variable, declaredType: nil, value: value)
        case .reference(let reference):
            try runtime.assign(
                reference: reference,
                indexes: try reference.indexes.map(evaluate),
                fieldIndexes: try evaluatedFieldIndexes(for: reference),
                value: value,
                accessClassName: currentClassContext
            )
        }
    }

    private func inputValue(from raw: String, to target: ReadTarget) throws -> BASICValue {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let current = try currentValue(for: target)
        switch current {
        case .string:
            return .string(BASICString(raw))
        case .boolean:
            if trimmed.uppercased() == "TRUE" {
                return .boolean(true)
            }
            if trimmed.uppercased() == "FALSE" {
                return .boolean(false)
            }
            if trimmed == "1" {
                return .boolean(true)
            }
            if trimmed == "0" {
                return .boolean(false)
            }
            throw BASICError.runtime("Type Mismatch")
        case .number:
            guard let number = Double(trimmed) else {
                throw BASICError.runtime("Expected numeric input for \(inputTargetName(target))")
            }
            return .number(number)
        case .empty:
            if inputTargetName(target).hasSuffix("$") {
                return .string(BASICString(raw))
            }
            if trimmed.uppercased() == "TRUE" {
                return .boolean(true)
            }
            if trimmed.uppercased() == "FALSE" {
                return .boolean(false)
            }
            guard let number = Double(trimmed) else {
                throw BASICError.runtime("Type Mismatch")
            }
            return .number(number)
        default:
            throw BASICError.runtime("Type Mismatch")
        }
    }

    private func currentValue(for target: ReadTarget) throws -> BASICValue {
        switch target {
        case .variable(let variable):
            return runtime.value(for: variable)
        case .reference(let reference):
            return try runtime.value(
                for: reference,
                indexes: try reference.indexes.map(evaluate),
                fieldIndexes: try evaluatedFieldIndexes(for: reference),
                accessClassName: currentClassContext
            )
        }
    }

    private func inputTargetName(_ target: ReadTarget) -> String {
        switch target {
        case .variable(let variable):
            return variable.name
        case .reference(let reference):
            return ([reference.base.name] + reference.fields).joined(separator: ".")
        }
    }

    private func readableLegacyFile(handle: Int) throws -> BASICOpenFile {
        guard let file = legacyFiles[handle], file.isOpen else {
            throw BASICError.runtime("Bad file number")
        }
        guard file.access == .read else {
            throw BASICError.runtime("Bad file mode")
        }
        return file
    }

    private func writableLegacyFile(handle: Int) throws -> BASICOpenFile {
        guard let file = legacyFiles[handle], file.isOpen else {
            throw BASICError.runtime("Bad file number")
        }
        guard file.access == .write else {
            throw BASICError.runtime("Bad file mode")
        }
        return file
    }

    private func legacyFileHandle(_ expression: Expression) throws -> Int {
        let handle = try integer(expression)
        guard handle > 0 else {
            throw BASICError.runtime("Bad file number")
        }
        return handle
    }

    private func legacyFileHost() throws -> BASICFileHost {
        guard let fileHost = host as? BASICFileHost else {
            throw BASICError.runtime("File I/O is not supported by this host")
        }
        return fileHost
    }

    private func legacyOpenPath(_ file: BASICOpenFile) throws -> String {
        guard let path = file.path else { throw BASICError.runtime("File is not open") }
        return path
    }

    private func runSystemCommand(_ expression: Expression) throws -> String {
        guard let systemHost = host as? BASICSystemHost else {
            throw BASICError.runtime("SYSTEM is not supported by this host")
        }
        return try systemHost.runSystemCommand(try string(expression))
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

    private func renderPrint(_ parts: [PrintPart], startColumn: Int = 0) throws -> PrintOutput {
        var output = ""
        var column = startColumn
        let tabWidth = 14

        for part in parts {
            switch part {
            case .expression(let expression):
                if let spacing = try printSpacing(for: expression, column: column) {
                    output += spacing
                    column += spacing.count
                    continue
                }
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
        return PrintOutput(text: output, terminator: terminator, endColumn: column)
    }

    private func renderUsing(format: Expression, values: [Expression], trailingSeparator: PrintSeparator?, startColumn: Int = 0) throws -> PrintOutput {
        let format = try string(format)
        let rendered = try formatUsing(format: format, values: try values.map(evaluate))
        return PrintOutput(text: rendered, terminator: trailingSeparator == nil ? "\n" : "", endColumn: startColumn + rendered.count)
    }

    private func updateOutputColumn(_ output: PrintOutput) {
        if output.terminator.contains("\n") {
            outputColumn = 0
        } else {
            outputColumn = output.endColumn
        }
    }

    private func updateOutputColumn(text: String, terminator: String) {
        let combined = text + terminator
        if let lastNewline = combined.lastIndex(of: "\n") {
            outputColumn = combined.distance(from: combined.index(after: lastNewline), to: combined.endIndex)
        } else {
            outputColumn += combined.count
        }
    }

    private func formatUsing(format: String, values: [BASICValue]) throws -> String {
        guard !values.isEmpty else { return format }

        var rendered = ""
        var valueIndex = 0
        while valueIndex < values.count {
            let startIndex = valueIndex
            let pass = try formatUsingPass(format: format, values: values, valueIndex: &valueIndex)
            if pass.fieldCount == 0 {
                if rendered.isEmpty {
                    rendered += format
                }
                break
            }
            rendered += pass.text
            if valueIndex == startIndex {
                break
            }
        }
        return rendered
    }

    private func formatUsingPass(format: String, values: [BASICValue], valueIndex: inout Int) throws -> (text: String, fieldCount: Int) {
        var output = ""
        var fieldCount = 0
        var index = format.startIndex

        while index < format.endIndex {
            let character = format[index]
            if character == "!" {
                guard valueIndex < values.count else { break }
                let value = values[valueIndex]
                valueIndex += 1
                fieldCount += 1
                output += String(value.description.prefix(1))
                index = format.index(after: index)
                continue
            }
            if character == "&" {
                guard valueIndex < values.count else { break }
                let value = values[valueIndex]
                valueIndex += 1
                fieldCount += 1
                output += value.description
                index = format.index(after: index)
                continue
            }
            if isNumericUsingCharacter(character) {
                let start = index
                while index < format.endIndex, isNumericUsingCharacter(format[index]) {
                    index = format.index(after: index)
                }
                let field = String(format[start..<index])
                if field.contains("#") {
                    guard valueIndex < values.count else { break }
                    let value = values[valueIndex]
                    valueIndex += 1
                    fieldCount += 1
                    output += try formatNumericUsingField(field, value: value)
                    continue
                }
                output += field
                continue
            }

            output.append(character)
            index = format.index(after: index)
        }

        return (output, fieldCount)
    }

    private func isNumericUsingCharacter(_ character: Character) -> Bool {
        "#.,+$-*".contains(character)
    }

    private func formatNumericUsingField(_ field: String, value: BASICValue) throws -> String {
        let number = try numeric(value)
        let decimalIndex = field.firstIndex(of: ".")
        let integerPattern = decimalIndex.map { String(field[..<$0]) } ?? field
        let fractionalPattern = decimalIndex.map { String(field[field.index(after: $0)...]) } ?? ""
        let fractionalDigits = fractionalPattern.filter { $0 == "#" }.count
        let usesGrouping = integerPattern.contains(",")
        let usesDollar = field.contains("$")
        let usesPlus = field.contains("+")
        let padCharacter: Character = field.contains("*") ? "*" : " "

        let absolute = abs(number)
        let scale = pow(10.0, Double(fractionalDigits))
        let roundedAbsolute = (absolute * scale).rounded() / scale
        let fixed = String(format: "%.\(fractionalDigits)f", roundedAbsolute)
        let pieces = fixed.split(separator: ".", omittingEmptySubsequences: false)
        var integerPart = String(pieces.first ?? "0")
        let fractionalPart = pieces.count > 1 ? String(pieces[1]) : ""
        if usesGrouping {
            integerPart = groupedDigits(integerPart)
        }

        var prefix = ""
        if number < 0 {
            prefix += "-"
        } else if usesPlus {
            prefix += "+"
        }
        if usesDollar {
            prefix += "$"
        }

        var rendered = prefix + integerPart
        if fractionalDigits > 0 {
            rendered += "." + fractionalPart
        }

        let width = field.count
        guard rendered.count <= width else {
            return String(repeating: "%", count: width)
        }
        return String(repeating: String(padCharacter), count: width - rendered.count) + rendered
    }

    private func groupedDigits(_ digits: String) -> String {
        var result = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 {
                result.append(",")
            }
            result.append(character)
        }
        return String(result.reversed())
    }

    private func printSpacing(for expression: Expression, column: Int) throws -> String? {
        let name: VariableName
        let arguments: [Expression]
        switch expression {
        case .callOrArray(let callName, let callArguments), .functionCall(let callName, let callArguments):
            name = callName
            arguments = callArguments
        default:
            return nil
        }

        switch name.normalized {
        case "SPC":
            let count = max(0, try singleIntegerArgument(name: name.name, arguments: arguments))
            return String(repeating: " ", count: count)
        case "TAB":
            let targetColumn = max(0, try singleIntegerArgument(name: name.name, arguments: arguments) - 1)
            return String(repeating: " ", count: max(0, targetColumn - column))
        default:
            return nil
        }
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
        case .null:
            return .null
        case .variable(let name):
            if name.normalized == "ERR" {
                return .number(Double(lastErrorNumber))
            }
            if name.normalized == "ERL" {
                return .number(Double(lastErrorLine))
            }
            if let constant = builtInConstant(named: name.normalized) {
                return constant
            }
            return runtime.value(for: name)
        case .variableReference(let reference):
            return try runtime.value(
                for: reference,
                indexes: try reference.indexes.map(evaluate),
                fieldIndexes: try evaluatedFieldIndexes(for: reference),
                accessClassName: currentClassContext
            )
        case .callOrArray(let name, let arguments):
            if name.normalized == "FILE" {
                return try constructFile(arguments: arguments)
            }
            if functionDefinitions[name.normalized] != nil {
                return try callFunction(name: name, arguments: arguments)
            }
            if Self.intrinsicFunctionNames.contains(name.normalized) {
                return try callIntrinsicFunction(name: name, arguments: arguments)
            }
            return try runtime.value(for: VariableReference(base: name, indexes: arguments), indexes: try arguments.map(evaluate), accessClassName: currentClassContext)
        case .methodCall(let receiver, let method, let arguments):
            return try callMethod(receiver: receiver, method: method, arguments: arguments)
        case .newObject(let className, let arguments):
            if className.uppercased() == "FILE" {
                return try constructFile(arguments: arguments)
            }
            guard let classDefinition = classDefinitions[className.uppercased()] else {
                throw BASICError.runtime("Unknown CLASS \(className)")
            }
            let object = runtime.defaultValue(for: .classType(className))
            guard !arguments.isEmpty || lookupMethod(named: "NEW", in: classDefinition) != nil else {
                return object
            }
            guard let constructor = lookupMethod(named: "NEW", in: classDefinition) else {
                throw BASICError.runtime("CLASS \(classDefinition.displayName) has no constructor")
            }
            let result = try callFunction(
                definition: constructor,
                receiver: object,
                receiverClassName: classDefinition.displayName,
                arguments: arguments,
                allowVoid: true
            )
            return result.receiver ?? object
        case .unaryMinus(let expression):
            guard let value = try evaluate(expression).number else {
                throw BASICError.runtime("Unary minus requires a number")
            }
            return .number(-value)
        case .binary(let left, let operation, let right):
            return try evaluateBinary(left, operation, right)
        case .await(let expression):
            return try evaluate(expression)
        case .functionCall(let name, let arguments):
            return try callFunction(name: name, arguments: arguments)
        case .pointFunction(let point):
            guard let graphicsHost = host as? BASICGraphicsHost else {
                throw BASICError.studioOnlyFeature
            }
            let resolved = try resolve(point: point)
            return .number(Double(graphicsHost.getPixel(x: resolved.x, y: resolved.y)))
        case .chrFunction(let expression):
            return .string(try BASICString.character(code: integer(expression)))
        case .lenFunction(let expression):
            let value = try evaluate(expression)
            if case .array(let array) = value {
                return .number(Double(array.values.count))
            }
            guard let string = value.string else {
                throw BASICError.runtime("LEN requires a string or array")
            }
            return .number(Double(string.characterCount))
        case .systemFunction(let expression):
            return .string(BASICString(try runSystemCommand(expression)))
        }
    }

    private func evaluatedFieldIndexes(for reference: VariableReference) throws -> [[BASICValue]] {
        try reference.fieldIndexes.map { indexes in
            try indexes.map(evaluate)
        }
    }

    private func builtInConstant(named normalized: String) -> BASICValue? {
        switch normalized {
        case "READ", "WRITE", "BOTH", "RAW", "TEXT", "JSON":
            return .string(BASICString(normalized))
        default:
            return nil
        }
    }

    private func constructFile(arguments: [Expression]) throws -> BASICValue {
        let file = runtime.fileObject()
        guard arguments.isEmpty || arguments.count == 4 else {
            throw BASICError.runtime("File expects 0 or 4 arguments")
        }
        if arguments.count == 4 {
            guard case .systemObject(let typeName, let id) = file else { return file }
            _ = try runtime.callSystemObjectMethod(
                typeName: typeName,
                id: id,
                method: "open",
                arguments: try arguments.map(evaluate),
                fileHost: host as? BASICFileHost,
                jsonDecoder: { [runtime] source in try runtime.valueFromJSONString(source, permissive: true) },
                jsonEncoder: { [runtime] value, pretty in try runtime.jsonString(for: value, pretty: pretty) }
            )
        }
        return file
    }

    private func evaluateBinary(_ leftExpression: Expression, _ operation: BinaryOperation, _ rightExpression: Expression) throws -> BASICValue {
        if operation == .add {
            return try evaluateAddChain(leftExpression, rightExpression)
        }

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

    private func evaluateAddChain(_ leftExpression: Expression, _ rightExpression: Expression) throws -> BASICValue {
        var terms: [Expression] = [rightExpression]
        var cursor = leftExpression

        while case .binary(let left, .add, let right) = cursor {
            terms.append(right)
            cursor = left
        }

        var value = try evaluate(cursor)
        for expression in terms.reversed() {
            let right = try evaluate(expression)
            if let leftString = value.string, let rightString = right.string {
                value = .string(leftString.concatenating(rightString))
            } else {
                value = .number(try numeric(value) + numeric(right))
            }
        }
        return value
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

    private func rawString(_ expression: Expression) throws -> String {
        guard let string = try evaluate(expression).string else {
            throw BASICError.runtime("Expected a string")
        }
        return string.rawString
    }

    private func boolean(_ value: BASICValue) throws -> Bool {
        switch value {
        case .boolean(let boolean):
            return boolean
        case .number(let number) where number == 0:
            return false
        case .number(let number) where number == 1:
            return true
        default:
            throw BASICError.runtime("Expected a boolean")
        }
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
    let displayLineNumber: Int
    let fileName: String?
    let sourceLineNumber: Int
    let statementNumber: Int
    let isImported: Bool
    let statement: Statement

    var breakpointLocation: BASICBreakpointLocation {
        BASICBreakpointLocation(fileName: fileName, lineNumber: sourceLineNumber, statementNumber: statementNumber)
    }

    static func flatten(number: Int?, fileName: String?, sourceLineNumber: Int, isImported: Bool, statement: Statement) -> [ParsedLine] {
        let displayLineNumber = number ?? sourceLineNumber
        guard case .sequence(let statements) = statement else {
            return [
                ParsedLine(
                    number: number,
                    displayLineNumber: displayLineNumber,
                    fileName: fileName,
                    sourceLineNumber: sourceLineNumber,
                    statementNumber: 0,
                    isImported: isImported,
                    statement: statement
                )
            ]
        }

        return statements.enumerated().map { index, statement in
            ParsedLine(
                number: index == 0 ? number : nil,
                displayLineNumber: displayLineNumber,
                fileName: fileName,
                sourceLineNumber: sourceLineNumber,
                statementNumber: index,
                isImported: isImported,
                statement: statement
            )
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
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
    case functionReturn
    case end
}

private indirect enum Statement: Equatable {
    case empty
    case remark
    case label(String)
    case labeled(String, Statement)
    case sequence([Statement])
    case importDirective(String)
    case typeDeclaration(name: String)
    case typeField(name: String, type: BASICType, fixedLength: Int?, arrayDimensions: [Int?], json: BASICJSONFieldOptions?, metadata: BASICMetadata, defaultValue: BASICValue?)
    case endType
    case interfaceDeclaration(name: String)
    case interfaceFunctionSignature(name: VariableName, parameters: [FunctionParameter], returnType: BASICType)
    case endInterface
    case classDeclaration(name: String)
    case implementsDeclaration(String)
    case inheritsDeclaration(String)
    case classField(name: String, type: BASICType, visibility: BASICMemberVisibility, arrayDimensions: [Int?], json: BASICJSONFieldOptions?, metadata: BASICMetadata, defaultValue: BASICValue?)
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
    case data([BASICValue])
    case read([ReadTarget])
    case restore
    case print([PrintPart])
    case printUsing(format: Expression, values: [Expression], trailingSeparator: PrintSeparator?)
    case log(level: Expression, parts: [PrintPart])
    case module(Expression)
    case screen(Expression)
    case color(Expression)
    case cls
    case locate(row: Expression, column: Expression)
    case pset(GraphicsPoint, Expression?)
    case preset(GraphicsPoint, Expression?)
    case line(GraphicsPoint, GraphicsPoint, Expression?)
    case assignment(AssignmentKind, VariableName, BASICType?, Expression?)
    case referenceAssignment(VariableReference, Expression?)
    case expression(Expression)
    case dim(AssignmentKind, VariableName, [Expression?], BASICType?)
    case optionLetMode(LetMode)
    case optionKeyMode(BASICKeyMode)
    case input(prompt: Expression?, target: ReadTarget)
    case lineInput(prompt: Expression?, target: ReadTarget, exitTarget: ReadTarget?, fieldLength: Expression?, maxLength: Expression?, defaultValue: Expression?)
    case openFile(path: Expression, mode: BASICLegacyFileMode, number: Expression)
    case closeFile(Expression?)
    case putFile(number: Expression, parts: [PrintPart])
    case getFile(number: Expression, targets: [ReadTarget])
    case resetFile(Expression)
    case printFile(number: Expression, parts: [PrintPart])
    case printFileUsing(number: Expression, format: Expression, values: [Expression], trailingSeparator: PrintSeparator?)
    case inputFile(number: Expression, targets: [ReadTarget])
    case lineInputFile(number: Expression, target: ReadTarget)
    case load(Expression)
    case save(Expression?)
    case cd(Expression?)
    case files
    case system(Expression)
    case yield
    case randomize(Expression?)
    case goto(Int)
    case gotoLabel(String)
    case computedGoto([BranchTarget], Expression)
    case computedGosub([BranchTarget], Expression)
    case onErrorGoto(BranchTarget?)
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
    let endColumn: Int
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
    case null
    case variable(VariableName)
    case variableReference(VariableReference)
    case callOrArray(VariableName, [Expression])
    case methodCall(VariableReference, VariableName, [Expression])
    case newObject(String, [Expression])
    case unaryMinus(Expression)
    case binary(Expression, BinaryOperation, Expression)
    case await(Expression)
    case functionCall(VariableName, [Expression])
    case pointFunction(GraphicsPoint)
    case chrFunction(Expression)
    case lenFunction(Expression)
    case systemFunction(Expression)
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
    case hash
    case dot
    case leftParen
    case rightParen
    case leftBrace
    case rightBrace
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
        if character.isNumber || (character == "." && nextCharacter?.isNumber == true) {
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
        case "#": token = .hash
        case "=": token = .equals
        case "+": token = .plus
        case "-": token = .minus
        case "*": token = .star
        case "/": token = .slash
        case ".": token = .dot
        case "(": token = .leftParen
        case ")": token = .rightParen
        case "{": token = .leftBrace
        case "}": token = .rightBrace
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

    private var nextCharacter: Character? {
        let next = source.index(after: index)
        return next < source.endIndex ? source[next] : nil
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
            return try parseFunctionDeclaration(visibility: .public, isOverride: false, isAsync: false)
        }
        if matchIdentifier("ASYNC") {
            guard matchIdentifier("FUNCTION") else { throw syntax("Expected FUNCTION after ASYNC") }
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
            let color = try parseExpression()
            return .color(color)
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
        let selector = try parseExpression()
        if matchIdentifier("GOTO") {
            return .computedGoto(try parseBranchTargetList(), selector)
        }
        if matchIdentifier("GOSUB") {
            return .computedGosub(try parseBranchTargetList(), selector)
        }
        throw syntax("Expected GOTO or GOSUB after ON expression")
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
        "LABEL", "REM", "PRINT", "PRINT#", "LOG", "MODULE", "USING", "USING$", "SCREEN", "COLOR", "CLS", "LOCATE", "PSET", "PRESET", "LINE",
        "LET", "GLOBAL", "LOCAL", "OPTION", "INPUT", "INPUT#", "OPEN", "CLOSE", "PUT", "GET", "RESET", "DATA", "READ", "RESTORE", "LOAD", "SAVE", "CD", "FILES", "SYSTEM", "YIELD", "ON", "ERROR", "RESUME", "GOTO", "GOSUB", "RETURN", "IF",
        "IMPORT", "TYPE", "INTERFACE", "CLASS", "IMPLEMENTS", "INHERITS", "PUBLIC", "PRIVATE", "PROTECTED", "OVERRIDES", "VIRTUAL",
        "FUNCTION", "DEF", "VOID", "VARIANT", "NEW", "ME", "FOR", "TO", "STEP", "NEXT", "SELECT", "CASE", "ELSEIF", "ELSE", "EXIT", "END", "STOP", "PAUSE"
    ]
}
