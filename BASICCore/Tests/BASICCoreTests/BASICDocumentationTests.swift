@testable import BASICCore
import BASICSyntax
import Testing

/// `///` documentation comments, held to Swift's rules.
@Suite("Documentation comments")
struct BASICDocumentationTests {

    static let program = """
        /// Squares a number.
        ///
        /// Multiplies the number by itself. This paragraph is the
        /// discussion, and it is Markdown.
        ///
        /// - Parameter n: The number to square.
        /// - Returns: `n` times `n`.
        /// - Note: Exact for whole numbers.
        FUNCTION Square(n AS DOUBLE) AS DOUBLE
            RETURN n * n
        END FUNCTION

        /// Adds two numbers.
        ///
        /// - Parameters:
        ///   - a: The first number.
        ///   - b: The second, which can run
        ///     onto a second line.
        FUNCTION Add(a AS DOUBLE, b AS DOUBLE) AS DOUBLE
            RETURN a + b
        END FUNCTION

        /// A point on the screen.
        TYPE Point
            /// Across, in columns.
            X AS DOUBLE
            Y AS DOUBLE
        END TYPE

        /// Which way a thing faces.
        ENUM Facing
            /// Toward the top.
            North
            South
        END ENUM

        /// How many times the loop has run.
        GLOBAL Count = 0

        //// Four slashes are an ordinary comment.
        FUNCTION Plain() AS DOUBLE
            RETURN 1
        END FUNCTION
        """

    static var symbols: [BASICDocumentedSymbol] { BASICDocumentation.symbols(in: program) }

    static func named(_ name: String) throws -> BASICDocumentedSymbol {
        try #require(BASICDocumentation.symbol(named: name, in: symbols), "no symbol \(name)")
    }

    @Test func theFirstParagraphIsTheSummaryAndTheRestIsTheDiscussion() throws {
        let doc = try #require(try Self.named("Square").documentation)
        #expect(doc.summary == "Squares a number.")
        #expect(doc.discussion == "Multiplies the number by itself. This paragraph is the\ndiscussion, and it is Markdown.")
    }

    @Test func calloutsAreReadAsSwiftReadsThem() throws {
        let doc = try #require(try Self.named("Square").documentation)
        #expect(doc.parameters.map(\.name) == ["n"])
        #expect(doc.parameters.first?.text == "The number to square.")
        #expect(doc.returns == "`n` times `n`.")
        #expect(doc.callouts == [BASICDocComment.Callout(kind: "Note", text: "Exact for whole numbers.")])
        // Callouts are not part of the discussion.
        #expect(!doc.discussion.contains("Parameter"))
    }

    @Test func aParametersListNamesOneParameterPerItem() throws {
        let doc = try #require(try Self.named("Add").documentation)
        #expect(doc.parameters.map(\.name) == ["a", "b"])
        // An indented line continues the item above it.
        #expect(doc.parameters.last?.text == "The second, which can run onto a second line.")
    }

    @Test func calloutKeywordsIgnoreCase() {
        let doc = BASICDocComment(lines: ["Does it.", "", "- returns: Something.", "- WARNING: Careful."])
        #expect(doc.returns == "Something.")
        #expect(doc.callouts.first?.kind == "Warning")
    }

    @Test func declarationsKnowWhatTheyAreAndWhatTheyTake() throws {
        let square = try Self.named("Square")
        #expect(square.kind == .function)
        #expect(square.parameters == ["n"])
        #expect(square.returnsValue)
        #expect(square.line == 9)
        #expect(square.documentationLine == 1)
        #expect(square.declaration == "FUNCTION Square(n AS DOUBLE) AS DOUBLE")
    }

    @Test func membersAreDocumentedInsideTheirContainer() throws {
        let x = try Self.named("Point.X")
        #expect(x.kind == .field)
        #expect(x.documentation?.summary == "Across, in columns.")
        #expect(try Self.named("Point.Y").documentation == nil)
        #expect(try Self.named("Point").documentation?.summary == "A point on the screen.")
    }

