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

    /// The breakpoint key for this statement.
    public var breakpointLocation: BASICBreakpointLocation {
        BASICBreakpointLocation(fileName: fileName, lineNumber: sourceLineNumber, statementNumber: statementNumber)
    }

    /// Creates a parsed line.
    public init(number: Int?, displayLineNumber: Int, fileName: String?, sourceLineNumber: Int, statementNumber: Int, isImported: Bool, statement: Statement) {
        self.number = number
        self.displayLineNumber = displayLineNumber
        self.fileName = fileName
        self.sourceLineNumber = sourceLineNumber
        self.statementNumber = statementNumber
        self.isImported = isImported
        self.statement = statement
    }

    /// Splits a colon-separated `.sequence` into one parsed line per
    /// statement, numbering them so breakpoints can name each.
    public static func flatten(number: Int?, fileName: String?, sourceLineNumber: Int, isImported: Bool, statement: Statement) -> [ParsedLine] {
        let displayLineNumber = number ?? sourceLineNumber
        guard case .sequence(let statements) = statement else {
            return [
                ParsedLine(
                    number: number,
                    displayLineNumber: displayLineNumber,
                    fileName: fileName,
                    sourceLineNumber: sourceLineNumber,
                    statementNumber: 0,
                    isImported: isImported,
                    statement: statement
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
                statement: statement
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

    public static func parse(_ sourceLines: [ProgramLine]) throws -> [ParsedLine] {
        var parsed: [ParsedLine] = []
        var index = 0
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
                    statement: .enumDeclaration(name: name, cases: cases)
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
                var body: [ClosureBodyLine] = []
                index += 1
                var foundEnd = false
                while index < sourceLines.count {
                    let bodyLine = sourceLines[index]
                    var parser = try Parser(source: bodyLine.source)
                    let statement: Statement
                    do {
                        statement = try parser.parseStatement()
                    } catch let error as BASICError {
                        throw Failure(fileName: bodyLine.fileName, lineNumber: bodyLine.sourceLineNumber ?? index + 1, error: error)
                    }
                    if case .endFunction = statement {
                        foundEnd = true
                        break
                    }
                    body.append(
                        ClosureBodyLine(
                            fileName: bodyLine.fileName,
                            sourceLineNumber: bodyLine.sourceLineNumber ?? index + 1,
                            statement: statement
                        )
                    )
                    index += 1
                }
                guard foundEnd else {
                    throw BASICError.runtime("FUNCTION closure without END FUNCTION")
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
                    )
                )
                index += 1
                continue
            }

            var parser = try Parser(source: line.source)
            let statement: Statement
            do {
                statement = try parser.parseStatement()
            } catch let error as BASICError {
                throw Failure(fileName: line.fileName, lineNumber: line.sourceLineNumber ?? index + 1, error: error)
            }
            parsed += ParsedLine.flatten(
                number: line.number,
                fileName: line.fileName,
                sourceLineNumber: line.sourceLineNumber ?? index + 1,
                isImported: line.isImported,
                statement: statement
            )
            index += 1
        }
        return parsed
    }
}
