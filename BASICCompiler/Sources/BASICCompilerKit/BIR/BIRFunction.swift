import Foundation

/// A basic block's identity within its function.
public typealias BIRBlockID = Int

/// One item of a `PRINT` statement.
public enum BIRPrintItem: Sendable {
    /// A value to render.
    case value(BIRExpression)
    /// `,` — advance to the next 14-column zone.
    case comma
    /// `TAB(n)` — pad to column n.
    case tab(BIRExpression)
    /// `SPC(n)` — n spaces.
    case spc(BIRExpression)
}

/// Somewhere a value can be stored: a variable, an array element, or a
/// field reached through either.
public indirect enum BIRPlace: Sendable {
    case variable(BIRVariable)
    case element(BIRVariable, [BIRExpression])
    case field(BIRPlace, index: Int, type: BIRType)
    /// An element of an array-typed place (an array field, or an array
    /// variable as a place).
    case arrayElement(BIRPlace, [BIRExpression], name: String)
    /// `d(key)` of a dictionary-typed place.
    case dictionaryEntry(BIRPlace, key: BIRExpression, name: String)
    /// `v(i, …)` of a VARIANT-typed place holding an array or dictionary.
    case valueEntry(BIRPlace, [BIRExpression], name: String)
    /// `v.Field` of a VARIANT-typed place holding a record or object.
    case valueField(BIRPlace, field: String, name: String)

    /// The type of the value the place holds. An array variable as a place
    /// has its whole-array type.
    public var type: BIRType {
        switch self {
        case .variable(let variable):
            if let rank = variable.rank { return .array(variable.type, rank: rank) }
            return variable.type
        case .element(let variable, _): return variable.type
        case .field(_, _, let type): return type
        case .arrayElement(let base, _, _): return base.type.elementType ?? .number
        case .dictionaryEntry, .valueEntry, .valueField: return .variant
        }
    }
}

/// One implementation a method call may dispatch to, by runtime type.
public struct BIRMethodCandidate: Sendable {
    /// The runtime type index of the receiver this candidate serves.
    public let typeIndex: Int
    /// The BIR function implementing it.
    public let function: String

    public init(typeIndex: Int, function: String) {
        self.typeIndex = typeIndex
        self.function = function
    }
}

/// Where a `READ` puts a value.
public enum BIRReadTarget: Sendable {
    /// A scalar variable.
    case variable(BIRVariable)
    /// An array element.
    case element(BIRVariable, [BIRExpression])
}

/// One `width AS var$` of a FIELD statement.
public struct BIRFieldSpec: Sendable {
    public let width: BIRExpression
    public let variable: BIRVariable

    public init(width: BIRExpression, variable: BIRVariable) {
        self.width = width
        self.variable = variable
    }
}

/// One `DATA` item.
public enum BIRDataItem: Sendable {
    case number(Double)
    case string(String)
}

