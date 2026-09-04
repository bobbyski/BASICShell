import Foundation

// BIR — the compiler's intermediate representation.
//
// Typed, resolved, and control-flow-graph shaped: every variable has a
// static type, every jump target is a block, and every operation that can
// fail carries the source location the runtime reports. Expressions stay
// trees (they lower to straight-line IR trivially); control flow is explicit.
//
//   BIRModule
//   ├── globals: [BIRVariable]
//   ├── main: BIRFunction ──── blocks: [BIRBlock] ── instructions + terminator
//   └── functions: [BIRFunction]
//
// The interpreter is the oracle: BIR models what the interpreter does, not
// what a textbook BASIC does. Comparisons yield the numbers 1 and 0, `+` on
// two strings concatenates, and truthiness is the interpreter's `truthy`.

/// The static type of a value.
public enum BIRType: String, Sendable, Hashable {
    /// A number. The interpreter keeps every number as a `Double`, so does BIR.
    case number
    /// A string, held by the runtime.
    case string
    /// `TRUE` / `FALSE` — distinct from numbers because `PRINT` renders them
    /// as words.
    case boolean
    /// No value; the type of a `SUB`-shaped call.
    case void
}

/// Where a variable's storage lives.
public enum BIRScope: Sendable, Hashable {
    /// Module-level storage, visible to the whole program.
    case global
    /// A slot in the enclosing function's frame.
    case local
}

/// Whether a variable holds one value or an array of them.
public enum BIRStorage: Sendable, Hashable {
    /// One value.
    case scalar
    /// A runtime array of `rank` dimensions; `type` is the element type.
    case array(rank: Int)
}

/// A resolved variable: a name, a type, and where it lives.
public struct BIRVariable: Sendable, Hashable {
    /// The BASIC name, uppercased, suffix included: `A$`, `COUNT%`.
    public let name: String
    /// The static type — of the elements, for an array.
    public let type: BIRType
    /// Where the storage lives.
    public let scope: BIRScope
    /// Scalar or array.
    public let storage: BIRStorage

    /// Creates a variable.
    public init(name: String, type: BIRType, scope: BIRScope, storage: BIRStorage = .scalar) {
        self.name = name
        self.type = type
        self.scope = scope
        self.storage = storage
    }

    /// The rank when this is an array, else nil.
    public var rank: Int? {
        if case .array(let rank) = storage { return rank }
        return nil
    }
}

/// Where an instruction came from, for diagnostics and debug info.
public struct BIRLocation: Sendable, Hashable {
    /// The source file, when known.
    public let file: String?
    /// The physical line, 1-based.
    public let line: Int
    /// The statement's index within a colon-separated line.
    public let statement: Int
    /// The line's BASIC line number, when it had one.
    public let lineNumber: Int?

    /// Creates a location.
    public init(file: String?, line: Int, statement: Int, lineNumber: Int?) {
        self.file = file
        self.line = line
        self.statement = statement
        self.lineNumber = lineNumber
    }
}
