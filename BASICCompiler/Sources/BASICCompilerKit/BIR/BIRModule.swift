import Foundation

/// The compiler's intermediate representation of one program.
///
/// **Placeholder.** Phase 1.4 of BASIC_COMPILER.md designs BIR properly —
/// typed, resolved, control-flow-graph-shaped. Until then the module carries
/// only what the toolchain spike needs: a name. The type exists now so the
/// ``DialectCompiler`` protocol is already the shape it will keep.
public struct BIRModule: Sendable {
    /// The module name, usually the source file's base name.
    public let name: String

    /// Creates an (empty) module.
    public init(name: String) {
        self.name = name
    }
}
