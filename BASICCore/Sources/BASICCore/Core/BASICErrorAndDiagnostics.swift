import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum BASICError: Error, CustomStringConvertible, Equatable {
    /// A general syntax error without source-line context.
    case syntax(String)
    /// A syntax error tied to a specific source line and column.
    case contextualSyntax(message: String, source: String, column: Int)
    /// A general type-checking or coercion error.
    case type(message: String)
    /// A type error tied to a specific source line and column.
    case contextualType(message: String, source: String, column: Int)
    /// A runtime failure raised while executing a valid program.
    case runtime(String)
    /// A runtime failure raised by the BASIC ERROR statement.
    case numberedRuntime(Int)
    /// An operation that requires BASICStudio graphics support on the current host.
    case studioOnlyFeature
    /// A branch target referenced a missing numbered line.
    case missingLine(Int)
    /// A branch target referenced a missing label.
    case missingLabel(String)
    /// Execution was interrupted by a user break request.
    case breakRequested(Int?)
    /// Execution stopped at a configured breakpoint.
    case breakpoint(BASICBreakpointLocation)
    /// Execution stopped after completing a debugger step.
    case stepComplete(BASICBreakpointLocation)
    /// Execution halted intentionally.
    case halted

    /// A user-facing rendering of the error, including caret context when available.
    public var description: String {
        switch self {
        case .syntax(let message): return "Syntax error: \(message)"
        case .contextualSyntax(let message, let source, let column):
            let marker = String(repeating: " ", count: max(0, column)) + "^"
            return "\(source)\n\(marker)\nSyntax error: \(message)"
        case .type(let message): return "Type error: \(message)"
        case .contextualType(let message, let source, let column):
            let marker = String(repeating: " ", count: max(0, column)) + "^"
            return "\(source)\n\(marker)\nType error: \(message)"
        case .runtime(let message): return "Runtime error: \(message)"
        case .numberedRuntime(let number): return "Runtime error: Error \(number)"
        case .studioOnlyFeature: return "Unsupported feature: you must run this program in BASICStudio"
        case .missingLine(let line): return "Missing line \(line)"
        case .missingLabel(let label): return "Missing label \(label)"
        case .breakRequested(let line):
            if let line {
                return "Break at \(line)"
            }
            return "Break at unnumbered line"
        case .breakpoint(let location):
            return "Break at \(location.lineNumber)"
        case .stepComplete(let location):
            return "Break at \(location.lineNumber)"
        case .halted: return "Program halted"
        }
    }
}

/// Severity for diagnostics reported before running a BASIC program.
public enum BASICDiagnosticSeverity: String, Codable, Sendable {
    /// A diagnostic that prevents correct execution.
    case error
    /// A diagnostic that should be shown but does not necessarily prevent execution.
    case warning
}

/// A source diagnostic suitable for editor decorations and LIST CHECK output.
public struct BASICDiagnostic: Codable, Equatable, Sendable {
    /// Optional source file path associated with the diagnostic.
    public let fileName: String?
    /// One-based physical source line number.
    public let lineNumber: Int
    /// Zero-based source column.
    public let column: Int
    /// Human-readable diagnostic message.
    public let message: String
    /// Diagnostic severity.
    public let severity: BASICDiagnosticSeverity

    /// Creates a diagnostic at a source location.
    public init(
        fileName: String? = nil,
        lineNumber: Int,
        column: Int,
        message: String,
        severity: BASICDiagnosticSeverity = .error
    ) {
        self.fileName = fileName
        self.lineNumber = lineNumber
        self.column = column
        self.message = message
        self.severity = severity
    }
}

extension BASICError {
    var isDebugPause: Bool {
        switch self {
        case .breakRequested, .breakpoint, .stepComplete:
            return true
        default:
            return false
        }
    }
}

/// String storage used by the interpreter, preserving embedded NUL bytes when required.
