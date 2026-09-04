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

/// What an instruction does. Instructions never transfer control; that is
/// the terminator's job.
public enum BIROperation: Sendable {
    /// Stores a value into a variable.
    case store(BIRVariable, BIRExpression)
    /// Prints items; `newline` is false when the statement ended in `;` or `,`.
    case print([BIRPrintItem], newline: Bool)
    /// Reads one value from the console into a variable.
    case input(prompt: BIRExpression?, into: BIRVariable)
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

/// A function: `main` for the program body, one per `FUNCTION` later.
public struct BIRFunction: Sendable {
    /// The name as it appears in IR.
    public let name: String
    /// Frame-local variables (hidden loop temporaries included).
    public var locals: [BIRVariable]
    /// The blocks; `blocks[0]` is the entry.
    public var blocks: [BIRBlock]

    /// Creates a function with an empty entry block.
    public init(name: String) {
        self.name = name
        self.locals = []
        self.blocks = [BIRBlock(id: 0, label: "entry")]
    }

    /// The blocks a terminator can reach.
    public static func successors(of terminator: BIRTerminator) -> [BIRBlockID] {
        switch terminator {
        case .jump(let target): return [target]
        case .branch(_, let then, let otherwise): return [then, otherwise]
        case .gosub(let target, let resume): return [target, resume]
        case .returnFromGosub, .end, .unterminated: return []
        }
    }

    /// Drops blocks nothing can reach — the code after a GOTO that the
    /// interpreter would never execute either — and renumbers the rest.
    public mutating func pruneUnreachableBlocks() {
        var reachable = Set<BIRBlockID>()
        var worklist: [BIRBlockID] = [0]
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
    }

    private static func renumber(_ terminator: BIRTerminator, _ map: [BIRBlockID: BIRBlockID]) -> BIRTerminator {
        switch terminator {
        case .jump(let target): return .jump(map[target]!)
        case .branch(let condition, let then, let otherwise): return .branch(condition, then: map[then]!, else: map[otherwise]!)
        case .gosub(let target, let resume): return .gosub(map[target]!, resume: map[resume]!)
        case .returnFromGosub, .end: return terminator
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

    /// Creates an empty module.
    public init(name: String) {
        self.name = name
        self.globals = []
        self.main = BIRFunction(name: "main")
    }
}
