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
        // **Its own build directory, not the package's `.build`.** SwiftPM
        // takes an exclusive lock on a build directory, so building a
        // dependency in the place its author (or their editor, or another
        // tool) is already building it makes `basicc` wait on a lock it
        // cannot see — and the failure looks like a broken import rather than
        // a busy directory. Stable rather than temporary, so a second compile
        // of the same program costs nothing.
        let scratch = (path as NSString).appendingPathComponent(".build-basicc")
        let build = try ProcessRunner.run("/usr/bin/xcrun", [
            "swift", "build", "-c", "release", "--product", importName,
            "--scratch-path", scratch,
        ], workingDirectory: path)
        guard build.exitCode == 0 else {
            throw Failure(importName: importName, problem: "swift build failed in \(path):\n\(Self.lastLines(build.stderr))")
        }
        let graph = try ProcessRunner.run("/usr/bin/xcrun", [
            // `--scratch-path` belongs to `swift package`, not to the
            // subcommand, so it goes before the verb.
            "swift", "package", "--scratch-path", scratch,
            "dump-symbol-graph", "--minimum-access-level", "public",
        ], workingDirectory: path)
        // The graph we asked for, not the exit code. `dump-symbol-graph`
        // walks *every* target in the package — tests and sample executables
        // included — and fails as a whole if any one of them fails. TUIKit's
        // test module is enough to stop the import of TUIKit itself, which is
        // not a fact about TUIKit's API. So: if the module's own graph was
        // written, the import succeeds, and the command's complaint is only
        // reported when the file is genuinely absent.
        guard let symbolGraph = Self.find(named: "\(importName).symbols.json", under: scratch) else {
            let detail = graph.exitCode == 0
                ? "no \(importName).symbols.json was written under \(scratch)"
                : "swift package dump-symbol-graph failed in \(path):\n\(Self.lastLines(graph.stderr))"
            throw Failure(importName: importName, problem: detail)
        }
        let objectDirectory = "\(scratch)/release/\(importName).build"
        let objects = ((try? FileManager.default.contentsOfDirectory(atPath: objectDirectory)) ?? [])
            .filter { $0.hasSuffix(".o") }.sorted().map { (objectDirectory as NSString).appendingPathComponent($0) }
        guard !objects.isEmpty else {
            throw Failure(importName: importName, problem: "swift build produced no objects in \(objectDirectory)")
        }
        return ResolvedPackage(name: importName, path: path, symbolGraph: symbolGraph, objects: objects)
    }

    /// Compiles the async shim for `api`, or nil when it has no async
    /// methods. The object joins the program's link line.
    public func buildAsyncShim(for api: SwiftAPI, package: ResolvedPackage) throws -> String? {
        var methods: [SwiftAsyncShim.Method] = []
        for klass in api.classes {
            // Awaited methods, and methods taking a handler: the two shapes
            // that cannot be reached by a plain call from emitted IR.
            for method in klass.methods {
                let handlers = Set(method.parameters.indices.filter { method.parameters[$0].type == .voidClosure })
                guard method.isAsync || !handlers.isEmpty else { continue }
                guard method.returns.isSupported, method.parameters.allSatisfy(\.type.isSupported) else { continue }
                var shim = SwiftAsyncShim.Method(
                    className: klass.name, name: method.name,
                    labels: method.parameters.map(\.label),
                    parameterTypes: method.parameters.map { Self.spelling($0.type, in: api) },
                    returns: method.returns == .void ? nil : Self.spelling(method.returns, in: api),
                    isThrowing: method.isThrowing
                )
                shim.isAsync = method.isAsync
                shim.closureParameters = handlers
                for (index, parameter) in method.parameters.enumerated() {
                    if case .object(let precise) = parameter.type, let klass = api.class(precise: precise) {
                        shim.objectParameters[index] = klass.name
                    }
                }
                if case .object(let precise) = method.returns, let klass = api.class(precise: precise) {
                    shim.objectResult = klass.name
                }
                methods.append(shim)
            }
        }
        guard let source = SwiftAsyncShim(module: api.module, methods: methods).source() else { return nil }

        let directory = (package.path as NSString).appendingPathComponent(".build-basicc/shims")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let file = (directory as NSString).appendingPathComponent("\(api.module)Await.swift")
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        let object = (directory as NSString).appendingPathComponent("\(api.module)Await.o")

        // Built against the framework's own module, and against BASICRTSwift
        // for the error raiser a failing await hands its error to.
        var arguments = ["swiftc", "-parse-as-library", "-emit-object", "-O", file, "-o", object]
        for modules in Self.moduleSearchPaths(package: package) { arguments += ["-I", modules] }
        let result = try ProcessRunner.run("/usr/bin/xcrun", arguments)
        guard result.exitCode == 0 else {
            throw Failure(importName: api.module, problem: "the await shim did not compile: \(result.stderr)")
        }
        return object
    }

    /// A Swift type's spelling in generated shim source.
    static func spelling(_ type: SwiftAPI.ValueType, in api: SwiftAPI) -> String {
        switch type {
        case .double: return "Swift.Double"
        case .int: return "Swift.Int"
        case .bool: return "Swift.Bool"
        case .string: return "Swift.String"
        case .object(let precise): return api.class(precise: precise)?.name ?? "AnyObject"
        case .void: return "Swift.Void"
        // Spelled by the shim itself, which takes the pair BASIC can supply.
        case .voidClosure: return "() -> Swift.Void"
        case .unsupported: return "Swift.Never"
        }
    }

    /// Where `swiftc` should look for the framework's module and for
    /// BASICRTSwift.
    static func moduleSearchPaths(package: ResolvedPackage) -> [String] {
        var paths: [String] = []
        for build in [".build-basicc", ".build"] {
            for configuration in ["release", "debug"] {
                let modules = "\(package.path)/\(build)/\(configuration)/Modules"
                if FileManager.default.fileExists(atPath: modules) { paths.append(modules) }
                let flat = "\(package.path)/\(build)/\(configuration)"
                if FileManager.default.fileExists(atPath: flat) { paths.append(flat) }
            }
        }
        if let extra = ProcessInfo.processInfo.environment["BASICC_SWIFT_MODULES"] {
            paths += extra.split(separator: ":").map(String.init)
        }
        return paths
    }

    /// The tail of a tool's output. A failing SwiftPM run prints its whole
    /// build log, and burying the one line that matters under a hundred
    /// progress lines helps nobody.
    static func lastLines(_ text: String, count: Int = 12) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(count).joined(separator: "\n")
    }

    static func find(named name: String, under root: String) -> String? {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return nil }
        for case let entry as String in walker where entry.hasSuffix("/" + name) || entry == name {
            return (root as NSString).appendingPathComponent(entry)
        }
        return nil
    }
}
