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

public enum BASICScalarType: String, Equatable, Hashable, Sendable {
    case integer = "INTEGER"
    case double = "DOUBLE"
    case string = "STRING"
    case boolean = "BOOLEAN"
    case variant = "VARIANT"
    case task = "TASK"
    /// A calendar date, no time and no zone (DB19).
    case date = "DATE"
    /// A wall-clock time, no date and no zone.
    case time = "TIME"
    /// Both together — VB's `DateTime`, and SQL's `TIMESTAMP`.
    case datetime = "DATETIME"
    /// An exact decimal, 28 significant digits, like VB's `Decimal`.
    ///
    /// Not a `DOUBLE` with a different name: money in binary floating point is
    /// a correctness bug rather than a fidelity loss, which is why every
    /// business database has this type and why the language now does.
    case decimal = "DECIMAL"

    /// The four DB19 types, which arrived together and share every rule that
    /// separates them from `DOUBLE`: exactness, and a literal of their own.
    public static let temporalAndExact: Set<BASICScalarType> = [.date, .time, .datetime, .decimal]
}

public enum BASICType: Equatable, Sendable {
    case scalar(BASICScalarType)
    case void
    case record(String)
    case classType(String)
    case interfaceType(String)
    case functionType(String)
    /// An `ENUM` name (E1). Payload-free, so the value *is* its number and
    /// this type says only which name table `PRINT` should consult — which
    /// the compiler resolves statically, exactly as Bobby required.
    case enumType(String)
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

/// What `DATABASE` says about a field.
///
/// Persistence is opt in (DB2), spelled exactly parallel to `JSON`:
///
/// ```
/// DATABASE [ EXCLUDE | [NAME "column"] [KEY] [INDEX] [UNIQUE] ]
/// ```
///
/// A field with no marker is not persisted, so adding a public field cannot
/// silently change a table. Absent options mean exactly that; `EXCLUDE` says
/// the same thing out loud, for a reader.
public struct BASICDatabaseFieldOptions: Equatable, Sendable {
    /// The column or document field name.
    public let name: String
    /// Whether this is the primary key (DB4).
    public let isKey: Bool
    /// Whether the column is indexed (DB9).
    public let isIndexed: Bool
    /// Whether the index rejects duplicates.
    public let isUnique: Bool

    /// Creates a value from its parts.
    ///
    /// Two implications are applied here rather than at every reader, so the
    /// modifiers do not have to be written together: `KEY` implies a unique
    /// index, and `UNIQUE` implies `INDEX`.
    public init(name: String, isKey: Bool = false, isIndexed: Bool = false, isUnique: Bool = false) {
        self.name = name
        self.isKey = isKey
        self.isUnique = isUnique || isKey
        self.isIndexed = isIndexed || isUnique || isKey
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

/// What a host does with a program's graphics when the program stops on a
/// break or an error: `OPTION GRAPHICS-ON-STOP` (BASIC-28).
public enum BASICGraphicsOnStop: Equatable, Sendable {
    /// Hide them, keeping the picture, so the error can be read. RUN or CLS
    /// shows the graphics again. The default.
    case hide
    /// Erase them.
    case clear
    /// Leave them showing.
    case keep
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

/// How a closure holds a variable it captures (Documents/CLOSURES.md,
/// Bobby's rulings C1–C5, 2026-10-15).
///
/// ```text
///   (no policy), MUTABLE   the variable itself, shared with the scope that made the closure
///   STRONG                 the closure's own copy, which it may change from call to call
///   READONLY, READ-ONLY    a copy frozen when the closure is made; assigning it is an error
///   WEAK                   an imported object, not kept alive
/// ```
public enum BASICCapturedReferenceAccess: String, Sendable {
    /// The closure and its scope share one variable: VB's rule, and the
    /// default (C1). `CAPTURES MUTABLE x` spells it out (C3).
    case shared = "Shared"
    /// The closure's own changeable copy, taken when it is made (C2).
    case strongCopy = "Strong Copy"
    /// A copy frozen when the closure is made (C4).
    case readOnly = "Read Only"
    /// An imported object the closure does not keep alive (C5).
    case weak = "Weak"

    /// Whether a closure may assign the variable.
    public var isWritable: Bool { self == .shared || self == .strongCopy }
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
        case .enumType(let name): return name
        case .dictionary: return "DICTIONARY"
        }
    }
}