/// What an instruction does. Instructions never transfer control; that is
/// the terminator's job.
public enum BIROperation: Sendable {
    /// Stores a value into a variable.
    case store(BIRVariable, BIRExpression)
    /// Stores a value into an array element.
    case storeElement(BIRVariable, [BIRExpression], BIRExpression)
    /// Stores a value into a field, mutating the record in place.
    case storeField(BIRPlace, BIRExpression)
    /// Stores a value into any other place: an element of an array field, a
    /// dictionary entry, or an entry reached through a VARIANT.
    case storePlace(BIRPlace, BIRExpression)
    /// `a = value` for a whole array (a variable or an array field): the
    /// boxed value is coerced to the array's declared shape, in place.
    case assignArray(BIRPlace, BIRExpression)
    /// Calls a method on the record at `receiver`: the receiver is copied
    /// in as `ME`, and written back afterwards — the interpreter's value
    /// semantics. The result, if any, lands in `result`. `candidates` has one
    /// entry for a statically bound call, more for a virtual one.
    case callMethod(receiver: BIRPlace, candidates: [BIRMethodCandidate], arguments: [BIRExpression], result: BIRVariable?)
    /// `DIM`: (re)creates an array with the given upper bounds; nil is an
    /// open `*` dimension (a dynamic array, empty until assigned).
    case dim(BIRVariable, [BIRExpression?])
    /// Calls a `FUNCTION` for its effect, discarding any value.
    case call(String, [BIRExpression])
    /// `READ` the next DATA items into the targets.
    case read([BIRReadTarget])
    /// `RESTORE`: rewind DATA.
    case restore
    /// `CLS`.
    case cls
    /// A `File.*` service call used as a statement.
    case fileService(method: String, arguments: [BIRExpression])
    /// A closure call used as a statement (a VOID closure, or a value dropped).
    case callClosure(BIRExpression, [BIRExpression])
    /// `OPEN path FOR mode AS #n [LEN = k]`: mode 0 input, 1 output,
    /// 2 append, 3 binary, 4 random.
    case openFile(path: BIRExpression, mode: Int, number: BIRExpression, recordLength: BIRExpression?)
    /// `FIELD #n, width AS var$, …`.
    case fieldFile(number: BIRExpression, fields: [BIRFieldSpec])
    /// `LSET`/`RSET var$ = value`.
    case setFieldString(BIRVariable, BIRExpression, rightAligned: Bool)
    /// `PUT #n[, record]`.
    case putRecord(number: BIRExpression, record: BIRExpression?)
    /// `GET #n[, record]`.
    case getRecord(number: BIRExpression, record: BIRExpression?)
    /// `SEEK #n, position`.
    case seekFile(number: BIRExpression, position: BIRExpression)
    /// `RESET #n`.
    case resetFile(BIRExpression)
    /// Evaluates an expression for its effect and drops the value.
    case discard(BIRExpression)
    /// `LOCATE row, column`.
    case locate(BIRExpression, BIRExpression)
    /// `FILES` inside a program: lists the working directory.
    case filesList
    /// `SYSTEM command`: runs it through the shell and prints its output.
    case systemCommand(BIRExpression)
    /// `SCREEN n`.
    case screen(BIRExpression)
    /// `COLOR fg[, bg]` — colors are strings or palette numbers, boxed.
    case color(BIRExpression, BIRExpression?)
    /// `PSET (x,y)[, color]` / `PRESET`.
    case pset(x: BIRExpression, y: BIRExpression, color: BIRExpression?, reset: Bool)
    /// `LINE (x1,y1)-(x2,y2)[, color]`.
    case gline(x1: BIRExpression, y1: BIRExpression, x2: BIRExpression, y2: BIRExpression, color: BIRExpression?)
    /// `CIRCLE (x,y), radius[, color][, aspect]`.
    case circle(x: BIRExpression, y: BIRExpression, radius: BIRExpression, color: BIRExpression?, aspect: BIRExpression?)
    /// `PAINT (x,y), color[, border]`.
    case paint(x: BIRExpression, y: BIRExpression, color: BIRExpression, border: BIRExpression?)
    /// `DRAW program$`.
    case draw(BIRExpression)
    /// `OPTION AIBASIC-KEYS` (0) / `OPTION IBM-KEYS` (1).
    case keyMode(Int)
    /// `LINE INPUT` with LENGTH/MAX/DEFAULT/EXITVAR: the text lands in
    /// `into`, the key that ended input (or "") in `exitInto`.
    case lineInputField(prompt: BIRExpression?, into: BIRVariable, exitInto: BIRVariable?, length: BIRExpression?, max: BIRExpression?, defaultText: BIRExpression?)
    /// `CLOSE #n`, or every file when nil.
    case closeFile(BIRExpression?)
    /// `PRINT #n, items` — rendered like PRINT, appended to the file.
    case printFile(number: BIRExpression, items: [BIRPrintItem], newline: Bool)
    /// `PRINT #n USING format; values`.
    case printFileUsing(number: BIRExpression, format: BIRExpression, values: [BIRExpression], newline: Bool)
    /// `WRITE #n, values` — quoted, comma-separated, one line.
    case writeFile(number: BIRExpression, values: [BIRExpression])
    /// `INPUT #n, targets`.
    case inputFile(number: BIRExpression, targets: [BIRReadTarget])
    /// `LINE INPUT #n, target`.
    case lineInputFile(number: BIRExpression, into: BIRVariable)
    /// Marks the start of statement `id` on display line `line`, so a
    /// runtime error knows its `ERL` and where `RESUME NEXT` continues.
    /// Emitted only when the program uses `ON ERROR`.
    case markStatement(id: Int, line: Int)
    /// `ON ERROR GOTO target` (a handler index into
    /// ``BIRFunction/errorHandlerBlocks``) or `ON ERROR GOTO 0` (nil).
    case onError(handler: Int?)
    /// `ERROR n`: raise error number n.
    case raise(BIRExpression)
    /// A GOTO/GOSUB to a line or label that does not exist: the
    /// interpreter's "Missing line N" error (number 8), raised when reached.
    case failMissing(String)
    /// The interpreter's "Type error: …" (number 13), raised when reached.
    case failType(String)
    /// Prints items; `newline` is false when the statement ended in `;` or `,`.
    case print([BIRPrintItem], newline: Bool)
    /// Reads one value from the console into a variable.
    case input(prompt: BIRExpression?, into: BIRVariable)
    /// Reads one whole line into a string variable.
    case lineInput(prompt: BIRExpression?, into: BIRVariable)
    /// `PRINT USING format; values` — `newline` is false after a trailing
    /// separator.
    case printUsing(format: BIRExpression, values: [BIRExpression], newline: Bool)
    /// `RANDOMIZE [seed]`.
    case randomize(BIRExpression?)
    /// Raises a runtime error unconditionally — the compiler knew this
    /// statement always fails here (e.g. `RETURN` with nothing to return to
    /// is detected at runtime, but `EXIT FUNCTION` outside a function is not).
    case fail(String)
}

