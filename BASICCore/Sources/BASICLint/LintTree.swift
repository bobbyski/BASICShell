import BASICSyntax
import Foundation

// The tree a rule reads.
//
// It is the program as the parser saw it, given a shape rules can walk:
// every statement is a node with a kind, a range, and children, and the
// blocks a program writes — a FUNCTION, an IF, a FOR, a SELECT, a TYPE —
// actually contain what is written inside them. The vocabulary is chosen to
// match CodeWatch's `LintNodeKind`, so its own complexity rules can run on
// BASIC unchanged.
//
// A parse error is a finding, never a crash: a linter that dies on the file
// it was asked about is worse than one that says the file will not parse.

/// Where something is, 1-based.
public struct LintRange: Sendable, Codable, Equatable {
    public let line: Int
    public let column: Int
    public let endLine: Int
    public let endColumn: Int

    public init(line: Int, column: Int, endLine: Int? = nil, endColumn: Int? = nil) {
        self.line = line
        self.column = column
        self.endLine = endLine ?? line
        self.endColumn = endColumn ?? column
    }
}

/// What a node is. The names are CodeWatch's where CodeWatch has one.
public enum LintNodeKind: String, Sendable, Codable {
    case program
    case routineDeclaration
    case typeDeclaration
    case block
    case branch
    case loop
    case selectCase
    case caseArm
    case gotoStatement
    case gosubStatement
    case label
    case assignment
    case declaration
    case callStatement
    case errorHandler
    case importDirective
    case dataStatement
    case readStatement
    case returnStatement
    case comment
    case optionStatement
    /// `END IF`, `NEXT`, `END FUNCTION` — part of the block, not of its body.
    case blockEnd
    case statement
}

/// One node of the tree.
public final class LintNode: @unchecked Sendable {
    public let kind: LintNodeKind
    public let range: LintRange
    /// The statement this node came from, for rules that need the detail.
    public let statement: Statement?
    /// A routine's, label's, or type's name, when it has one.
    public let name: String?
    /// The source text of the line, trimmed of nothing.
    public let text: String
    public private(set) var children: [LintNode] = []
    public private(set) weak var parent: LintNode?

    init(kind: LintNodeKind, range: LintRange, statement: Statement?, name: String? = nil, text: String = "") {
        self.kind = kind
        self.range = range
        self.statement = statement
        self.name = name
        self.text = text
    }

    func add(_ child: LintNode) {
        child.parent = self
        children.append(child)
    }

    /// This node and everything under it, depth first.
    public var descendants: [LintNode] {
        children + children.flatMap(\.descendants)
    }

    /// How deeply nested this node is inside blocks.
    public var depth: Int {
        var depth = 0
        var current = parent
        while let node = current {
            if node.kind != .program { depth += 1 }
            current = node.parent
        }
        return depth
    }
}

/// The whole program, and whatever stopped it parsing.
public struct LintTree: @unchecked Sendable {
    public let root: LintNode
    /// The parsed lines, in order — what whole-program rules count over.
    public let lines: [ParsedLine]
    /// The source, split into physical lines, for the rules that read text.
    public let sourceLines: [String]
    /// A parse failure, when the file did not parse.
    public let syntaxError: (line: Int, message: String)?

    /// Builds the tree for a file's text.
    public static func build(source: String, fileName: String?) -> LintTree {
        let programLines = ProgramLine.parse(source, fileName: fileName, isImported: false)
        let sourceLines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let root = LintNode(kind: .program, range: LintRange(line: 1, column: 1, endLine: max(1, sourceLines.count), endColumn: 1), statement: nil, name: fileName)

        let parsed: [ParsedLine]
        var failure: (line: Int, message: String)?
        do {
            parsed = try ProgramParser.parse(programLines)
        } catch let error as ProgramParser.Failure {
            failure = (error.lineNumber ?? 1, error.error.description)
            parsed = []
        } catch {
            failure = (1, "\(error)")
            parsed = []
        }

        var builder = Builder(root: root, sourceLines: sourceLines)
        for line in parsed { builder.add(line) }
        return LintTree(root: root, lines: parsed, sourceLines: sourceLines, syntaxError: failure)
    }

    /// Assembles nodes, opening and closing the blocks a program writes.
    private struct Builder {
        let root: LintNode
        let sourceLines: [String]
        /// The blocks currently open. An arm (`ELSE`, `ELSEIF`, `CASE`) is
        /// marked, because a closer pops every arm above the block and then
        /// the block — and an arm and its owner are both `.branch`, so the
        /// kind cannot tell them apart.
        var open: [(node: LintNode, isArm: Bool)] = []

        init(root: LintNode, sourceLines: [String]) {
            self.root = root
            self.sourceLines = sourceLines
        }

        var current: LintNode { open.last?.node ?? root }

