import Foundation

/// A compiler back end for one dialect of BASIC.
///
/// `basicc` owns no language knowledge: it parses a command line, asks the
/// ``DialectRegistry`` for a dialect, and hands it a module. Everything below
/// BIR belongs to the conforming framework — the object model, the type
/// lowering, the runtime it links, and the diagnostics it owns.
///
/// Two conformers are planned, one framework each:
///
/// | Framework                  | Dialect       | Ships |
/// |----------------------------|---------------|-------|
/// | `BASICDialectTraditional`  | `traditional` | Rev 1 |
/// | `BASICDialectSwift`        | `swift`       | Rev 2 |
///
/// Why a protocol and not an enum with two cases: the dialects differ in
/// *object model*, not in a flag. Making them peers is what keeps the default
/// dialect from slowly accreting `if swift` branches.
public protocol DialectCompiler: Sendable {
    /// What `--dialect` matches and what the wizard lists.
    static var identity: DialectIdentity { get }

    /// The questions Sema asks while it is still dialect-agnostic.
    var semantics: SemanticProfile { get }

    /// BIR in, an LLVM module out. Textual IR in Rev 1 (decision D3).
    func lower(_ module: BIRModule, options: CompileOptions) throws -> LoweredModule

    /// The runtime this dialect's code calls, and how the link finds it.
    func runtimeLibrary(for target: TargetTriple) -> RuntimeLibrary
}