/// An instruction with the source location it came from.
public struct BIRInstruction: Sendable {
    /// Where it came from.
    public let location: BIRLocation
    /// What it does.
    public let operation: BIROperation

    /// Creates an instruction.
    public init(_ operation: BIROperation, at location: BIRLocation) {
        self.operation = operation
        self.location = location
    }
}

/// How a block ends.
public enum BIRTerminator: Sendable {
    /// Unconditional jump.
    case jump(BIRBlockID)
    /// Branch on the truthiness of a value.
    case branch(BIRExpression, then: BIRBlockID, else: BIRBlockID)
    /// `GOSUB`: push `resume`, jump to `target`.
    case gosub(BIRBlockID, resume: BIRBlockID)
    /// `RETURN`: pop the most recent resume block and jump to it.
    case returnFromGosub
    /// `END`, or falling off the end of the program.
    case end
    /// Return from a `FUNCTION`, with the value when it has one.
    case ret(BIRExpression?)
    /// `RESUME NEXT`: continue at the statement after the one that failed.
    case resumeNext
    /// The block was never finished — a builder bug if it survives.
    case unterminated
}

/// A basic block: straight-line instructions and one terminator.
public struct BIRBlock: Sendable {
    /// Identity within the function.
    public let id: BIRBlockID
    /// A readable name for dumps and IR: `L100`, `if3.else`, `bb7`.
    public let label: String
    /// The instructions, in order.
    public var instructions: [BIRInstruction]
    /// How the block ends.
    public var terminator: BIRTerminator

    /// Creates an empty, unterminated block.
    public init(id: BIRBlockID, label: String) {
        self.id = id
        self.label = label
        self.instructions = []
        self.terminator = .unterminated
    }
}

/// A function: `main` for the program body, one per `FUNCTION`.
public struct BIRFunction: Sendable {
    /// The name as it appears in IR.
    public let name: String
    /// Parameters, in order; each is also a local.
    public var parameters: [BIRVariable]
    /// The value returned, or `.void`.
    public var returnType: BIRType
    /// Frame-local variables (parameters and hidden temporaries included).
    public var locals: [BIRVariable]
    /// For a closure body: the environment type whose fields are copied into
    /// the named locals at entry, in field order.
    public var environment: (type: String, locals: [BIRVariable])?
    /// The blocks; `blocks[0]` is the entry.
    public var blocks: [BIRBlock]
    /// For `main` when the program uses `ON ERROR`: the block that begins
    /// statement `id + 1`, i.e. where `RESUME NEXT` after statement `id` goes.
    public var statementResumeBlocks: [BIRBlockID] = []
    /// For `main`: the blocks `ON ERROR GOTO` can name, by handler index.
    public var errorHandlerBlocks: [BIRBlockID] = []

    /// Creates a function with an empty entry block.
    public init(name: String, parameters: [BIRVariable] = [], returnType: BIRType = .void) {
        self.name = name
        self.parameters = parameters
        self.returnType = returnType
        self.locals = parameters
        self.blocks = [BIRBlock(id: 0, label: "entry")]
    }

    /// The blocks a terminator can reach.
    public static func successors(of terminator: BIRTerminator) -> [BIRBlockID] {
        switch terminator {
        case .jump(let target): return [target]
        case .branch(_, let then, let otherwise): return [then, otherwise]
        case .gosub(let target, let resume): return [target, resume]
        case .returnFromGosub, .end, .ret, .resumeNext, .unterminated: return []
        }
    }

