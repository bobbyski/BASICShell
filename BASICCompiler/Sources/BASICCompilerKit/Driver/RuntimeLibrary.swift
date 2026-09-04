import Foundation

/// Where a dialect's runtime lives and how a compiled program links it.
///
/// The runtime is Swift source compiled to one object (`rt.o`) and cached
/// beside the compiler's build products. Resolution order for the sources:
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

    /// Every `.swift` file in ``sourceDirectory(environment:)``, sorted.
    public func sources(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> [String] {
        guard let directory = sourceDirectory(environment: environment) else {
            throw MissingRuntime(name: name)
        }
        return try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .map { (directory as NSString).appendingPathComponent($0) }
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
