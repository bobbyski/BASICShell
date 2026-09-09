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
public struct Compilation: Sendable {
    /// The dialect doing the lowering.
    public let dialect: any DialectCompiler
    /// Options for this compilation.
    public let options: CompileOptions
    /// The tools.
    public let toolchain: Toolchain

    /// Extra objects the link must include — an imported Swift framework's
    /// compiled code (R4). Empty for a program that imports nothing.
    public var extraObjects: [String] = []

    /// Reads a program's source, given the path. A dialect that can import
    /// Swift frameworks replaces this to resolve them as it reads (see
    /// `SwiftImportLoader`); the default is the ordinary loader.
    ///
    /// It returns a *new* Compilation as well as the module, because
    /// resolving an import teaches the dialect which symbols to call —
    /// reading and lowering are one decision, not two.
    public var readModule: (@Sendable (_ sourcePath: String, _ compilation: Compilation) throws -> (BIRModule, Compilation))?

    /// Creates a compilation.
    public init(dialect: any DialectCompiler, options: CompileOptions = CompileOptions(), toolchain: Toolchain = Toolchain()) {
        self.dialect = dialect
        self.options = options
        self.toolchain = toolchain
    }

    /// The BIR for a source file or project, for `--emit-bir`.
    public func bir(sourcePath: String) throws -> BIRModule {
        if let project = try ProjectManifest.load(at: sourcePath) {
            let libraries = try LibraryIndex.build(root: project.root, declared: project.libraries ?? [])
            let lines = try SourceLoader(projectRoot: project.root, libraries: libraries).load(path: project.entryPath)
            return try BIRBuilder(defaultStringSubstitution: project.stringSubstitution).build(lines, moduleName: project.name)
        }
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
        let (module, compilation) = try readModule.map { try $0(sourcePath, self) } ?? (try bir(sourcePath: sourcePath), self)
        return try compilation.dialect.lower(module, options: compilation.options).llvmIR
    }

    /// Compiles a source file to an executable at `output`.
    ///
    /// Intermediates (`.ll`, `.o`) go next to the output under
    /// `<output>.build/` so `--emit-llvm` has something to show and a failed
    /// clang run leaves evidence.
    public func build(sourcePath: String, output: String) throws {
        let (module, compilation) = try readModule.map { try $0(sourcePath, self) } ?? (try bir(sourcePath: sourcePath), self)
        let lowered = try compilation.dialect.lower(module, options: compilation.options)

        let buildDir = output + ".build"
        try FileManager.default.createDirectory(atPath: buildDir, withIntermediateDirectories: true)
        // `-o Build/roids` names a directory that may not exist yet, and the
        // linker will not make one.
        let outputDirectory = (output as NSString).deletingLastPathComponent
        if !outputDirectory.isEmpty {
            try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        }
        let irPath = (buildDir as NSString).appendingPathComponent("\(module.name).ll")
        let objectPath = (buildDir as NSString).appendingPathComponent("\(module.name).o")
        try toolchain.assemble(llvmIR: lowered.llvmIR, irPath: irPath, objectPath: objectPath, optimizationLevel: options.optimizationLevel)

        let runtime = compilation.dialect.runtimeLibrary(for: compilation.options.target)
        // The full runtime archive when there is one; else the core compiled
        // from source with the host half stubbed.
        let runtimeObject: String
        if let archive = try runtime.archive() {
            runtimeObject = archive
        } else if let reason = runtime.requiresArchiveBecause {
            throw CompileError([Diagnostic(
                severity: .error,
                file: sourcePath,
                message: "this dialect needs the runtime archive (libBASICRTHost.a) and none was found: \(reason). "
                    + "Set BASICC_RT_LIB to one, or install basicc so it sits beside its lib/ (see INSTALLATION.md)"
            )])
        } else {
            runtimeObject = try cachedRuntimeObject(runtime)
        }
        try toolchain.link(objects: [objectPath, runtimeObject] + compilation.extraObjects, output: output, extraArguments: runtime.linkArguments)
    }

    /// Compiles a source file to assembly text at `output`, for the SwiftPM
    /// build-tool plugin: no runtime is linked here — the package links the
    /// BASICRT product like any other dependency.
    public func buildAssembly(sourcePath: String, output: String) throws {
        let module = try bir(sourcePath: sourcePath)
        let lowered = try dialect.lower(module, options: options)
        let irPath = (output as NSString).deletingPathExtension + ".ll"
        try toolchain.assembleToAssembly(llvmIR: lowered.llvmIR, irPath: irPath, assemblyPath: output)
    }

    /// Where a build writes when `-o` was not given: `Build/<name>`,
    /// relative to the working directory, as `make` and every other compiler
    /// driver in this tree already assume.
    ///
    /// The intermediates follow the output — `<output>.build/` — so putting
    /// the output under `Build/` puts them there too and leaves the
    /// directory holding the source with nothing added to it.
    public static func defaultOutputPath(for sourcePath: String) -> String {
        ("Build" as NSString).appendingPathComponent(moduleName(for: sourcePath))
    }

    /// The module name for a source path: its base name without `.bas`, or
    /// the project's name.
    public static func moduleName(for sourcePath: String) -> String {
        if let project = try? ProjectManifest.load(at: sourcePath) { return project.name }
        return ((sourcePath as NSString).lastPathComponent as NSString).deletingPathExtension
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
            let staging = objectPath + ".\(UUID().uuidString).tmp"
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
