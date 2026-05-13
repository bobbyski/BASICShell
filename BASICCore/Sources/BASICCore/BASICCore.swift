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
    case breakRequested(Int?)
    case breakpoint(BASICBreakpointLocation)
    case stepComplete(BASICBreakpointLocation)
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

public enum BASICDiagnosticSeverity: String, Codable, Sendable {
    case error
    case warning
}

public struct BASICDiagnostic: Codable, Equatable, Sendable {
    public let lineNumber: Int
    public let column: Int
    public let message: String
    public let severity: BASICDiagnosticSeverity

    public init(
        lineNumber: Int,
        column: Int,
        message: String,
        severity: BASICDiagnosticSeverity = .error
    ) {
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

indirect enum BASICValue: Equatable, CustomStringConvertible {
    case empty
    case number(Double)
    case string(BASICString)
    case boolean(Bool)
    case record(String, [String: BASICValue])
    case object(String, [String: BASICValue])
    case array(BASICArray)

    var description: String {
        switch self {
        case .empty:
            return ""
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
        case .array(let array):
            return "<ARRAY \(array.type.name)>"
        }
    }

    var truthy: Bool {
        switch self {
        case .empty: return false
        case .number(let value): return value != 0
        case .string(let value): return !value.description.isEmpty
        case .boolean(let value): return value
        case .record, .object, .array: return true
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

struct BASICArray: Equatable {
    let dimensions: [Int]
    let type: BASICType
    var values: [BASICValue]
}

public enum BASICVariableScope: String, Sendable {
    case local = "Local"
    case global = "Global"
}

public struct BASICVariableSnapshot: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let typeName: String
    public let value: String
    public let scope: BASICVariableScope
    public let children: [BASICVariableSnapshot]
}

public struct BASICCallStackFrame: Identifiable, Equatable, Sendable {
    public var id: String { "\(index):\(kind):\(name)" }
    public let index: Int
    public let kind: String
    public let name: String
    public let location: BASICBreakpointLocation?
    public let declaringClassName: String?
    public let receiverClassName: String?
    public let isOverride: Bool
}

enum BASICScalarType: String, Equatable {
    case integer = "INTEGER"
    case double = "DOUBLE"
    case string = "STRING"
    case boolean = "BOOLEAN"
    case variant = "VARIANT"
}

enum BASICType: Equatable {
    case scalar(BASICScalarType)
    case void
    case record(String)
    case classType(String)
    case interfaceType(String)
}

private struct BASICTypeSpec: Equatable {
    let type: BASICType
    let fixedLength: Int?
}

private struct BASICRecordField: Equatable {
    let displayName: String
    let normalizedName: String
    let type: BASICType
    let fixedLength: Int?
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

private struct BASICClassField: Equatable {
    let displayName: String
    let normalizedName: String
    let type: BASICType
    let visibility: BASICMemberVisibility
    let declaringClassName: String
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
    var fields: [String]

    init(base: VariableName, indexes: [Expression] = [], fields: [String] = []) {
        self.base = base
        self.indexes = indexes
        self.fields = fields
    }

    var isSimple: Bool {
        indexes.isEmpty && fields.isEmpty
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
    let startIndex: Int
    let endIndex: Int
    let ownerClassName: String?
    let visibility: BASICMemberVisibility
    let isOverride: Bool
    let explicitInterfaceImplementations: [BASICExplicitInterfaceImplementation]

    init(
        displayName: String,
        normalizedName: String,
        parameters: [FunctionParameter],
        returnType: BASICType,
        startIndex: Int,
        endIndex: Int,
        ownerClassName: String? = nil,
        visibility: BASICMemberVisibility = .public,
        isOverride: Bool = false,
        explicitInterfaceImplementations: [BASICExplicitInterfaceImplementation] = []
    ) {
        self.displayName = displayName
        self.normalizedName = normalizedName
        self.parameters = parameters
        self.returnType = returnType
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.ownerClassName = ownerClassName
        self.visibility = visibility
        self.isOverride = isOverride
        self.explicitInterfaceImplementations = explicitInterfaceImplementations
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

    func resetForRun() {
        globals.removeAll()
        locals.removeAll()
    }

    func clearAll() {
        resetForRun()
        letMode = .global
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

    func value(for reference: VariableReference, indexes: [Int], accessClassName: String? = nil) throws -> BASICValue {
        var value = value(for: reference.base)
        if !indexes.isEmpty {
            guard case .array(let array) = value else {
                throw BASICError.runtime("\(reference.base.name) is not an array")
            }
            value = try arrayValue(array, at: indexes, name: reference.base.name)
        }
        for field in reference.fields {
            guard let composite = value.compositeFields else {
                throw BASICError.runtime("\(reference.base.name) has no field \(field)")
            }
            let (recordName, fields) = composite
            let normalized = field.uppercased()
            try validateFieldAccess(typeName: recordName, fieldName: field, accessClassName: accessClassName)
            guard let fieldValue = fields[normalized] else {
                throw BASICError.runtime("\(recordName) has no field \(field)")
            }
            value = fieldValue
        }
        return value
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

    func dim(variable: VariableName, dimensions: [Int], declaredType: BASICType?) throws {
        try validateSuffix(variable: variable, declaredType: declaredType)
        guard !dimensions.isEmpty else {
            let type = resolvedDeclaredType(declaredType ?? inferredType(name: variable.name, value: nil))
            let binding = VariableBinding(displayName: variable.name, type: type, value: defaultValue(for: type))
            set(binding, in: targetContext(kind: .bare, normalized: variable.normalized), normalized: variable.normalized)
            return
        }
        guard dimensions.allSatisfy({ $0 >= 0 }) else {
            throw BASICError.runtime("DIM bounds must be non-negative")
        }
        let type = resolvedDeclaredType(declaredType ?? inferredType(name: variable.name, value: nil))
        let elementCount = dimensions.reduce(1) { $0 * ($1 + 1) }
        let array = BASICArray(
            dimensions: dimensions,
            type: type,
            values: Array(repeating: defaultValue(for: type), count: elementCount)
        )
        let binding = VariableBinding(displayName: variable.name, type: type, value: .array(array))
        set(binding, in: targetContext(kind: .bare, normalized: variable.normalized), normalized: variable.normalized)
    }

    func assign(reference: VariableReference, indexes: [Int], value: BASICValue?, accessClassName: String? = nil) throws {
        guard !reference.isSimple else {
            try assign(kind: .bare, variable: reference.base, declaredType: nil, value: value)
            return
        }

        let normalized = reference.base.normalized
        let context = targetContext(kind: .bare, normalized: normalized)
        guard var binding = binding(in: context, normalized: normalized) else {
            throw BASICError.runtime("\(reference.base.name) is not defined")
        }

        if !indexes.isEmpty {
            guard case .array(var array) = binding.value else {
                throw BASICError.runtime("\(reference.base.name) is not an array")
            }
            let offset = try arrayOffset(dimensions: array.dimensions, indexes: indexes, name: reference.base.name)
            if reference.fields.isEmpty {
                array.values[offset] = try coerce(value ?? defaultValue(for: array.type), to: array.type, variable: reference.base)
            } else {
                array.values[offset] = try assigningField(reference.fields, in: array.values[offset], value: value, accessClassName: accessClassName)
            }
            binding.value = .array(array)
            set(binding, in: context, normalized: normalized)
            return
        }

        binding.value = try assigningField(reference.fields, in: binding.value, value: value, accessClassName: accessClassName)
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
        if case .record(let name) = type, classDefinitions[name.uppercased()] != nil {
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
            case .empty: return .scalar(.variant)
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
            case .array(let array):
                return array.type
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
            if case .object(let valueName, let fields) = value, valueName.uppercased() == name.uppercased() {
                return .record(valueName, fields)
            }
            if case .empty = value {
                return defaultValue(for: type)
            }
            throw BASICError.type(message: "Cannot assign non-\(name) value to \(variable.name)")
        }
        if case .classType(let name) = type {
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
            if case .object(let valueName, _) = value,
               classConforms(valueName, toInterface: name) {
                return value
            }
            if case .empty = value {
                return .empty
            }
            throw BASICError.type(message: "Cannot assign non-\(name) object to \(variable.name)")
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
                ($0.normalizedName, defaultValue(for: $0.type))
            })
            return .record(definition.displayName, fields)
        case .classType(let name):
            guard let definition = classDefinitions[name.uppercased()] else {
                return .object(name, [:])
            }
            let fields = Dictionary(uniqueKeysWithValues: inheritedFields(for: definition).map {
                ($0.normalizedName, defaultValue(for: $0.type))
            })
            return .object(definition.displayName, fields)
        case .interfaceType:
            return .empty
        }
    }

    private func arrayValue(_ array: BASICArray, at indexes: [Int], name: String) throws -> BASICValue {
        try array.values[arrayOffset(dimensions: array.dimensions, indexes: indexes, name: name)]
    }

    private func arrayOffset(dimensions: [Int], indexes: [Int], name: String) throws -> Int {
        guard indexes.count == dimensions.count else {
            throw BASICError.runtime("\(name) expects \(dimensions.count) indexes")
        }
        var multiplier = 1
        var offset = 0
        for (index, upperBound) in zip(indexes.reversed(), dimensions.reversed()) {
            guard (0...upperBound).contains(index) else {
                throw BASICError.runtime("\(name) subscript out of range")
            }
            offset += index * multiplier
            multiplier *= upperBound + 1
        }
        return offset
    }

    private func assigningField(_ fields: [String], in recordValue: BASICValue, value: BASICValue?, accessClassName: String?) throws -> BASICValue {
        guard let first = fields.first else {
            return value ?? recordValue
        }
        guard let composite = recordValue.compositeFields else {
            throw BASICError.runtime("Cannot assign field \(first) on non-record value")
        }
        let recordName = composite.name
        var recordFields = composite.fields
        let fieldDefinitions = compositeFieldDefinitions(for: recordName)
        guard !fieldDefinitions.isEmpty else { throw BASICError.runtime("Unknown TYPE or CLASS \(recordName)") }
        let normalized = first.uppercased()
        guard let field = fieldDefinitions.first(where: { $0.normalizedName == normalized }) else {
            throw BASICError.runtime("\(recordName) has no field \(first)")
        }
        try validateAccess(to: field, from: accessClassName)
        let current = recordFields[normalized] ?? defaultValue(for: field.type)
        if fields.count == 1 {
            recordFields[normalized] = try coerce(value ?? defaultValue(for: field.type), to: field.type, variable: VariableName(name: field.displayName, column: 0))
        } else {
            recordFields[normalized] = try assigningField(Array(fields.dropFirst()), in: current, value: value, accessClassName: accessClassName)
        }
        switch recordValue {
        case .object:
            return .object(recordName, recordFields)
        default:
            return .record(recordName, recordFields)
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
                let value = fields[field.normalizedName] ?? defaultValue(for: field.type)
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
                let value = fields[field.normalizedName] ?? defaultValue(for: field.type)
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
                BASICClassField(displayName: $0.displayName, normalizedName: $0.normalizedName, type: $0.type, visibility: .public, declaringClassName: recordDefinition.normalizedName)
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
    func listFiles(path: String) throws -> [String]
}

public protocol BASICSystemHost: BASICHost {
    func runSystemCommand(_ command: String) throws -> String
}

public extension BASICFileHost {
    func saveTextFile(path: String, text: String) throws {
        throw BASICError.runtime("SAVE is not supported by this host")
    }

    func listFiles() throws -> [String] {
        throw BASICError.runtime("FILES is not supported by this host")
    }

    func listFiles(path: String) throws -> [String] {
        throw BASICError.runtime("Directory IMPORT is not supported by this host")
    }
}

public extension BASICSystemHost {
    func runSystemCommand(_ command: String) throws -> String {
        try BASICSystemCommand.run(command)
    }
}

public enum BASICSystemCommand {
    public static func run(_ command: String) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", command]
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

public enum BASICExecutionMode: Sendable {
    case run
    case stepInto
    case stepOver(depth: Int)
    case stepOut(depth: Int)
}

public final class BASICExecutionControl: @unchecked Sendable {
    private let lock = NSLock()
    private var breakRequested = false
    private var currentLineNumber: Int?
    private var currentLocation: BASICBreakpointLocation?
    private var breakpoints: [BASICBreakpointLocation] = []
    private var ignoredBreakpointLocation: BASICBreakpointLocation?
    private var mode: BASICExecutionMode = .run

    public init() {}

    public func reset() {
        lock.lock()
        breakRequested = false
        currentLineNumber = nil
        currentLocation = nil
        lock.unlock()
    }

    public func requestBreak() {
        lock.lock()
        breakRequested = true
        lock.unlock()
    }

    public var lineNumber: Int? {
        lock.lock()
        defer { lock.unlock() }
        return currentLineNumber
    }

    public var location: BASICBreakpointLocation? {
        lock.lock()
        defer { lock.unlock() }
        return currentLocation
    }

    public func setBreakpoints(_ breakpoints: [BASICBreakpoint]) {
        lock.lock()
        self.breakpoints = breakpoints.filter(\.isEnabled).map(\.location)
        lock.unlock()
    }

    public func setMode(_ mode: BASICExecutionMode) {
        lock.lock()
        self.mode = mode
        lock.unlock()
    }

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

public struct BASICBreakpointLocation: Hashable, Sendable {
    public var fileName: String?
    public var lineNumber: Int
    public var statementNumber: Int

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

public struct BASICBreakpoint: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var location: BASICBreakpointLocation
    public var isEnabled: Bool

    public init(id: UUID = UUID(), location: BASICBreakpointLocation, isEnabled: Bool = true) {
        self.id = id
        self.location = location
        self.isEnabled = isEnabled
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

public final class BASICProgram: @unchecked Sendable {
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
                lines.append(ProgramLine(number: number, source: trimmed, sourceLineNumber: nil, isImported: false))
            }
            lines.sort { ($0.number ?? Int.max) < ($1.number ?? Int.max) }
        }
    }

    public func loadSource(_ source: String) {
        lines = Self.parseLines(from: source, isImported: false)
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

    public var orderedLines: [(number: Int?, source: String, sourceLineNumber: Int?, isImported: Bool)] {
        lines.map { ($0.number, $0.source, $0.sourceLineNumber, $0.isImported) }
    }

    fileprivate static func importedLines(from source: String) -> [ProgramLine] {
        parseLines(from: source, isImported: true)
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

    private static func parseLines(from source: String, isImported: Bool) -> [ProgramLine] {
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
            .map { record in
                (lineNumber: record.lineNumber, source: record.source.trimmingCharacters(in: .whitespaces))
            }
            .filter { !$0.source.isEmpty }
            .map { record in
                if let numbered = splitNumberedLine(record.source) {
                    return ProgramLine(number: numbered.number, source: numbered.source, sourceLineNumber: record.lineNumber, isImported: isImported)
                }
                return ProgramLine(number: nil, source: record.source, sourceLineNumber: record.lineNumber, isImported: isImported)
            }
    }

    private static func joinContinuationLines(_ sourceLines: [(lineNumber: Int, source: String)]) -> [(lineNumber: Int, source: String)] {
        var joinedLines: [(lineNumber: Int, source: String)] = []
        var pending: (lineNumber: Int, source: String)?

        for sourceLine in sourceLines {
            let line = sourceLine.source.trimmingCharacters(in: .whitespaces)
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
}

private struct ProgramLine {
    let number: Int?
    var source: String
    var sourceLineNumber: Int?
    var isImported: Bool
}

private final class BASICFileState {
    var lastFilePath: String?
}

public final class BASICSession: @unchecked Sendable {
    public static let defaultPrompt = "READY\n> "

    public let program = BASICProgram()
    public var prompt: String

    private let host: BASICHost
    private let runtime = BASICRuntime()
    private let fileState = BASICFileState()
    private var activeInterpreter: BASICInterpreter?

    public init(host: BASICHost, prompt: String = BASICSession.defaultPrompt) {
        self.host = host
        self.prompt = prompt
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
                try runProgram(startLine: startLine)
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
                host.printLine("Commands: RUN, LIST, LOAD, SAVE, FILES, SYSTEM, NEW, CLEAR, HELP, QUIT")
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

    public func runProgram(startLine: Int? = nil, executionControl: BASICExecutionControl? = nil) throws {
        runtime.resetForRun()
        let interpreter = BASICInterpreter(
            program: program,
            host: host,
            runtime: runtime,
            fileState: fileState,
            executionControl: executionControl
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

    public var debugLocalVariables: [BASICVariableSnapshot] {
        activeInterpreter?.debugLocalVariables ?? runtime.localSnapshots()
    }

    public var debugGlobalVariables: [BASICVariableSnapshot] {
        activeInterpreter?.debugGlobalVariables ?? runtime.globalSnapshots()
    }

    public func diagnostics() -> [BASICDiagnostic] {
        BASICInterpreter(program: program, host: host, runtime: runtime, fileState: fileState).diagnostics()
    }

    public var debugCallStack: [BASICCallStackFrame] {
        activeInterpreter?.debugCallStack ?? []
    }

    public var debugFrameLocalVariables: [[BASICVariableSnapshot]] {
        activeInterpreter?.debugFrameLocalVariables ?? []
    }

    public var debugCallDepth: Int {
        activeInterpreter?.debugCallDepth ?? 0
    }

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
    private var executionControl: BASICExecutionControl?
    private var gosubStack: [GosubFrame] = []
    private var forStack: [ForFrame] = []
    private var functionStack: [FunctionFrame] = []
    private var functionDefinitions: [String: FunctionDefinition] = [:]
    private var recordDefinitions: [String: BASICRecordDefinition] = [:]
    private var interfaceDefinitions: [String: BASICInterfaceDefinition] = [:]
    private var classDefinitions: [String: BASICClassDefinition] = [:]
    private var lineIndexByNumber: [Int: Int] = [:]
    private var lineIndexByLabel: [String: Int] = [:]
    private var parsedLines: [ParsedLine] = []
    private var pausedDebugCallStack: [BASICCallStackFrame]?
    private var pausedDebugLocalVariables: [BASICVariableSnapshot]?
    private var pausedDebugFrameLocalVariables: [[BASICVariableSnapshot]]?
    private var pausedDebugGlobalVariables: [BASICVariableSnapshot]?
    private var pausedDebugCallDepth: Int?
    private var dataValues: [BASICValue] = []
    private var dataIndex = 0
    private var pc = 0
    private var isPrepared = false

    public convenience init(program: BASICProgram, host: BASICHost) {
        self.init(program: program, host: host, runtime: BASICRuntime(), fileState: BASICFileState(), executionControl: nil)
    }

    fileprivate init(
        program: BASICProgram,
        host: BASICHost,
        runtime: BASICRuntime,
        fileState: BASICFileState = BASICFileState(),
        executionControl: BASICExecutionControl? = nil
    ) {
        self.program = program
        self.host = host
        self.runtime = runtime
        self.fileState = fileState
        self.executionControl = executionControl
    }

    public func run(startLine: Int? = nil) throws {
        gosubStack.removeAll()
        forStack.removeAll()
        functionStack.removeAll()
        try prepare(startLine: startLine)
        try continueExecution()
    }

    fileprivate func setExecutionControl(_ executionControl: BASICExecutionControl?) {
        self.executionControl = executionControl
    }

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
                        sourceLineNumber: line.sourceLineNumber ?? index + 1,
                        fallbackColumn: 0
                    )
                )
            } catch {
                diagnostics.append(
                    BASICDiagnostic(
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
            let parsed = try sourceLines.enumerated().flatMap { index, line in
                var parser = try Parser(source: line.source)
                let statement = try parser.parseStatement()
                return ParsedLine.flatten(
                    number: line.number,
                    sourceLineNumber: line.sourceLineNumber ?? index + 1,
                    isImported: line.isImported,
                    statement: statement
                )
            }

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
        sourceLineNumber: Int,
        fallbackColumn: Int
    ) -> BASICDiagnostic {
        switch error {
        case .contextualSyntax(let message, _, let column):
            return BASICDiagnostic(lineNumber: sourceLineNumber, column: column, message: "Syntax error: \(message)")
        case .contextualType(let message, _, let column):
            return BASICDiagnostic(lineNumber: sourceLineNumber, column: column, message: "Type error: \(message)")
        case .syntax(let message):
            return BASICDiagnostic(lineNumber: sourceLineNumber, column: fallbackColumn, message: "Syntax error: \(message)")
        case .type(let message):
            return BASICDiagnostic(lineNumber: sourceLineNumber, column: fallbackColumn, message: "Type error: \(message)")
        default:
            return BASICDiagnostic(lineNumber: sourceLineNumber, column: fallbackColumn, message: error.description)
        }
    }

    private func diagnostic(for error: BASICError, parsed: [ParsedLine]) -> BASICDiagnostic {
        let line = sourceLineNumber(for: error, parsed: parsed) ?? 1
        return diagnostic(for: error, sourceLineNumber: line, fallbackColumn: 0)
    }

    private func sourceLineNumber(for error: BASICError, parsed: [ParsedLine]) -> Int? {
        let message = error.description
        var currentClassName: String?

        for line in parsed where !line.isImported {
            switch line.statement {
            case .classDeclaration(let name):
                currentClassName = name
                if message.contains("CLASS \(name)") && !message.contains(" method ") {
                    return line.sourceLineNumber
                }
            case .endClass:
                currentClassName = nil
            case .interfaceDeclaration(let name):
                if message.contains("INTERFACE \(name)") {
                    return line.sourceLineNumber
                }
            case .typeDeclaration(let name):
                if message.contains("TYPE \(name)") {
                    return line.sourceLineNumber
                }
            case .functionDeclaration(let name, _, _, _, _, _):
                let classMatches = currentClassName.map { message.contains("CLASS \($0)") } ?? true
                if classMatches && (message.contains("method \(name.name)") || message.contains("Function \(name.name)")) {
                    return line.sourceLineNumber
                }
            case .classField(let name, _, _), .typeField(let name, _, _):
                if message.contains("field \(name)") || message.contains(" \(name) ") {
                    return line.sourceLineNumber
                }
            case .interfaceFunctionSignature(let name, _, _):
                if message.contains(".\(name.name)") || message.contains("member \(name.name)") {
                    return line.sourceLineNumber
                }
            default:
                continue
            }
        }

        return parsed.first(where: { !$0.isImported })?.sourceLineNumber
    }

    private func prepare(startLine: Int?) throws {
        let sourceLines = try expandedProgramLines()
        let parsed = try sourceLines.enumerated().flatMap { index, line in
            var parser = try Parser(source: line.source)
            let statement = try parser.parseStatement()
            return ParsedLine.flatten(number: line.number, sourceLineNumber: line.sourceLineNumber ?? index + 1, isImported: line.isImported, statement: statement)
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

        pc = 0
        if let startLine {
            guard let index = lineIndexByNumber[startLine] else { throw BASICError.missingLine(startLine) }
            pc = index
        }
        isPrepared = true
    }

    private func expandedProgramLines() throws -> [ProgramLine] {
        var importedPaths: Set<String> = []
        return try expandedProgramLines(from: program.orderedLines.map {
            ProgramLine(number: $0.number, source: $0.source, sourceLineNumber: $0.sourceLineNumber, isImported: $0.isImported)
        }, importedPaths: &importedPaths)
    }

    private func expandedProgramLines(from lines: [ProgramLine], importedPaths: inout Set<String>) throws -> [ProgramLine] {
        var expanded: [ProgramLine] = []
        for line in lines {
            var parser = try Parser(source: line.source)
            if case .importDirective(let path) = try parser.parseStatement() {
                guard let fileHost = host as? BASICFileHost else {
                    throw BASICError.runtime("IMPORT is not supported by this host")
                }
                if Self.isDirectoryImportPath(path) {
                    for importedFile in try Self.importedBasFiles(in: path, using: fileHost) {
                        guard !importedPaths.contains(importedFile) else { continue }
                        importedPaths.insert(importedFile)
                        let imported = BASICProgram.importedLines(from: try fileHost.loadTextFile(path: importedFile))
                        expanded += try expandedProgramLines(from: imported, importedPaths: &importedPaths)
                    }
                } else {
                    guard !importedPaths.contains(path) else { continue }
                    importedPaths.insert(path)
                    let imported = BASICProgram.importedLines(from: try fileHost.loadTextFile(path: path))
                    expanded += try expandedProgramLines(from: imported, importedPaths: &importedPaths)
                }
            } else {
                expanded.append(line)
            }
        }
        return expanded
    }

    private static func isDirectoryImportPath(_ path: String) -> Bool {
        path.hasSuffix("/") || path.hasSuffix("\\")
    }

    private static func importedBasFiles(in path: String, using fileHost: BASICFileHost) throws -> [String] {
        let directory = path.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
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

    public func continueExecution() throws {
        clearPausedDebugSnapshots()
        if !isPrepared {
            try prepare(startLine: nil)
        }

        while pc < parsedLines.count {
            let current = parsedLines[pc]
            if current.isImported {
                pc += 1
                continue
            }
            updateExecutionLocation(current)
            try executionControl?.checkBreak()
            let next = try execute(current.statement, pc: pc, parsed: parsedLines)
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
                guard let index = matchingEndSelect(after: pc, in: parsedLines) else {
                    throw BASICError.runtime("EXIT SELECT without SELECT")
                }
                pc = index + 1
            case .functionReturn:
                throw BASICError.runtime("RETURN outside FUNCTION")
            }

            if executionControl?.shouldPauseAfterStep(callDepth: debugCallDepth) == true {
                if pc < parsedLines.count {
                    updateExecutionLocation(parsedLines[pc])
                    throw BASICError.stepComplete(parsedLines[pc].breakpointLocation)
                }
                return
            }
        }
    }

    private func updateExecutionLocation(_ line: ParsedLine) {
        executionControl?.update(lineNumber: line.displayLineNumber, location: line.breakpointLocation)
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
        case .empty, .remark, .data:
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
            if try assignFunctionReturnIfNeeded(variable: variable, declaredType: declaredType, value: value) {
                return .next
            }
            try runtime.assign(kind: kind, variable: variable, declaredType: declaredType, value: value)
            return .next
        case .referenceAssignment(let reference, let expression):
            let value = try expression.map(evaluate)
            try runtime.assign(reference: reference, indexes: try reference.indexes.map(integer), value: value, accessClassName: currentClassContext)
            return .next
        case .dim(let variable, let dimensions, let declaredType):
            try runtime.dim(variable: variable, dimensions: try dimensions.map(integer), declaredType: declaredType)
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
        case .files:
            try listFiles()
            return .next
        case .system(let command):
            let output = try runSystemCommand(command)
            if !output.isEmpty {
                host?.print(output, terminator: "")
            }
            return .next
        case .goto(let line):
            return .goto(line)
        case .gotoLabel(let label):
            return .gotoLabel(label)
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
            case .functionDeclaration(let name, let parameters, let returnType, _, _, _):
                guard let endIndex = matchingEndFunction(after: index, in: parsed) else {
                    throw BASICError.runtime("FUNCTION without END FUNCTION")
                }
                let definition = FunctionDefinition(
                    displayName: name.name,
                    normalizedName: name.normalized,
                    parameters: parameters,
                    returnType: returnType,
                    startIndex: index,
                    endIndex: endIndex
                )
                if definitions[name.normalized] != nil {
                    throw BASICError.runtime("Function \(name.name) is already defined")
                }
                definitions[name.normalized] = definition
                index = endIndex + 1
                continue
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
                    indexes: try reference.indexes.map(integer),
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
                case .typeField(let fieldName, let type, let fixedLength):
                    let normalizedField = fieldName.uppercased()
                    guard !fields.contains(where: { $0.normalizedName == normalizedField }) else {
                        throw BASICError.runtime("TYPE \(name) field \(fieldName) is already defined")
                    }
                    fields.append(
                        BASICRecordField(
                            displayName: fieldName,
                            normalizedName: normalizedField,
                            type: type,
                            fixedLength: fixedLength
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
                case .functionDeclaration(let memberName, let parameters, let returnType, _, _, _):
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
                case .classField(let fieldName, let type, let visibility):
                    let normalizedField = fieldName.uppercased()
                    guard !fields.contains(where: { $0.normalizedName == normalizedField }) else {
                        throw BASICError.runtime("CLASS \(name) field \(fieldName) is already defined")
                    }
                    fields.append(BASICClassField(displayName: fieldName, normalizedName: normalizedField, type: type, visibility: visibility, declaringClassName: normalized))
                case .typeField(let fieldName, let type, _):
                    let normalizedField = fieldName.uppercased()
                    guard !fields.contains(where: { $0.normalizedName == normalizedField }) else {
                        throw BASICError.runtime("CLASS \(name) field \(fieldName) is already defined")
                    }
                    fields.append(BASICClassField(displayName: fieldName, normalizedName: normalizedField, type: type, visibility: .public, declaringClassName: normalized))
                case .implementsDeclaration(let interfaceName):
                    interfaces.append(interfaceName)
                case .inheritsDeclaration(let baseClassName):
                    guard baseClassName.uppercased() != normalized else {
                        throw BASICError.runtime("CLASS \(name) cannot inherit itself")
                    }
                    baseClass = baseClassName
                case .functionDeclaration(let methodName, let parameters, let returnType, let visibility, let isOverride, let explicitInterfaceImplementations):
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

    private func callFunction(name: VariableName, arguments: [Expression]) throws -> BASICValue {
        guard let definition = functionDefinitions[name.normalized] else {
            throw BASICError.runtime("Unknown function \(name.name)")
        }
        return try callFunction(definition: definition, receiver: nil, receiverClassName: nil, arguments: arguments, allowVoid: false).value
    }

    private func callMethod(receiver: VariableReference, method: VariableName, arguments: [Expression]) throws -> BASICValue {
        let receiverValue = try runtime.value(for: receiver, indexes: try receiver.indexes.map(integer))
        guard case .object(let className, _) = receiverValue else {
            throw BASICError.runtime("\(receiver.base.name) is not an object")
        }
        guard let classDefinition = classDefinitions[className.uppercased()] else {
            throw BASICError.runtime("Unknown CLASS \(className)")
        }
        guard let definition = lookupMethod(named: method.normalized, in: classDefinition) else {
            throw BASICError.runtime("CLASS \(classDefinition.displayName) has no method \(method.name)")
        }
        try validateMethodAccess(definition, receiverClass: classDefinition.displayName)
        let result = try callFunction(
            definition: definition,
            receiver: receiverValue,
            receiverClassName: classDefinition.displayName,
            arguments: arguments,
            allowVoid: false
        )
        if let updatedReceiver = result.receiver {
            try runtime.assign(reference: receiver, indexes: try receiver.indexes.map(integer), value: updatedReceiver, accessClassName: currentClassContext)
        }
        return result.value
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

        func resultValue() -> FunctionCallResult {
            let value = functionStack.last?.returnValue ?? runtime.defaultValue(for: definition.returnType)
            let receiver = receiver == nil ? nil : runtime.value(for: VariableName(name: "ME", column: 0))
            return FunctionCallResult(value: value, receiver: receiver)
        }

        var pc = definition.startIndex + 1
        let parsed = parsedLines
        do {
            while pc < definition.endIndex {
                executionControl?.update(lineNumber: parsed[pc].displayLineNumber, location: parsed[pc].breakpointLocation)
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
                    guard let index = lineIndexByLabel[label.uppercased()] else { throw BASICError.missingLabel(label) }
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
                        executionControl?.update(lineNumber: parsed[pc].displayLineNumber, location: parsed[pc].breakpointLocation)
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
        case .variableReference(let reference):
            return try runtime.value(for: reference, indexes: try reference.indexes.map(integer), accessClassName: currentClassContext)
        case .callOrArray(let name, let arguments):
            if functionDefinitions[name.normalized] != nil {
                return try callFunction(name: name, arguments: arguments)
            }
            return try runtime.value(for: VariableReference(base: name, indexes: arguments), indexes: try arguments.map(integer), accessClassName: currentClassContext)
        case .methodCall(let receiver, let method, let arguments):
            return try callMethod(receiver: receiver, method: method, arguments: arguments)
        case .newObject(let className, let arguments):
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
            guard let string = try evaluate(expression).string else {
                throw BASICError.runtime("LEN requires a string")
            }
            return .number(Double(string.characterCount))
        case .systemFunction(let expression):
            return .string(BASICString(try runSystemCommand(expression)))
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
    let displayLineNumber: Int
    let sourceLineNumber: Int
    let statementNumber: Int
    let isImported: Bool
    let statement: Statement

    var breakpointLocation: BASICBreakpointLocation {
        BASICBreakpointLocation(lineNumber: sourceLineNumber, statementNumber: statementNumber)
    }

    static func flatten(number: Int?, sourceLineNumber: Int, isImported: Bool, statement: Statement) -> [ParsedLine] {
        let displayLineNumber = number ?? sourceLineNumber
        guard case .sequence(let statements) = statement else {
            return [ParsedLine(number: number, displayLineNumber: displayLineNumber, sourceLineNumber: sourceLineNumber, statementNumber: 0, isImported: isImported, statement: statement)]
        }

        return statements.enumerated().map { index, statement in
            ParsedLine(number: index == 0 ? number : nil, displayLineNumber: displayLineNumber, sourceLineNumber: sourceLineNumber, statementNumber: index, isImported: isImported, statement: statement)
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
    case typeField(name: String, type: BASICType, fixedLength: Int?)
    case endType
    case interfaceDeclaration(name: String)
    case interfaceFunctionSignature(name: VariableName, parameters: [FunctionParameter], returnType: BASICType)
    case endInterface
    case classDeclaration(name: String)
    case implementsDeclaration(String)
    case inheritsDeclaration(String)
    case classField(name: String, type: BASICType, visibility: BASICMemberVisibility)
    case endClass
    case functionDeclaration(
        name: VariableName,
        parameters: [FunctionParameter],
        returnType: BASICType,
        visibility: BASICMemberVisibility,
        isOverride: Bool,
        explicitInterfaceImplementations: [BASICExplicitInterfaceImplementation]
    )
    case endFunction
    case data([BASICValue])
    case read([ReadTarget])
    case restore
    case print([PrintPart])
    case screen(Expression)
    case color(Expression)
    case cls
    case pset(GraphicsPoint, Expression?)
    case preset(GraphicsPoint, Expression?)
    case line(GraphicsPoint, GraphicsPoint, Expression?)
    case assignment(AssignmentKind, VariableName, BASICType?, Expression?)
    case referenceAssignment(VariableReference, Expression?)
    case dim(VariableName, [Expression], BASICType?)
    case optionLetMode(LetMode)
    case input(String)
    case load(Expression)
    case save(Expression?)
    case files
    case system(Expression)
    case goto(Int)
    case gotoLabel(String)
    case gosub(BranchTarget)
    case returnFromSubroutine
    case returnValue(Expression)
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
    case variableReference(VariableReference)
    case callOrArray(VariableName, [Expression])
    case methodCall(VariableReference, VariableName, [Expression])
    case newObject(String, [Expression])
    case unaryMinus(Expression)
    case binary(Expression, BinaryOperation, Expression)
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
    case dot
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
        case "=": token = .equals
        case "+": token = .plus
        case "-": token = .minus
        case "*": token = .star
        case "/": token = .slash
        case ".": token = .dot
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
            return .print(try parsePrintParts())
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
            return try parseFunctionDeclaration(visibility: .public, isOverride: false)
        }
        if matchIdentifier("TYPE") {
            let name = try consumeIdentifier("Expected TYPE name")
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
            return try parseDim()
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
        if matchIdentifier("SYSTEM") {
            return .system(try parseExpression())
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
            if isStatementEnd {
                return .returnFromSubroutine
            }
            return .returnValue(try parseExpression())
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
            return try parseAssignment(kind: .bare, requiresEquals: true)
        }
        throw syntax("Unknown statement")
    }

    private mutating func parseDim() throws -> Statement {
        let variable = try consumeVariableName("Expected variable name after DIM")
        var dimensions: [Expression] = []
        if match(.leftParen) {
            repeat {
                dimensions.append(try parseExpression())
            } while match(.comma)
            guard match(.rightParen) else { throw syntax("Expected )") }
        }
        let declaredType = try parseOptionalType(for: variable)
        return .dim(variable, dimensions, declaredType)
    }

    private mutating func parseTypeField() throws -> Statement {
        let name = try consumeIdentifier("Expected field name")
        guard matchIdentifier("AS") else { throw syntax("Expected AS") }
        let typeSpec = try parseTypeSpec(allowVoid: false)
        return .typeField(name: name, type: typeSpec.type, fixedLength: typeSpec.fixedLength)
    }

    private mutating func parseModifiedMember() throws -> Statement {
        let visibility = parseVisibilityModifier() ?? .public
        let isOverride = matchIdentifier("OVERRIDES")
        _ = matchIdentifier("VIRTUAL")
        if matchIdentifier("FUNCTION") {
            return try parseFunctionDeclaration(visibility: visibility, isOverride: isOverride)
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
        guard matchIdentifier("AS") else { throw syntax("Expected AS") }
        let typeSpec = try parseTypeSpec(allowVoid: false)
        return .classField(name: name, type: typeSpec.type, visibility: visibility)
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

    private mutating func parseFunctionDeclaration(visibility: BASICMemberVisibility, isOverride: Bool) throws -> Statement {
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
            visibility: visibility,
            isOverride: isOverride,
            explicitInterfaceImplementations: explicitInterfaceImplementations
        )
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
        let declaredType = reference.isSimple ? try parseOptionalType(for: variable) : nil
        let expression: Expression?
        if match(.equals) {
            expression = try parseExpression()
        } else if requiresEquals {
            throw syntax("Expected =")
        } else {
            expression = nil
        }
        if !reference.isSimple {
            guard kind == .bare || kind == .letValue else {
                throw syntax("GLOBAL and LOCAL require simple variable names")
            }
            return .referenceAssignment(reference, expression)
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
            if uppercased == "NEW" {
                let className = try consumeIdentifier("Expected class name after NEW")
                let arguments = peek == .leftParen ? try parseArgumentList() : []
                return .newObject(className, arguments)
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
                while match(.dot) {
                    let fieldColumn = tokens[current].column
                    let fieldName = try consumeIdentifier("Expected field name after .")
                    if peek == .leftParen {
                        return .methodCall(
                            VariableReference(base: VariableName(name: name, column: column), indexes: arguments, fields: fields),
                            VariableName(name: fieldName, column: fieldColumn),
                            try parseArgumentList()
                        )
                    }
                    fields.append(fieldName)
                }
                if !fields.isEmpty {
                    return .variableReference(VariableReference(base: VariableName(name: name, column: column), indexes: arguments, fields: fields))
                }
                return .callOrArray(VariableName(name: name, column: column), arguments)
            }
            var reference = VariableReference(base: VariableName(name: name, column: column))
            while match(.dot) {
                let fieldColumn = tokens[current].column
                let fieldName = try consumeIdentifier("Expected field name after .")
                if peek == .leftParen {
                    return .methodCall(reference, VariableName(name: fieldName, column: fieldColumn), try parseArgumentList())
                }
                reference.fields.append(fieldName)
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
                arguments.append(try parseExpression())
            } while match(.comma)
            guard match(.rightParen) else { throw syntax("Expected )") }
        }
        return arguments
    }

    private mutating func parseVariableReference(message: String) throws -> VariableReference {
        let base = try consumeVariableName(message)
        var indexes: [Expression] = []
        if match(.leftParen) {
            repeat {
                indexes.append(try parseExpression())
            } while match(.comma)
            guard match(.rightParen) else { throw syntax("Expected )") }
        }
        var fields: [String] = []
        while match(.dot) {
            fields.append(try consumeIdentifier("Expected field name after ."))
        }
        return VariableReference(base: base, indexes: indexes, fields: fields)
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
        guard case .identifier(let next) = peekNext else { return false }
        return next.uppercased() == "AS"
    }

    private var isClassFieldDeclaration: Bool {
        guard case .identifier(let access) = peek else { return false }
        guard ["PUBLIC", "PRIVATE", "PROTECTED"].contains(access.uppercased()) else { return false }
        let nameIndex = current + 1
        let asIndex = current + 2
        guard asIndex < tokens.count else { return false }
        guard case .identifier = tokens[nameIndex].token else { return false }
        guard case .identifier(let asKeyword) = tokens[asIndex].token else { return false }
        return asKeyword.uppercased() == "AS"
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
        "LABEL", "REM", "PRINT", "SCREEN", "COLOR", "CLS", "PSET", "PRESET", "LINE",
        "LET", "GLOBAL", "LOCAL", "OPTION", "INPUT", "DATA", "READ", "RESTORE", "LOAD", "SAVE", "FILES", "SYSTEM", "GOTO", "GOSUB", "RETURN", "IF",
        "IMPORT", "TYPE", "INTERFACE", "CLASS", "IMPLEMENTS", "INHERITS", "PUBLIC", "PRIVATE", "PROTECTED", "OVERRIDES", "VIRTUAL",
        "FUNCTION", "VOID", "VARIANT", "NEW", "ME", "FOR", "TO", "STEP", "NEXT", "SELECT", "CASE", "ELSEIF", "ELSE", "EXIT", "END", "STOP"
    ]
}