    @Test func enumsAndTheirCasesCanBeDocumented() throws {
        #expect(try Self.named("Facing").kind == .enumeration)
        let north = try Self.named("Facing.North")
        #expect(north.kind == .enumCase)
        #expect(north.documentation?.summary == "Toward the top.")
        #expect(try Self.named("Facing.South").documentation == nil)
    }

    @Test func globalsCanBeDocumented() throws {
        let count = try Self.named("Count")
        #expect(count.kind == .variable)
        #expect(count.documentation?.summary == "How many times the loop has run.")
    }

    @Test func fourSlashesAreNotDocumentation() throws {
        #expect(try Self.named("Plain").documentation == nil)
        #expect(BASICDocumentation.commentText("//// no") == nil)
        #expect(BASICDocumentation.commentText("    /// yes") == "yes")
    }

    @Test func namesAreMatchedWithoutRegardToCase() {
        #expect(BASICDocumentation.symbol(named: "SQUARE", in: Self.symbols)?.name == "Square")
        #expect(BASICDocumentation.symbol(named: "point.x", in: Self.symbols)?.name == "X")
    }

    @Test func aCommentThatDocumentsNothingIsReported() {
        let detached = BASICDocumentation.detachedComments(in: """
            /// Separated by a blank line.

            FUNCTION A() AS DOUBLE
                RETURN 1
            END FUNCTION
            /// Above a statement.
            PRINT 1
            /// At the end.
            """)
        #expect(detached.map(\.line) == [1, 6, 8])
        #expect(BASICDocumentation.detachedComments(in: Self.program).isEmpty)
    }

    @Test func documentationIsItsOwnTokenButOnlyAsAWholeLine() {
        #expect(BASICSyntaxTokenizer.spans(in: "  /// Squares.").map(\.token) == [.documentation])
        #expect(BASICSyntaxTokenizer.spans(in: "//// not docs").map(\.token) == [.comment])
        // After code, `///` is an ordinary trailing comment.
        #expect(BASICSyntaxTokenizer.spans(in: "PRINT 1 /// trailing").last?.token == .comment)
    }

    @Test func markdownLeadsWithTheDeclaration() throws {
        let text = BASICDocumentation.markdown(for: try Self.named("Square"))
        #expect(text.hasPrefix("`FUNCTION Square(n AS DOUBLE) AS DOUBLE`\n\nSquares a number."))
        #expect(text.contains("- `n`: The number to square."))
        #expect(text.contains("**Returns** `n` times `n`."))
    }
}

/// `HELP name` answers from the loaded program's `///` comments.
@Suite("HELP for a program's own declarations")
struct BASICDocumentationHelpTests {
    static let source = """
        /// Squares a number.
        ///
        /// - Parameter n: The number to square.
        /// - Returns: `n` times `n`.
        FUNCTION Square(n AS DOUBLE) AS DOUBLE
            RETURN n * n
        END FUNCTION

        FUNCTION Bare() AS DOUBLE
            RETURN 0
        END FUNCTION
        PRINT Square(3)
        """

    private func help(_ command: String) -> [String] {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource(Self.source)
        _ = session.submit(command)
        return host.output
    }

    @Test func helpWithAFunctionNameShowsItsDocumentation() {
        let text = help("HELP square").joined(separator: "\n")
        #expect(text.contains("FUNCTION Square(n AS DOUBLE) AS DOUBLE"))
        #expect(text.contains("Squares a number."))
        #expect(text.contains("The number to square."))
        #expect(text.contains("function"))
    }

    @Test func anUndocumentedDeclarationSaysHowToDocumentIt() {
        let text = help("HELP Bare").joined(separator: "\n")
        #expect(text.contains("FUNCTION Bare() AS DOUBLE"))
        #expect(text.contains("No documentation"))
    }

    @Test func aNameTheProgramDoesNotDeclareIsNotAnswered() {
        let session = BASICSession(host: TestHost())
        session.program.loadSource(Self.source)
        #expect(session.documentation(for: "Nothing") == nil)
        #expect(session.documentation(for: "Square", colored: false)?.contains("\u{1B}[") == false)
    }
}
