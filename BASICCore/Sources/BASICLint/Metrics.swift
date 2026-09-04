import BASICSyntax
import Foundation

// Complexity, measured per routine and per file.
//
// The rule ids match CodeWatch's — `complexity.cyclomatic`,
// `complexity.long_routine`, and the rest — with the same default
// thresholds, so one settings pane configures both. The metrics are a value
// as well as findings, because a host may want to score a file without
// showing anything.

/// What one routine (or the main program) measures.
public struct RoutineMetrics: Sendable, Codable, Equatable {
    /// The routine's name, or nil for the main program.
    public let name: String?
    public let line: Int
    /// Decision points plus one.
    public let cyclomaticComplexity: Int
    /// How deeply blocks nest inside it.
    public let nestingDepth: Int
    /// Statements it contains.
    public let length: Int
    public let parameterCount: Int
    /// The spaghetti measures, reported in both profiles.
    public let gotoCount: Int
    public let backwardJumpCount: Int
}

/// What one type measures.
public struct TypeMetrics: Sendable, Codable, Equatable {
    public let name: String
    public let line: Int
    public let fieldCount: Int
    public let methodCount: Int
}

/// Everything measured about a file.
public struct Metrics: Sendable, Codable, Equatable {
    public let routines: [RoutineMetrics]
    public let types: [TypeMetrics]
    public let lineCount: Int

    /// Measures a tree.
    public static func measure(_ tree: LintTree) -> Metrics {
        var routines: [RoutineMetrics] = []
        var types: [TypeMetrics] = []

        // The main program is everything not inside a routine or a type.
        let mainNodes = tree.root.children.filter { $0.kind != .routineDeclaration && $0.kind != .typeDeclaration }
        routines.append(measure(name: nil, line: 1, nodes: mainNodes, parameters: 0, tree: tree))

        for node in tree.root.descendants where node.kind == .routineDeclaration {
            var parameterCount = 0
            if case .functionDeclaration(_, let parameters, _, _, _, _, _)? = node.statement {
                parameterCount = parameters.count
            }
            routines.append(measure(name: node.name, line: node.range.line, nodes: node.children, parameters: parameterCount, tree: tree))
        }
        for node in tree.root.descendants where node.kind == .typeDeclaration {
            let fields = node.children.filter { child in
                switch child.statement {
                case .typeField?, .classField?: return true
                default: return false
                }
            }
            let methods = node.children.filter { $0.kind == .routineDeclaration }
            types.append(TypeMetrics(name: node.name ?? "", line: node.range.line, fieldCount: fields.count, methodCount: methods.count))
        }
        return Metrics(routines: routines, types: types, lineCount: tree.sourceLines.count)
    }

    private static func measure(name: String?, line: Int, nodes: [LintNode], parameters: Int, tree: LintTree) -> RoutineMetrics {
        let all = nodes + nodes.flatMap(\.descendants)
        var complexity = 1
        var gotoCount = 0
        var backwardJumps = 0
        var depth = 0
        for node in all {
            switch node.kind {
            case .branch, .loop, .caseArm:
                complexity += 1
            case .gotoStatement:
                complexity += 1
                gotoCount += 1
            case .gosubStatement, .errorHandler:
                complexity += 1
            default:
                break
            }
            complexity += Self.shortCircuits(in: node.statement)
            depth = max(depth, node.depth)
            if node.kind == .gotoStatement, Self.jumpsBackward(node, tree: tree) { backwardJumps += 1 }
        }
        let base = nodes.first?.depth ?? 0
        return RoutineMetrics(
            name: name, line: line,
            cyclomaticComplexity: complexity,
            nestingDepth: max(0, depth - base),
            length: all.count,
            parameterCount: parameters,
            gotoCount: gotoCount,
            backwardJumpCount: backwardJumps
        )
    }

    /// `AND` and `OR` are decision points too.
    private static func shortCircuits(in statement: Statement?) -> Int {
        func count(_ expression: BASICSyntax.Expression) -> Int {
            switch expression {
            case .binary(let left, let operation, let right):
                let own = (operation == .and || operation == .or) ? 1 : 0
                return own + count(left) + count(right)
            case .unaryMinus(let inner): return count(inner)
            default: return 0
            }
        }
        switch statement {
        case .blockIf(let condition), .elseIf(let condition): return count(condition)
        case .ifThen(let condition, _, _): return count(condition)
        default: return 0
        }
    }

    /// Whether a branch goes to a line above it — the spaghetti measure.
    private static func jumpsBackward(_ node: LintNode, tree: LintTree) -> Bool {
        let target: String?
        switch node.statement {
        case .goto(let number)?: target = "\(number)"
        case .gotoLabel(let name)?: target = name.uppercased()
        default: target = nil
        }
        guard let target else { return false }
        for candidate in tree.root.descendants where candidate.kind == .label {
            if candidate.name?.uppercased() == target { return candidate.range.line < node.range.line }
        }
        for line in tree.lines where line.number.map(String.init) == target {
            return line.sourceLineNumber < node.range.line
        }
        return false
    }
}
