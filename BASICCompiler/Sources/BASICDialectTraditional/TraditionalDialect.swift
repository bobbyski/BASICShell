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
        try lower(module, options: options, objectModel: RuntimeObjectModel())
    }

    /// The same lowering with objects placed by `objectModel` — how the Swift
    /// dialect shares this code and changes only where objects live.
    public func lower(_ module: BIRModule, options: CompileOptions, objectModel: any ObjectModel) throws -> LoweredModule {
        let lowering = LLVMLowering(module: module, options: options, objectModel: objectModel)
        return LoweredModule(name: module.name, llvmIR: lowering.render())
    }

    public func runtimeLibrary(for target: TargetTriple) -> RuntimeLibrary {
        RuntimeLibrary(name: "BASICRT")
    }
}
