import BASICCompilerKit
import Foundation

/// Finds the Swift package an `IMPORT "Name"` means and gets what the
/// compiler needs from it: its symbol graph and its compiled objects.
///
/// This is SwiftPM doing the dependency management, as Bobby asked: the
/// program's own `Package.swift` names its dependencies, `swift package
/// show-dependencies` says where they are, and each is built with
/// `swift build` in its own directory. Nothing is fetched or resolved by
/// `basicc` itself.
///
/// Path dependencies only, for now — the manifest's `.package(path:)`. A
/// remote dependency resolves into `.build/checkouts`, which
/// `show-dependencies` also reports, so it is the same walk once the
/// checkout exists; it just has not been exercised.
public struct SwiftPackageResolver {
    /// The directory holding the program and its `Package.swift`.
    public let programDirectory: String

    public init(programDirectory: String) {
        self.programDirectory = programDirectory
    }

    /// What an import resolved to.
    public struct ResolvedPackage: Sendable {
        /// The product/module name, as `IMPORT` spelled it.
        public let name: String
        /// The package's directory.
        public let path: String
        /// The symbol graph file for the module.
        public let symbolGraph: String
        /// The compiled objects to link.
        public let objects: [String]
    }

    /// The failure, with the command that produced it.
    public struct Failure: Error, CustomStringConvertible {
        public let importName: String
        public let problem: String
        public var description: String { "IMPORT \"\(importName)\": \(problem)" }
    }

    /// Every dependency the program's manifest names, by name.
    public func dependencies() throws -> [String: String] {
        let result = try ProcessRunner.run("/usr/bin/xcrun", ["swift", "package", "show-dependencies", "--format", "json"], workingDirectory: programDirectory)
        guard result.exitCode == 0, let data = result.stdout.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure(importName: "*", problem: "swift package show-dependencies failed in \(programDirectory): \(result.stderr)") }
        var found: [String: String] = [:]
        func walk(_ node: [String: Any]) {
            for dependency in (node["dependencies"] as? [[String: Any]]) ?? [] {
                if let name = dependency["name"] as? String, let path = dependency["path"] as? String { found[name] = path }
                walk(dependency)
            }
        }
        walk(root)
        return found
    }

    /// Resolves, builds and reads one import.
    public func resolve(_ importName: String) throws -> ResolvedPackage {
        let dependencies = try dependencies()
        guard let path = dependencies[importName] else {
            throw Failure(importName: importName, problem: "the program's Package.swift names no dependency called \(importName) (it has: \(dependencies.keys.sorted().joined(separator: ", ")))")
        }
        // Built in the package's own .build, the way any consumer builds it.
        let build = try ProcessRunner.run("/usr/bin/xcrun", ["swift", "build", "-c", "release", "--product", importName], workingDirectory: path)
        guard build.exitCode == 0 else {
            throw Failure(importName: importName, problem: "swift build failed in \(path): \(build.stderr)")
        }
        let graph = try ProcessRunner.run("/usr/bin/xcrun", ["swift", "package", "dump-symbol-graph", "--minimum-access-level", "public"], workingDirectory: path)
        guard graph.exitCode == 0 else {
            throw Failure(importName: importName, problem: "swift package dump-symbol-graph failed in \(path): \(graph.stderr)")
        }
        guard let symbolGraph = Self.find(named: "\(importName).symbols.json", under: (path as NSString).appendingPathComponent(".build")) else {
            throw Failure(importName: importName, problem: "no \(importName).symbols.json under \(path)/.build")
        }
        let objectDirectory = "\(path)/.build/release/\(importName).build"
        let objects = ((try? FileManager.default.contentsOfDirectory(atPath: objectDirectory)) ?? [])
            .filter { $0.hasSuffix(".o") }.sorted().map { (objectDirectory as NSString).appendingPathComponent($0) }
        guard !objects.isEmpty else {
            throw Failure(importName: importName, problem: "swift build produced no objects in \(objectDirectory)")
        }
        return ResolvedPackage(name: importName, path: path, symbolGraph: symbolGraph, objects: objects)
    }

    static func find(named name: String, under root: String) -> String? {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return nil }
        for case let entry as String in walker where entry.hasSuffix("/" + name) || entry == name {
            return (root as NSString).appendingPathComponent(entry)
        }
        return nil
    }
}
