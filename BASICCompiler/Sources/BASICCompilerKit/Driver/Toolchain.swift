import Foundation

/// The three external steps that turn lowered IR into a program.
///
/// ```text
///   LoweredModule.llvmIR ─► clang -c ────────────► module.o ──┐
///                                                             ├─► swiftc link ─► binary
///   BASICRT/*.swift ──────► swiftc -emit-object ─► rt.o ──────┘
/// ```
///
/// Textual IR in, Apple clang for objects, `swiftc` for the final link so the
/// Swift runtime and any Swift framework the program uses resolve without the
/// driver knowing where they live. This is the recipe the Phase 0.5 spike
/// proved; ``ToolchainSpikeTests`` keeps it proved.
public struct Toolchain: Sendable {
    /// Creates a toolchain driver.
    public init() {}

    /// Assembles textual LLVM IR into an object file.
    ///
    /// - Parameters:
    ///   - llvmIR: The module as `.ll` text.
    ///   - irPath: Where to write the `.ll`, kept for `--emit-llvm`.
    ///   - objectPath: Where clang writes the object.
    public func assemble(llvmIR: String, irPath: String, objectPath: String, optimizationLevel: Int = 0) throws {
        try llvmIR.write(toFile: irPath, atomically: true, encoding: .utf8)
        let result = try ProcessRunner.xcrun("clang", ["-c", irPath, "-O\(optimizationLevel)", "-o", objectPath, "-Wno-override-module"])
        guard result.exitCode == 0 else {
            throw ToolchainError(stage: "clang", exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// Assembles textual LLVM IR into assembly text — what a SwiftPM
    /// build-tool plugin can hand to a C-family target as a generated source.
    public func assembleToAssembly(llvmIR: String, irPath: String, assemblyPath: String) throws {
        try llvmIR.write(toFile: irPath, atomically: true, encoding: .utf8)
        let result = try ProcessRunner.xcrun("clang", ["-S", irPath, "-o", assemblyPath, "-Wno-override-module"])
        guard result.exitCode == 0 else {
            throw ToolchainError(stage: "clang", exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// Compiles the runtime's Swift sources into one object file.
    ///
    /// Whole-module, optimized: the runtime is compiled once and cached, so
    /// its build time is paid rarely and compiled programs never pay for a
    /// debug runtime.
    public func compileRuntime(sources: [String], objectPath: String, extraArguments: [String] = []) throws {
        let arguments = ["-parse-as-library", "-O", "-wmo", "-emit-object"]
            + sources + extraArguments + ["-o", objectPath]
        let result = try ProcessRunner.xcrun("swiftc", arguments)
        guard result.exitCode == 0 else {
            throw ToolchainError(stage: "swiftc (runtime)", exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// Links objects into an executable.
    public func link(objects: [String], output: String, extraArguments: [String] = []) throws {
        let result = try ProcessRunner.xcrun("swiftc", objects + extraArguments + ["-o", output])
        guard result.exitCode == 0 else {
            throw ToolchainError(stage: "swiftc (link)", exitCode: result.exitCode, stderr: result.stderr)
        }
    }
}
