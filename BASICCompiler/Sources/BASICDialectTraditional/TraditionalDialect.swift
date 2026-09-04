import BASICCompilerKit
import Foundation

/// The default dialect: the BASIC the interpreter runs, compiled.
///
/// Objects, strings, and errors keep the interpreter's semantics; the runtime
/// is `BASICRT`. Lowering arrives in Phase 3 of BASIC_COMPILER.md — today the
/// dialect can identify itself, answer Sema's questions, and name its runtime,
/// which is enough for the driver and the toolchain spike to be real.
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
        throw NotYetLowered(module: module.name)
    }

    public func runtimeLibrary(for target: TargetTriple) -> RuntimeLibrary {
        RuntimeLibrary(name: "BASICRT")
    }

    /// Raised until Phase 3 lands: there is no code generator yet.
    public struct NotYetLowered: Error, CustomStringConvertible {
        /// The module that was asked for.
        public let module: String
        public var description: String {
            "basicc cannot lower '\(module)' yet — code generation is Phase 3 of BASIC_COMPILER.md"
        }
    }
}
