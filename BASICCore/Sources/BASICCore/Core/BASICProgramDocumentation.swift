import BASICSyntax
import Foundation
import RichSwift

// `HELP Square`: a program's own documentation, the way Xcode's Quick Help
// shows a Swift symbol's. See BASICDocumentation.swift for the rules a `///`
// comment follows.

extension BASICProgram {
    /// Every declaration in the loaded program with the `///` documentation
    /// above it, file by file.
    ///
    /// The program keeps its lines without the blank ones, so each file is
    /// rebuilt at its original line numbers before it is read: a blank line
    /// between a comment and a declaration detaches the comment, and the
    /// reader has to see the blank line to know.
    public var documentedSymbols: [BASICDocumentedSymbol] {
        var order: [String?] = []
        var byFile: [String?: [(line: Int, source: String)]] = [:]
        for line in orderedLines {
            if byFile[line.fileName] == nil { order.append(line.fileName) }
            // A typed program has no physical line numbers; its order is its
            // line order, one after another.
            let position = line.sourceLineNumber ?? ((byFile[line.fileName]?.last?.line ?? 0) + 1)
            byFile[line.fileName, default: []].append((position, line.source))
        }
        return order.flatMap { file -> [BASICDocumentedSymbol] in
            let entries = byFile[file] ?? []
            let last = entries.map(\.line).max() ?? 0
            var text = Array(repeating: "", count: last)
            for entry in entries where entry.line >= 1 { text[entry.line - 1] = entry.source }
            return BASICDocumentation.symbols(in: text.joined(separator: "\n"), fileName: file)
        }
    }
}

public enum BASICDocumentationRenderer {
    /// A symbol's documentation as terminal text: Markdown rendered with
    /// RichSwift, colored or plain, wrapped to `width`.
    public static func render(_ symbol: BASICDocumentedSymbol, width: Int = 80, colored: Bool = true) -> String {
        var markdown = BASICDocumentation.markdown(for: symbol)
        let place = [symbol.fileName.map { ($0 as NSString).lastPathComponent }, "line \(symbol.line)"]
            .compactMap { $0 }.joined(separator: ", ")
        markdown += "\n\n\(symbol.kind.rawValue) · \(place)"
        let context = RenderContext(width: width, colorMode: colored ? .standard : .disabled, markup: false)
        return Markdown(markdown).render(in: context)
    }
}
