@testable import BASICCompilerKit
import BASICSyntax
import Foundation
import Testing

// The interpreter parity gate (BASIC_COMPILER.md 1.6).
//
// The interpreter and the compiler are one language because they read it
// with one parser: `BASICSyntax`'s `ProgramLine` and `ProgramParser`, which
// both consume directly. The compiler adds import expansion around them and
// nothing else — no lexer of its own, no statements of its own, no quiet
// second opinion about what a line means.
//
// This is that promise as a test. It parses every program in the tree twice
// — once through the compiler's front door, once through the shared parser
// straight — and holds the two ASTs against each other. The day the
// compiler grows a parser of its own, this fails.

@Suite("The compiler parses with the interpreter's parser")
struct ParserParityTests {
    /// Every program the parity suite covers, plus the language corners the
    /// starters use.
    static var programs: [String] {
        TestBuild.programs.filter { path in
            // Import expansion is the compiler's own layer, so a program
            // that imports is not the same *text* both ways. The programs
            // that do are covered by the behaviour suite instead.
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
            return !text.uppercased().contains("IMPORT ")
        }
    }

    @Test(arguments: ParserParityTests.programs)
    func theCompilerSeesTheSameStatements(path: String) throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let name = (path as NSString).lastPathComponent

        // The compiler's front door.
        let compilerLines = try SourceLoader().parse(text, fileName: name)
        // The parser both engines share, called directly.
        let sharedLines = try ProgramParser.parse(ProgramLine.parse(text, fileName: name, isImported: false))

        #expect(compilerLines.count == sharedLines.count, Comment(rawValue: "\(name): line count"))
        for (compiled, shared) in zip(compilerLines, sharedLines) {
            #expect(
                String(describing: compiled.statement) == String(describing: shared.statement),
                Comment(rawValue: "\(name) line \(shared.sourceLineNumber): the compiler read it differently")
            )
            #expect(compiled.sourceLineNumber == shared.sourceLineNumber)
            #expect(compiled.number == shared.number)
        }
    }
}
