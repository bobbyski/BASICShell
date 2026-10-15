import Foundation

/// One statement of a program with everything needed to point back at its
/// source: the file, the physical line, and the statement's index within a
/// colon-separated line. This is the unit the interpreter executes and the
/// compiler lowers.
public struct ParsedLine {
    public let number: Int?
    public let displayLineNumber: Int
    public let fileName: String?
    public let sourceLineNumber: Int
    public let statementNumber: Int
    public let isImported: Bool
    public let statement: Statement
    /// The source line the statement is on, as written (without its line
    /// number), and the column the statement starts at in it: where a
    /// runtime error puts its caret.
    public let source: String
    public let column: Int

    /// The breakpoint key for this statement.
    public var breakpointLocation: BASICBreakpointLocation {
        BASICBreakpointLocation(fileName: fileName, lineNumber: sourceLineNumber, statementNumber: statementNumber)
    }

    /// Creates a parsed line.
    public init(number: Int?, displayLineNumber: Int, fileName: String?, sourceLineNumber: Int, statementNumber: Int, isImported: Bool, statement: Statement, source: String = "", column: Int = 0) {
        self.number = number
        self.displayLineNumber = displayLineNumber
        self.fileName = fileName
        self.sourceLineNumber = sourceLineNumber
        self.statementNumber = statementNumber
        self.isImported = isImported
        self.statement = statement
        self.source = source
        self.column = column
    }

    /// The column of the first thing on `source` that isn't a space or tab:
    /// where a statement starts when no parser said.
    public static func firstColumn(of source: String) -> Int {
        source.prefix { $0 == " " || $0 == "\t" }.count
    }

    /// Splits a colon-separated `.sequence` into one parsed line per
    /// statement, numbering them so breakpoints can name each.
    /// `source` is the line's text and `columns` where each of its statements
    /// starts (from `Parser.statementColumns`); with none, a statement starts
    /// at the line's first non-blank column.
    public static func flatten(number: Int?, fileName: String?, sourceLineNumber: Int, isImported: Bool, statement: Statement, source: String = "", columns: [Int] = []) -> [ParsedLine] {
        let displayLineNumber = number ?? sourceLineNumber
        func column(_ index: Int) -> Int {
            index < columns.count ? columns[index] : firstColumn(of: source)
        }
        guard case .sequence(let statements) = statement else {
            return [
                ParsedLine(
                    number: number,
                    displayLineNumber: displayLineNumber,
                    fileName: fileName,
                    sourceLineNumber: sourceLineNumber,
                    statementNumber: 0,
                    isImported: isImported,
                    statement: statement,
                    source: source,
                    column: column(0)
                )
            ]
        }

        return statements.enumerated().map { index, statement in
            ParsedLine(
                number: index == 0 ? number : nil,
                displayLineNumber: displayLineNumber,
                fileName: fileName,
                sourceLineNumber: sourceLineNumber,
                statementNumber: index,
                isImported: isImported,
                statement: statement,
                source: source,
                column: column(index)
            )
        }
    }
}

/// Turns program lines into the flat statement list both engines run on.
///
/// ```text
///   [ProgramLine]  ──►  ProgramParser.parse  ──►  [ParsedLine]
///        │                     │
///        │                     ├─ a closure-block assignment header pulls
///        │                     │  the lines up to END FUNCTION into one
///        │                     │  .closureAssignment statement
///        │                     └─ every other line parses to one statement,
///        │                        then colon sequences are flattened
///        └─ from ProgramLine.parse(_:fileName:isImported:)
/// ```
public enum ProgramParser {
    /// A parse error, with where it happened.
    public struct Failure: Error {
        /// The file the failing line came from, when known.
        public let fileName: String?
        /// The physical line number of the failing line.
        public let lineNumber: Int
        /// The parser's error, unchanged.
        public let error: BASICError
    }

    /// What follows `END FUNCTION` on a line that is one, any case and
    /// spacing, as written; nil for any other line.
    public static func endFunctionTail(_ source: String) -> String? {
        let text = source.drop { $0 == " " || $0 == "\t" }
        guard text.prefix(3).uppercased() == "END" else { return nil }
        let gap = text.dropFirst(3)
        guard let space = gap.first, space == " " || space == "\t" else { return nil }
        let word = gap.drop { $0 == " " || $0 == "\t" }
        guard word.prefix(8).uppercased() == "FUNCTION" else { return nil }
        let tail = word.dropFirst(8)
        if let next = tail.first, next.isLetter || next.isNumber || next == "_" || next == "$" { return nil }
        return String(tail)
    }

    /// `x = FUNCTION(…) … END FUNCTION` is a closure assignment however the
    /// line was reached, so the closure is named for its variable.
    static func namingClosures(_ statement: Statement) -> Statement {
        switch statement {
        case .assignment(let kind, let variable, let declared, .blockClosure(let parameters, let returnType, let captures, let body)?):
            return .closureAssignment(kind, variable, declared, parameters, returnType, captures, body)
        case .sequence(let statements):
            return .sequence(statements.map(namingClosures))
        default:
            return statement
        }
    }

