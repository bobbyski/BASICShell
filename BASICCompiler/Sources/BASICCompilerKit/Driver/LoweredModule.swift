import Foundation

/// What a dialect hands back from ``DialectCompiler/lower(_:options:)``.
///
/// Textual LLVM IR is the contract (decision D3): LLVM has a first-class
/// parser for its own IR, the golden tests read like documentation, and an
/// LLVM-C emitter can replace the text behind this same type later.
public struct LoweredModule: Sendable {
    /// The module, as `.ll` text.
    public let llvmIR: String

    /// The module name, used for the object file and diagnostics.
    public let name: String

    /// Creates a lowered module.
    public init(name: String, llvmIR: String) {
        self.name = name
        self.llvmIR = llvmIR
    }
}
