import Foundation

/// Where a dialect's runtime lives and how a compiled program links it.
///
/// Two shapes. The full runtime is a SwiftPM static product,
/// `libBASICRTHost.a`, which bundles the core (`BASICRT`), the host half
/// (`BASICRTHost`: VTG graphics, TUIKit, events), and their SDKs; it is
/// found (or rebuilt, in-tree) by ``archive(environment:)``. When no archive
/// can be had, the core's Swift sources are compiled to one object (`rt.o`),
/// cached beside the compiler's build products, with stubs for the host
/// entry points — a program still builds, and graphics report themselves
/// unsupported. Resolution order for the sources:
///
/// 1. `BASICC_RT_DIR` in the environment — tests and odd installs.
/// 2. `<prefix>/share/basicc/<name>` beside the installed `basicc` executable.
/// 3. The in-tree `Sources/<name>` of this package, found from `#filePath` —
///    the developer case, when `basicc` runs from `swift build`.
public struct RuntimeLibrary: Sendable {
    /// The runtime target's name, also its directory name: `"BASICRT"`.
    public let name: String

    /// Extra `swiftc` arguments the link needs (`-I`, `-L`, `-l` for
    /// frameworks the runtime depends on). Empty for the traditional runtime.
    public let linkArguments: [String]

    /// Creates a runtime library description.
    public init(name: String, linkArguments: [String] = []) {
        self.name = name
        self.linkArguments = linkArguments
    }