    public static func parse(_ sourceLines: [ProgramLine]) throws -> [ParsedLine] {
        var parsed: [ParsedLine] = []
        var index = 0

        // A multi-line closure's body: the lines after the one `index` is on,
        // up to its END FUNCTION — a closure nested in them gathers its own
        // first, so the END FUNCTION found here is this one's. `index` is left
        // on the END FUNCTION line, and what follows END FUNCTION there is
        // handed back for the statement to go on with (CLOSURES.md 3.6–3.8).
        func closureBody() throws -> (body: [ClosureBodyLine], tail: String) {
            var body: [ClosureBodyLine] = []
            index += 1
            while index < sourceLines.count {
                let bodyLine = sourceLines[index]
                if let tail = endFunctionTail(bodyLine.source) { return (body, tail) }
                var parser = try Parser(source: bodyLine.source)
                parser.blockClosureBody = closureBody
                let statement: Statement
                do {
                    statement = try parser.parseStatement()
                } catch let error as BASICError {
                    throw Failure(fileName: bodyLine.fileName, lineNumber: bodyLine.sourceLineNumber ?? index + 1, error: error)
                }
                body.append(ClosureBodyLine(fileName: bodyLine.fileName, sourceLineNumber: bodyLine.sourceLineNumber ?? index + 1,
                                            statement: namingClosures(statement), source: bodyLine.source))
                index += 1
            }
            throw BASICError.runtime("FUNCTION closure without END FUNCTION")
        }

        while index < sourceLines.count {
            let line = sourceLines[index]
            // `ENUM Suit ... END ENUM` is gathered before anything else is
            // tried, because the closure-block header parser *throws* on a
            // line it does not recognize rather than returning nil — so an
            // ENUM header never reached this check when it came second.
            //
            // It is gathered as a block for the same reason a
            // closure block is: a member is a bare identifier, and `Hearts` on
            // its own is indistinguishable from a mistyped assignment unless
            // something knows it is inside an ENUM. Doing it here keeps every
            // line of the statement parser context-free.
            var enumParser = try Parser(source: line.source)
            if let name = enumParser.parseEnumHeader() {
                var cases: [EnumCase] = []
                var next = 0
                var foundEnd = false
                index += 1
                while index < sourceLines.count {
                    let member = sourceLines[index]
                    var parser = try Parser(source: member.source)
                    if parser.parseEndEnum() { foundEnd = true; break }
                    do {
                        if let parsed = try parser.parseEnumCase(next: &next) { cases.append(parsed) }
                    } catch let error as BASICError {
                        throw Failure(fileName: member.fileName,
                                      lineNumber: member.sourceLineNumber ?? index + 1, error: error)
                    }
                    index += 1
                }
                guard foundEnd else {
                    throw Failure(fileName: line.fileName,
                                  lineNumber: line.sourceLineNumber ?? index + 1,
                                  error: .syntax("ENUM \(name) without END ENUM"))
                }
                parsed += ParsedLine.flatten(
                    number: line.number,
                    fileName: line.fileName,
                    sourceLineNumber: line.sourceLineNumber ?? parsed.count + 1,
                    isImported: line.isImported,
                    statement: .enumDeclaration(name: name, cases: cases),
                    source: line.source
                )
                index += 1
                continue
            }

            var headerParser = try Parser(source: line.source)
            let header: (
                kind: AssignmentKind,
                variable: VariableName,
                declaredType: BASICType?,
                parameters: [FunctionParameter],
                returnType: BASICType,
                captures: [ClosureCaptureSpec]
            )?
            do {
                header = try headerParser.parseClosureBlockAssignmentHeader()
            } catch let error as BASICError {
                throw Failure(fileName: line.fileName, lineNumber: line.sourceLineNumber ?? index + 1, error: error)
            }
            if let header {
                let (body, tail) = try closureBody()
                guard tail.allSatisfy({ $0 == " " || $0 == "\t" }) || tail.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("'") else {
                    throw Failure(fileName: line.fileName, lineNumber: sourceLines[index].sourceLineNumber ?? index + 1,
                                  error: .syntax("Unexpected text after END FUNCTION"))
                }
                parsed += ParsedLine.flatten(
                    number: line.number,
                    fileName: line.fileName,
                    sourceLineNumber: line.sourceLineNumber ?? parsed.count + 1,
                    isImported: line.isImported,
                    statement: .closureAssignment(
                        header.kind,
                        header.variable,
                        header.declaredType,
                        header.parameters,
                        header.returnType,
                        header.captures,
                        body
                    ),
                    source: line.source
                )
                index += 1
                continue
            }

            var parser = try Parser(source: line.source)
            parser.blockClosureBody = closureBody
            let lineIndex = index
            let statement: Statement
            do {
                statement = try parser.parseStatement()
            } catch let error as BASICError {
                throw Failure(fileName: line.fileName, lineNumber: line.sourceLineNumber ?? index + 1, error: error)
            }
            parsed += ParsedLine.flatten(
                number: line.number,
                fileName: line.fileName,
                sourceLineNumber: line.sourceLineNumber ?? lineIndex + 1,
                isImported: line.isImported,
                statement: namingClosures(statement),
                source: line.source,
                columns: parser.statementColumns
            )
            index += 1
        }
        return parsed
    }
}
