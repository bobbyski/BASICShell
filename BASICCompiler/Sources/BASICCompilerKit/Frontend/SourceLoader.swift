import BASICSyntax
import Foundation

/// Reads a `.bas` file into parsed statements through the interpreter's own
/// line splitter and statement flattener, so both engines agree on what
/// "line 12, statement 2" means.
///
/// `IMPORT` expansion (files and directories) arrives with Phase 4.7; until
/// then an `IMPORT` is reported as not yet supported.
public struct SourceLoader {
    /// Creates a loader.
    public init() {}

    /// Loads and parses a program file.
    public func load(path: String) throws -> [ParsedLine] {
        let source: String
        do {
            source = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw CompileError("cannot read \(path): \(error.localizedDescription)", at: nil)
        }
        return try parse(source, fileName: path)
    }

    /// Parses program text as if it came from `fileName`.
    public func parse(_ source: String, fileName: String?) throws -> [ParsedLine] {
        let lines = ProgramLine.parse(source, fileName: fileName, isImported: false)
        do {
            return try ProgramParser.parse(lines)
        } catch let failure as ProgramParser.Failure {
            throw CompileError([
                Diagnostic(severity: .error, file: failure.fileName, line: failure.lineNumber, message: failure.error.description)
            ])
        } catch let error as BASICError {
            throw CompileError(error.description, at: nil)
        }
    }
}
