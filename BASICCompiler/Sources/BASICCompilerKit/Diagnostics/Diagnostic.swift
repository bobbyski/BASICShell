import Foundation

/// One thing the compiler has to say about the program.
///
/// Diagnostics are BASIC-shaped (the prime directive): a source position and a
/// message in BASIC's words. They are `Codable` so `--json-diagnostics` can
/// hand them to an IDE unchanged.
public struct Diagnostic: Codable, Sendable, Equatable {
    /// How serious it is.
    public enum Severity: String, Codable, Sendable {
        case error
        case warning
        case note
    }

    /// The severity.
    public let severity: Severity

    /// The file the diagnostic points into, when known.
    public let file: String?

    /// The 1-based line, when known.
    public let line: Int?

    /// The 1-based column, when known.
    public let column: Int?

    /// The message, in BASIC's voice.
    public let message: String

    /// Creates a diagnostic.
    public init(severity: Severity, file: String? = nil, line: Int? = nil, column: Int? = nil, message: String) {
        self.severity = severity
        self.file = file
        self.line = line
        self.column = column
        self.message = message
    }

    /// The clang-style one-liner IDEs already know how to parse:
    /// `file:line:column: error: message`.
    public var rendered: String {
        var prefix = ""
        if let file {
            prefix = file
            if let line {
                prefix += ":\(line)"
                if let column { prefix += ":\(column)" }
            }
            prefix += ": "
        }
        return "\(prefix)\(severity.rawValue): \(message)"
    }
}