        mutating func add(_ line: ParsedLine) {
            var statement = line.statement
            var labelName: String?
            if case .labeled(let name, let inner) = statement {
                labelName = name
                statement = inner
            }
            if case .label(let name) = statement {
                labelName = name
            }
            let text = sourceLines.indices.contains(line.sourceLineNumber - 1) ? sourceLines[line.sourceLineNumber - 1] : ""
            let column = Self.column(of: line, in: text)
            let range = LintRange(line: line.sourceLineNumber, column: column, endLine: line.sourceLineNumber, endColumn: max(column, text.count))

            if let labelName {
                current.add(LintNode(kind: .label, range: range, statement: .label(labelName), name: labelName, text: text))
                // A line that is only a label is that node and nothing else.
                if case .label = statement { return }
            }

            // Closers first, so `END IF` belongs to the block it closes —
            // and the closer is a node of its own, because a rule that
            // checks `NEXT j` against `FOR i` needs to see it.
            switch statement {
            case .endFunction, .endIf, .endType, .endClass, .endInterface, .endSelect, .nextLoop:
                current.add(LintNode(kind: .blockEnd, range: range, statement: statement, name: Self.name(of: statement), text: text))
                closeBlock()
                return
            case .elseBlock, .elseIf, .caseClause, .caseElse:
                // An arm closes the one before it and opens its own.
                if open.last?.isArm == true { open.removeLast() }
                let node = LintNode(kind: statementIsCase(statement) ? .caseArm : .branch, range: range, statement: statement, text: text)
                current.add(node)
                open.append((node, true))
                return
            default:
                break
            }

            let node = LintNode(kind: Self.kind(of: statement), range: range, statement: statement, name: Self.name(of: statement), text: text)
            current.add(node)
            if Self.opensBlock(statement) { open.append((node, false)) }
        }

        private func statementIsCase(_ statement: Statement) -> Bool {
            if case .caseClause = statement { return true }
            if case .caseElse = statement { return true }
            return false
        }

        /// Closes the innermost block: every arm above it, then it.
        private mutating func closeBlock() {
            while open.last?.isArm == true { open.removeLast() }
            if !open.isEmpty { open.removeLast() }
        }

        /// The column a statement starts at: the first non-space for the
        /// first statement on a line, and after the nth top-level colon for
        /// the ones that follow.
        static func column(of line: ParsedLine, in text: String) -> Int {
            guard line.statementNumber > 0 else {
                let leading = text.prefix { $0 == " " || $0 == "\t" }.count
                return leading + 1
            }
            var colons = 0
            var inString = false
            for (offset, character) in text.enumerated() {
                if character == "\"" { inString.toggle() }
                if character == ":" && !inString {
                    colons += 1
                    if colons == line.statementNumber { return offset + 2 }
                }
            }
            return 1
        }

        static func opensBlock(_ statement: Statement) -> Bool {
            switch statement {
            case .functionDeclaration, .typeDeclaration, .classDeclaration, .interfaceDeclaration,
                 .blockIf, .forLoop, .selectCase:
                return true
            default:
                return false
            }
        }

        static func kind(of statement: Statement) -> LintNodeKind {
            switch statement {
            case .functionDeclaration, .defFunction: return .routineDeclaration
            case .typeDeclaration, .classDeclaration, .interfaceDeclaration: return .typeDeclaration
            case .blockIf, .ifThen: return .branch
            case .forLoop: return .loop
            case .selectCase: return .selectCase
            case .goto, .gotoLabel, .computedGoto: return .gotoStatement
            case .gosub, .computedGosub: return .gosubStatement
            case .label: return .label
            case .assignment, .referenceAssignment, .closureAssignment: return .assignment
            case .dim, .typeField, .classField, .functionTypeDeclaration, .interfaceFunctionSignature: return .declaration
            case .expression: return .callStatement
            case .onErrorGoto, .resumeNext: return .errorHandler
            case .importDirective: return .importDirective
            case .data: return .dataStatement
            case .read, .restore: return .readStatement
            case .returnValue, .returnFromSubroutine, .exitFunction: return .returnStatement
            case .remark: return .comment
            case .optionLetMode, .optionKeyMode, .optionShellMode, .optionStringSubstitution, .optionEventInput:
                return .optionStatement
            default: return .statement
            }
        }

        static func name(of statement: Statement) -> String? {
            switch statement {
            case .functionDeclaration(let name, _, _, _, _, _, _): return name.name
            case .defFunction(let name, _, _, _): return name.name
            case .typeDeclaration(let name), .classDeclaration(let name), .interfaceDeclaration(let name): return name
            case .assignment(_, let name, _, _): return name.name
            case .closureAssignment(_, let name, _, _, _, _, _): return name.name
            case .dim(_, let name, _, _): return name.name
            case .forLoop(let variable, _, _, _): return variable.name
            case .label(let name): return name
            default: return nil
            }
        }
    }
}
