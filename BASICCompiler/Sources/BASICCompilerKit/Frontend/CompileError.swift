import BASICSyntax
import Foundation

/// The front end could not compile the program.
///
/// Carries every diagnostic found, so an IDE can show all of them; the first
/// is what the CLI prints. Rendering is BASIC-shaped (the prime directive):
/// `file:line: error: message`.
public struct CompileError: Error, CustomStringConvertible {
    /// What went wrong, in source order.
    public let diagnostics: [Diagnostic]

    /// Creates an error from diagnostics; there must be at least one.
    public init(_ diagnostics: [Diagnostic]) {
        precondition(!diagnostics.isEmpty)
        self.diagnostics = diagnostics
    }

    /// Creates an error from one message at a location.
    public init(_ message: String, at location: BIRLocation?) {
        self.init([Diagnostic(severity: .error, file: location?.file, line: location?.line, message: message)])
    }

    public var description: String {
        diagnostics.map(\.rendered).joined(separator: "\n")
    }
}
