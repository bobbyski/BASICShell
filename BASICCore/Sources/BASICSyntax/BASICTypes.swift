import Foundation

// The declaration-level types the parser produces and both the interpreter
// and the compiler consume: BASIC types, names, parameters, modes. Values a
// running program holds live in BASICCore; the only value-like thing here is
// a literal (BASICLiteral.swift).

public enum BASICLegacyFileMode: String, Equatable, Sendable {
    case input = "INPUT"
    case output = "OUTPUT"
    case append = "APPEND"
    case binary = "BINARY"
    case random = "RANDOM"
}

public enum BASICScalarType: String, Equatable, Sendable {
    case integer = "INTEGER"
    case double = "DOUBLE"
    case string = "STRING"
    case boolean = "BOOLEAN"
    case variant = "VARIANT"
    case task = "TASK"
}

public enum BASICType: Equatable, Sendable {
    case scalar(BASICScalarType)
    case void
    case record(String)
    case classType(String)
    case interfaceType(String)
    case functionType(String)
    case dictionary
}

public struct BASICTypeSpec: Equatable {
    public let type: BASICType
    public let fixedLength: Int?

    /// Creates a value from its parts.
    public init(type: BASICType, fixedLength: Int?) {
        self.type = type
        self.fixedLength = fixedLength
    }
}

public struct BASICJSONFieldOptions: Equatable {
    public let name: String

    /// Creates a value from its parts.
    public init(name: String) {
        self.name = name
    }
}

public struct BASICExplicitInterfaceImplementation: Equatable {
    public let interfaceName: String
    public let normalizedInterfaceName: String
    public let memberName: String
    public let normalizedMemberName: String

    /// Creates a value from its parts.
    public init(interfaceName: String, normalizedInterfaceName: String, memberName: String, normalizedMemberName: String) {
        self.interfaceName = interfaceName
        self.normalizedInterfaceName = normalizedInterfaceName
        self.memberName = memberName
        self.normalizedMemberName = normalizedMemberName
    }
}

public enum BASICMemberVisibility: String, Equatable, Sendable {
    case `public` = "PUBLIC"
    case `private` = "PRIVATE"
    case `protected` = "PROTECTED"
}

public enum LetMode: Equatable, Sendable {
    case global
    case local
}

public enum BASICKeyMode: Equatable, Sendable {
    case aibasic
    case ibm
}

public enum BASICEventInputMode: Equatable, Sendable {
    case auto
    case on
    case off
}

public enum AssignmentKind: Equatable, Sendable {
    case bare
    case letValue
    case global
    case local
}

public struct VariableName: Equatable {
    public let name: String
    public let column: Int

    public var normalized: String { name.uppercased() }

    /// Creates a value from its parts.
    public init(name: String, column: Int) {
        self.name = name
        self.column = column
    }
}

public struct VariableReference: Equatable {
    public let base: VariableName
    public var indexes: [Expression]
    public var declarationDimensions: [Expression?]
    public var fields: [String]
    public var fieldIndexes: [[Expression]]
    public var hasEmptyIndexList: Bool

    public init(base: VariableName, indexes: [Expression] = [], declarationDimensions: [Expression?] = [], fields: [String] = [], fieldIndexes: [[Expression]] = [], hasEmptyIndexList: Bool = false) {
        self.base = base
        self.indexes = indexes
        self.declarationDimensions = declarationDimensions
        self.fields = fields
        self.fieldIndexes = fields.enumerated().map { index, _ in
            fieldIndexes.indices.contains(index) ? fieldIndexes[index] : []
        }
        self.hasEmptyIndexList = hasEmptyIndexList
    }

    public var isSimple: Bool {
        indexes.isEmpty && declarationDimensions.isEmpty && fields.isEmpty && fieldIndexes.isEmpty && !hasEmptyIndexList
    }
}

/// How an async/captured-value reference is allowed to interact with storage.
public enum BASICCapturedReferenceAccess: String, Sendable {
    /// The reference may read and update the target value.
    case strongMutable = "Strong Mutable"
    /// The reference may read the target value but should not update it.
    case readOnly = "Read Only"
    /// Reserved for future object references that should not keep the target alive.
    case weak = "Weak"
}

public struct FunctionParameter: Equatable {
    public let variable: VariableName
    public let type: BASICType

    /// Creates a value from its parts.
    public init(variable: VariableName, type: BASICType) {
        self.variable = variable
        self.type = type
    }
}

public struct ClosureCaptureSpec: Equatable {
    public let variable: VariableName
    public let access: BASICCapturedReferenceAccess

    /// Creates a value from its parts.
    public init(variable: VariableName, access: BASICCapturedReferenceAccess) {
        self.variable = variable
        self.access = access
    }
}

public enum ReadTarget: Equatable {
    case variable(VariableName)
    case reference(VariableReference)
}

extension BASICType {
    /// The type as BASIC spells it: `INTEGER`, `VOID`, or the record/class name.
    public var name: String {
        switch self {
        case .scalar(let scalar): return scalar.rawValue
        case .void: return "VOID"
        case .record(let name): return name
        case .classType(let name): return name
        case .interfaceType(let name): return name
        case .functionType(let name): return name
        case .dictionary: return "DICTIONARY"
        }
    }
}
