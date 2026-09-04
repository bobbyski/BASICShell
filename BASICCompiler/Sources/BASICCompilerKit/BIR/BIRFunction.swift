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

/// Where a `READ` puts a value.
public enum BIRReadTarget: Sendable {
    /// A scalar variable.
    case variable(BIRVariable)
    /// An array element.
    case element(BIRVariable, [BIRExpression])
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
    /// `DIM`: (re)creates an array with the given upper bounds.
    case dim(BIRVariable, [BIRExpression])
    /// Calls a `FUNCTION` for its effect, discarding any value.
    case call(String, [BIRExpression])
    /// `READ` the next DATA items into the targets.
    case read([BIRReadTarget])
    /// `RESTORE`: rewind DATA.
    case restore
    /// Marks the start of statement `id` on display line `line`, so a
    /// runtime error knows its `ERL` and where `RESUME NEXT` continues.
    /// Emitted only when the program uses `ON ERROR`.
    case markStatement(id: Int, line: Int)
    /// `ON ERROR GOTO target` (a handler index into
    /// ``BIRFunction/errorHandlerBlocks``) or `ON ERROR GOTO 0` (nil).
    case onError(handler: Int?)
    /// `ERROR n`: raise error number n.
    case raise(BIRExpression)
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

    /// Creates an empty module.
    public init(name: String) {
        self.name = name
        self.globals = []
        self.main = BIRFunction(name: "main")
        self.functions = []
        self.data = []
    }
}