    /// Drops blocks nothing can reach — the code after a GOTO that the
    /// interpreter would never execute either — and renumbers the rest.
    public mutating func pruneUnreachableBlocks() {
        var reachable = Set<BIRBlockID>()
        // Resume and handler blocks are entered by runtime dispatch, so they
        // are roots too.
        var worklist: [BIRBlockID] = [0] + statementResumeBlocks + errorHandlerBlocks
        while let id = worklist.popLast() {
            guard reachable.insert(id).inserted else { continue }
            worklist.append(contentsOf: Self.successors(of: blocks[id].terminator))
        }
        let kept = blocks.filter { reachable.contains($0.id) }
        let renumbered = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($0.element.id, $0.offset) })
        blocks = kept.enumerated().map { index, block in
            var copy = BIRBlock(id: index, label: block.label)
            copy.instructions = block.instructions
            copy.terminator = Self.renumber(block.terminator, renumbered)
            return copy
        }
        statementResumeBlocks = statementResumeBlocks.map { renumbered[$0]! }
        errorHandlerBlocks = errorHandlerBlocks.map { renumbered[$0]! }
    }

    private static func renumber(_ terminator: BIRTerminator, _ map: [BIRBlockID: BIRBlockID]) -> BIRTerminator {
        switch terminator {
        case .jump(let target): return .jump(map[target]!)
        case .branch(let condition, let then, let otherwise): return .branch(condition, then: map[then]!, else: map[otherwise]!)
        case .gosub(let target, let resume): return .gosub(map[target]!, resume: map[resume]!)
        case .returnFromGosub, .end, .ret, .resumeNext: return terminator
        case .unterminated: return .end
        }
    }
}

/// A field's declared default value.
public enum BIRDefault: Sendable, Hashable {
    case number(Double)
    case string(String)
    case boolean(Bool)
    case null
    case empty
}

/// One field of a composite type.
public struct BIRField: Sendable {
    /// The normalized name.
    public let name: String
    /// The name as written.
    public let displayName: String
    /// The field's type; an array field has an `.array` type.
    public let type: BIRType
    /// Declared bounds for an array field (nil entries are `*`).
    public let dimensions: [Int?]
    /// The `json name`, when the field takes part in JSON.
    public let jsonName: String?
    /// The declared default, when the field has one.
    public let defaultValue: BIRDefault?
    /// Whether a numeric field (or array of numbers) was declared INTEGER.
    public let isInteger: Bool
    /// The field's `meta { … }` entries.
    public let metadata: [String: BIRDefault]

    public init(name: String, displayName: String? = nil, type: BIRType, dimensions: [Int?] = [], jsonName: String? = nil, defaultValue: BIRDefault? = nil, isInteger: Bool = false, metadata: [String: BIRDefault] = [:]) {
        self.name = name
        self.displayName = displayName ?? name
        self.type = type
        self.dimensions = dimensions
        self.jsonName = jsonName
        self.defaultValue = defaultValue
        self.isInteger = isInteger
        self.metadata = metadata
    }
}

/// A closure signature — the shape a closure value has.
public struct BIRSignature: Sendable {
    public let name: String
    public let parameterTypes: [BIRType]
    public let returnType: BIRType

    public init(name: String, parameterTypes: [BIRType], returnType: BIRType) {
        self.name = name
        self.parameterTypes = parameterTypes
        self.returnType = returnType
    }
}

/// A `TYPE` or `CLASS`, as the runtime needs to know it.
public struct BIRCompositeType: Sendable {
    /// The normalized name, as types are looked up.
    public let name: String
    /// The name as written, which is what `PRINT` shows in `<Name>`.
    public let displayName: String
    /// The runtime type index; also the position in ``BIRModule/types``.
    public let index: Int
    /// All fields, inherited ones first.
    public let fields: [BIRField]
    /// Whether this is a CLASS (else a TYPE record).
    public let isClass: Bool
    /// The base class's type index, when there is one.
    public let base: Int?

    public init(name: String, displayName: String, index: Int, fields: [BIRField], isClass: Bool = false, base: Int? = nil) {
        self.name = name
        self.displayName = displayName
        self.index = index
        self.fields = fields
        self.isClass = isClass
        self.base = base
    }
}

/// A whole program, ready to lower.
public struct BIRModule: Sendable {
    /// The module name, usually the source file's base name.
    public let name: String
    /// Program-wide variables.
    public var globals: [BIRVariable]
    /// The program body.
    public var main: BIRFunction
    /// User functions, in source order.
    public var functions: [BIRFunction]
    /// Every `DATA` item, in source order.
    public var data: [BIRDataItem]
    /// Every `TYPE` and `CLASS`, by runtime type index.
    public var types: [BIRCompositeType]
    /// Every closure signature, by name.
    public var signatures: [String: BIRSignature]
    /// Every variable named in a FIELD statement, normalized: the runtime
    /// mirrors their values for PUT and GET.
    public var fieldVariables: [String] = []

    /// Creates an empty module.
    public init(name: String) {
        self.name = name
        self.globals = []
        self.main = BIRFunction(name: "main")
        self.functions = []
        self.data = []
        self.types = []
        self.signatures = [:]
    }

    /// The type index of a composite type name.
    public func typeIndex(of name: String) -> Int? {
        types.first { $0.name == name }?.index
    }
}
