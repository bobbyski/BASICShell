import CryptoKit
import Foundation

/// One program, from source file to executable.
///
/// ```text
///   source.bas ─► SourceLoader ─► BIRBuilder ─► dialect.lower ─► Toolchain
///                  [ParsedLine]    BIRModule     LoweredModule    clang · swiftc
///                                                                     │
///                                                    BASICRT (cached rt.o) ─┘
/// ```
///
/// The runtime object is compiled once per runtime-source revision and kept
/// in the user's cache directory, so building a program costs one clang run
/// and one link.
public struct Compilation {
    /// The dialect doing the lowering.
    public let dialect: any DialectCompiler
    /// Options for this compilation.
    public let options: CompileOptions
    /// The tools.
    public let toolchain: Toolchain

    /// Creates a compilation.
    public init(dialect: any DialectCompiler, options: CompileOptions = CompileOptions(), toolchain: Toolchain = Toolchain()) {
        self.dialect = dialect
        self.options = options
        self.toolchain = toolchain
    }

    /// The BIR for a source file, for `--emit-bir`.
    public func bir(sourcePath: String) throws -> BIRModule {
        let lines = try SourceLoader().load(path: sourcePath)
        return try BIRBuilder().build(lines, moduleName: Self.moduleName(for: sourcePath))
    }

    /// The BIR for program text, for tests.
    public func bir(source: String, name: String) throws -> BIRModule {
        let lines = try SourceLoader().parse(source, fileName: name + ".bas")
        return try BIRBuilder().build(lines, moduleName: name)
    }

    /// The LLVM IR for a source file, for `--emit-llvm`.
    public func llvmIR(sourcePath: String) throws -> String {
        try dialect.lower(try bir(sourcePath: sourcePath), options: options).llvmIR
    }

    /// Compiles a source file to an executable at `output`.
    ///
    /// Intermediates (`.ll`, `.o`) go next to the output under
    /// `<output>.build/` so `--emit-llvm` has something to show and a failed
    /// clang run leaves evidence.
    public func build(sourcePath: String, output: String) throws {
        let module = try bir(sourcePath: sourcePath)
        let lowered = try dialect.lower(module, options: options)

        let buildDir = output + ".build"
        try FileManager.default.createDirectory(atPath: buildDir, withIntermediateDirectories: true)
        let irPath = (buildDir as NSString).appendingPathComponent("\(module.name).ll")
        let objectPath = (buildDir as NSString).appendingPathComponent("\(module.name).o")
        try toolchain.assemble(llvmIR: lowered.llvmIR, irPath: irPath, objectPath: objectPath)

        let runtime = dialect.runtimeLibrary(for: options.target)
        let runtimeObject = try cachedRuntimeObject(runtime)
        try toolchain.link(objects: [objectPath, runtimeObject], output: output, extraArguments: runtime.linkArguments)
    }

    /// The module name for a source path: its base name without `.bas`.
    public static func moduleName(for sourcePath: String) -> String {
        ((sourcePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Compiles the runtime once per revision of its sources.
    func cachedRuntimeObject(_ runtime: RuntimeLibrary) throws -> String {
        let sources = try runtime.sources()
        var hasher = SHA256()
        for path in sources {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: try Data(contentsOf: URL(fileURLWithPath: path)))
        }
        let digest = hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("basicc")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let objectPath = cacheDir.appendingPathComponent("\(runtime.name)-\(digest).o").path
        if !FileManager.default.fileExists(atPath: objectPath) {
            // Compile beside the final name and move it into place, so two
            // compilations racing for the same cache entry never link a
            // half-written object.
            let staging = objectPath + ".\(ProcessInfo.processInfo.processIdentifier).tmp"
            try toolchain.compileRuntime(sources: sources, objectPath: staging)
            if FileManager.default.fileExists(atPath: objectPath) {
                try? FileManager.default.removeItem(atPath: staging)
            } else {
                try FileManager.default.moveItem(atPath: staging, toPath: objectPath)
            }
        }
        return objectPath
    }
}
