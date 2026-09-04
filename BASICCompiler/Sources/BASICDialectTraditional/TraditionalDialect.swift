import BASICCompilerKit
import Foundation

/// The default dialect: the BASIC the interpreter runs, compiled.
///
/// Objects, strings, and errors keep the interpreter's semantics; the runtime
/// is `BASICRT`, and ``LLVMLowering`` turns BIR into textual LLVM IR that
/// calls it.
public struct TraditionalDialect: DialectCompiler {
    public static let identity = DialectIdentity(
        identifier: "traditional",
        displayName: "Traditional",
        summary: "The BASIC BASICShell runs, compiled — the default.",
        isDefault: true
    )

    public let semantics = SemanticProfile(
        strings: .exactBytes,
        importsSwiftFrameworks: false
    )

    /// Creates the traditional dialect.
    public init() {}

    public func lower(_ module: BIRModule, options: CompileOptions) throws -> LoweredModule {
        var lowering = LLVMLowering(module: module, options: options)
        return LoweredModule(name: module.name, llvmIR: lowering.render())
    }

    public func runtimeLibrary(for target: TargetTriple) -> RuntimeLibrary {
        RuntimeLibrary(name: "BASICRT")
    }
}
