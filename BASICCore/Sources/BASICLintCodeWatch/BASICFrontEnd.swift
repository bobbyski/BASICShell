import BASICLint
import CodeWatchLint
import Foundation

// BASIC in CodeWatch.
//
// CodeWatchLint's rule engine never sees a parser: a language is a mapping
// from whatever produced its tree onto `LintNodeKind`. Its own front ends
// are tree-sitter grammars, which BASIC has no reason to grow — it already
// has a parser, the one the interpreter and `basicc` both use, and a second
// one here could only disagree with it.
//
// So this lives with BASIC rather than with CodeWatch: the direction
// CodeWatchLint documents for a host that brings its own parser. CodeWatch
// gains one enum case; everything else is here.

/// Parses BASIC into CodeWatchLint's representation.
public struct BASICFrontEnd: LintFrontEnd {
    public var language: LintLanguage { .basic }

    public init() {}

    public func parse(source: String, path: String) throws -> CodeWatchLint.LintTree {
        let tree = BASICLint.LintTree.build(source: source, fileName: (path as NSString).lastPathComponent)
        var builder = LintTreeBuilder(language: .basic, path: path, source: source)
        let offsets = LineOffsets(source: source)
        for node in tree.root.children {
            add(node, to: &builder, offsets: offsets)
        }
        return builder.finish()
    }

    /// Adds a node and everything under it, opening before its children and
    /// closing after them, as the builder asks.
    private func add(_ node: BASICLint.LintNode, to builder: inout LintTreeBuilder, offsets: LineOffsets) {
        guard let kind: CodeWatchLint.LintNodeKind = Self.kind(of: node.kind) else { return }
        let range = offsets.utf8Range(of: node)
        guard !node.children.isEmpty else {
            builder.addNode(kind: kind, utf8Range: range)
            return
        }
        // A block spans its children, which the node's own single line does
        // not: a rule measuring nesting needs the whole extent.
        let end = node.children.map { offsets.utf8Range(of: $0).upperBound }.max() ?? range.upperBound
        builder.beginNode(kind: kind, utf8Range: range.lowerBound..<max(range.upperBound, end))
        for child in node.children { add(child, to: &builder, offsets: offsets) }
        builder.endNode()
    }

    /// BASIC's vocabulary in CodeWatch's words. The two were chosen to line
    /// up, so this is a rename rather than a translation.
    static func kind(of kind: BASICLint.LintNodeKind) -> CodeWatchLint.LintNodeKind? {
        switch kind {
        case .program: return .compilationUnit
        case .routineDeclaration: return .routineDeclaration
        case .typeDeclaration: return .typeDeclaration
        case .block: return .block
        case .branch: return .branch
        case .loop: return .loop
        case .selectCase: return .caseStatement
        case .caseArm: return .caseClause
        case .gotoStatement, .gosubStatement: return .gotoStatement
        case .assignment: return .assignment
        case .declaration: return .variableDeclaration
        case .callStatement: return .call
        case .errorHandler: return .exceptionHandler
        case .importDirective: return .importDeclaration
        case .returnStatement: return .returnStatement
        case .comment: return .comment
        case .label, .dataStatement, .readStatement, .optionStatement, .blockEnd, .statement:
            // Nothing in CodeWatch's vocabulary means these, and a node with
            // the wrong kind is worse than no node: a rule would count it.
            return nil
        }
    }
}

/// Turns a line and column into a UTF-8 offset, which is what the builder
/// wants and what BASIC's tree does not carry.
struct LineOffsets {
    private let starts: [Int]
    private let byteCount: Int

    init(source: String) {
        var starts: [Int] = [0]
        for (offset, byte) in Array(source.utf8).enumerated() where byte == 0x0A {
            starts.append(offset + 1)
        }
        self.starts = starts
        self.byteCount = source.utf8.count
    }

    func offset(line: Int, column: Int) -> Int {
        guard line >= 1, line <= starts.count else { return byteCount }
        return min(byteCount, starts[line - 1] + max(0, column - 1))
    }

    func utf8Range(of node: BASICLint.LintNode) -> Range<Int> {
        let start = offset(line: node.range.line, column: node.range.column)
        let end = max(start, offset(line: node.range.endLine, column: node.range.endColumn + 1))
        return start..<end
    }
}