    /// The directory holding this runtime's Swift sources, or nil when none
    /// of the candidates exist.
    public func sourceDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        var candidates: [String] = []
        if let override = environment["BASICC_RT_DIR"] {
            candidates.append(override)
        }
        let executableDir = (Bundle.main.executablePath as NSString?)?.deletingLastPathComponent
        if let executableDir {
            candidates.append(((executableDir as NSString).appendingPathComponent("../share/basicc") as NSString)
                .appendingPathComponent(name))
        }
        candidates.append(Self.inTreeSourcesDirectory.appendingPathComponent(name).path)

        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Every `.swift` file in ``sourceDirectory(environment:)``, sorted, plus
    /// the host stubs beside it (`<name>HostStubs`) when they exist.
    public func sources(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> [String] {
        guard let directory = sourceDirectory(environment: environment) else {
            throw MissingRuntime(name: name)
        }
        func swiftFiles(in directory: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
                .filter { $0.hasSuffix(".swift") }
                .sorted()
                .map { (directory as NSString).appendingPathComponent($0) }
        }
        let stubs = ((directory as NSString).deletingLastPathComponent as NSString).appendingPathComponent("\(name)HostStubs")
        return swiftFiles(in: directory) + swiftFiles(in: stubs)
    }

    /// The full runtime archive, when one can be had:
    ///
    /// 1. `BASICC_RT_LIB` in the environment.
    /// 2. `<prefix>/lib/lib<name>Host.a` beside the installed `basicc`.
    /// 3. In-tree: `.build/release/lib<name>Host.a` of this package, rebuilt
    ///    with `swift build` when it is missing or older than the runtime
    ///    sources or the manifest.
    public func archive(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String? {
        if let override = environment["BASICC_RT_LIB"] {
            return FileManager.default.fileExists(atPath: override) ? override : nil
        }
        if let executableDir = (Bundle.main.executablePath as NSString?)?.deletingLastPathComponent {
            // `<prefix>/lib`, the conventional place for a local library —
            // reached by walking up from wherever this `basicc` was started,
            // never from a path written down here.
            let installed = ((executableDir as NSString).appendingPathComponent("../lib") as NSString)
                .appendingPathComponent("lib\(name)Host.a")
            if FileManager.default.fileExists(atPath: installed) { return installed }
        }
        let root = Self.inTreeSourcesDirectory.deletingLastPathComponent()
        let manifest = root.appendingPathComponent("Package.swift").path
        guard FileManager.default.fileExists(atPath: manifest) else { return nil }
        let archive = root.appendingPathComponent(".build/release/lib\(name)Host.a").path
        // The archive is also built from the packages the manifest names by
        // path — the runtime's host half links the interpreter's TUI binding
        // — so a change to one of those makes it stale too.
        let inputs = [manifest, root.appendingPathComponent("Sources/\(name)").path, root.appendingPathComponent("Sources/\(name)Host").path]
            + Self.siblingSourceDirectories(manifest: manifest, root: root)
        if Self.isStale(archive, against: inputs) {
            // Several compilers can run at once (a test sweep, a parallel
            // build). They would each start their own release build and then
            // fight over SwiftPM's package lock, so the first one through this
            // gate does the build and the rest wait and re-check.
            try Self.whileHoldingLock(at: root.appendingPathComponent(".build/basicc-runtime.lock").path) {
                guard Self.isStale(archive, against: inputs) else { return }
                let result = try ProcessRunner.xcrun("swift", ["build", "-c", "release", "--product", "\(name)Host", "--package-path", root.path])
                guard result.exitCode == 0 else {
                    throw ToolchainError(stage: "swift build (runtime)", exitCode: result.exitCode, stderr: result.stderr)
                }
            }
        }
        return FileManager.default.fileExists(atPath: archive) ? archive : nil
    }

    /// Runs `body` holding an exclusive lock on `path`, so concurrent
    /// compilers rebuild the runtime once between them rather than each
    /// starting a build of their own.
    private static func whileHoldingLock(at path: String, _ body: () throws -> Void) throws {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return try body() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return try body() }
        defer { flock(descriptor, LOCK_UN) }
        try body()
    }

    /// The `Sources` directory of every package the manifest names by a
    /// relative path.
    private static func siblingSourceDirectories(manifest: String, root: URL) -> [String] {
        guard let text = try? String(contentsOfFile: manifest, encoding: .utf8) else { return [] }
        var found: [String] = []
        var rest = Substring(text)
        while let start = rest.range(of: ".package(path: \"") {
            rest = rest[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            let path = String(rest[..<end])
            rest = rest[end...]
            guard path.hasPrefix("..") else { continue }
            let sources = URL(fileURLWithPath: path, relativeTo: root).appendingPathComponent("Sources").standardizedFileURL.path
            if FileManager.default.fileExists(atPath: sources) { found.append(sources) }
        }
        return found
    }

    /// Whether `archive` is missing or older than anything under `inputs`.
    private static func isStale(_ archive: String, against inputs: [String]) -> Bool {
        guard let archiveDate = (try? FileManager.default.attributesOfItem(atPath: archive))?[.modificationDate] as? Date else { return true }
        for input in inputs {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: input, isDirectory: &isDirectory) else { continue }
            // Recursive: a package keeps its sources in subdirectories, and
            // a change two levels down is still a change.
            let files: [String]
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(atPath: input)
                files = (enumerator?.allObjects as? [String] ?? []).map { (input as NSString).appendingPathComponent($0) }
            } else {
                files = [input]
            }
            for file in files {
                if let date = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date, date > archiveDate {
                    return true
                }
            }
        }
        return false
    }

    /// Raised when no candidate directory holds the runtime sources.
    public struct MissingRuntime: Error, CustomStringConvertible {
        /// The runtime that could not be found.
        public let name: String
        public var description: String {
            "runtime '\(name)' not found — set BASICC_RT_DIR or install with buildAndInstall.sh"
        }
    }

    /// `Code/BASICCompiler/Sources`, located from this file's own path.
    static var inTreeSourcesDirectory: URL {
        // #filePath is .../Sources/BASICCompilerKit/Driver/RuntimeLibrary.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Driver
            .deletingLastPathComponent()   // BASICCompilerKit
            .deletingLastPathComponent()   // Sources
    }
}
