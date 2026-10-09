import BASICCompilerKit
import BASICSyntax
import Foundation

/// `IMPORT` of a framework the app running the program contains (BASIC-45).
///
/// BASICStudio contains ActiveUI and TUIKit, and carries their *map*
/// (``SwiftFrameworkMap``): each framework's symbol graph and export list, and
/// a shim for every member compiled into the app. A program Studio compiles
/// imports a framework from that map — with no SwiftPM, no swiftc and no
/// framework build where it runs, which on an iPad is the only way there is.
///
/// ```text
///   IMPORT "ActiveUI"
///        │  nothing on disk answers to it
///        ▼
///   the map's graph + export list ─► SwiftAPI, as `basicc framework-map` read it
///        │                              └─ only what the app's shims answer
///        ▼
///   SwiftInterfaceUnit ─► BASIC ─► the Swift dialect, mapped (every member
///                                  through its shim, by name)
/// ```
///
/// Anything else a program imports is a BASIC file, as ever; a framework the
/// app does not contain is not importable here.
public struct SwiftMappedImports: Sendable {
    /// One framework in the map.
    public struct Framework: Sendable {
        /// The module name a program imports: `ActiveUI`.
        public let module: String
        /// Its symbol graph, as the map bundles it.
        public let symbolGraph: String
        /// The symbols the API was checked against when the map was made.
        public let exported: String

        public init(module: String, symbolGraph: String, exported: String) {
            self.module = module
            self.symbolGraph = symbolGraph
            self.exported = exported
        }
    }

    public let frameworks: [Framework]
    /// Every shim the app contains, by name.
    public let shims: Set<String>

    public init(frameworks: [Framework], shims: Set<String>) {
        self.frameworks = frameworks
        self.shims = shims
    }

    /// The framework an `IMPORT` names, if the map has it. Matched without
    /// regard to case, as BASIC matches names.
    public func framework(named name: String) -> Framework? {
        frameworks.first { $0.module.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// A framework's API: read from the map as `basicc framework-map` read
    /// it, then narrowed to what the app's shims answer.
    public func api(of framework: Framework) throws -> SwiftAPI {
        let key = framework.symbolGraph + "\n" + framework.exported
        if let cached = Self.cache.value(key) { return cached }
        var api = try SwiftAPI.read(fileAt: framework.symbolGraph)
        let exported = try String(contentsOfFile: framework.exported, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        api.keepOnly(exported: Set(exported))
        api.keepMapped(shims)
        Self.cache.store(api, key)
        return api
    }

    /// What a program's text came to: the module, and the frameworks it
    /// imported, for ``SwiftDialect``'s mapped mode.
    public struct Loaded {
        public let module: BIRModule
        public let imports: [String: SwiftAPI]
    }

    /// Reads program text — as the file at `path` when there is one, its
    /// imports found beside it — resolving imports of the map's frameworks
    /// as they are met. Mirrors `Compilation.bir(source:path:projectRoot:)`,
    /// which has no hook for them.
    public func load(source: String, path: String?, name: String, projectRoot: String? = nil,
                     options: CompileOptions = CompileOptions()) throws -> Loaded {
        var loader = SourceLoader()
        var moduleName = name
        var stringSubstitution = true
        if let projectRoot, let project = try ProjectManifest.load(at: projectRoot) {
            let libraries = try LibraryIndex.build(root: project.root, declared: project.libraries ?? [])
            loader = SourceLoader(projectRoot: project.root, libraries: libraries)
            moduleName = project.name
            stringSubstitution = project.stringSubstitution
        }
        final class Collected: @unchecked Sendable {
            var imports: [String: SwiftAPI] = [:]
            var externalClasses: [String: String] = [:]
            var enumMembers: [String: [String: SemanticModel.EnumMemberRef]] = [:]
            var externalFunctions: Set<String> = []
        }
        let collected = Collected()
        let mapped = self
        loader.resolveForeignImport = { name, location in
            guard let framework = mapped.framework(named: name) else { return nil }
            do {
                let api = try mapped.api(of: framework)
                collected.imports[api.module] = api
                let unit = SwiftInterfaceUnit(api: api)
                collected.enumMembers.merge(unit.enumMembers) { $1 }
                collected.externalFunctions.formUnion(unit.enumMemberFunctionNames)
                for className in unit.externalClassNames { collected.externalClasses[className] = api.module }
                let text = unit.render()
                // `BASICC_DUMP_UNITS=<dir>`, as for basicc's own imports.
                if let directory = ProcessInfo.processInfo.environment["BASICC_DUMP_UNITS"] {
                    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    try? text.write(toFile: (directory as NSString).appendingPathComponent("\(api.module).bas"),
                                    atomically: true, encoding: .utf8)
                }
                return text
            } catch {
                throw CompileError("IMPORT \"\(name)\": \(error)", at: location)
            }
        }
        let lines = try path.map { try loader.load(source: source, path: $0) }
            ?? loader.load(source: source, path: name + ".bas")
        let module = try BIRBuilder(defaultStringSubstitution: stringSubstitution,
                                    externalClasses: collected.externalClasses,
                                    externalFunctions: collected.externalFunctions,
                                    enumMembers: collected.enumMembers,
                                    hostedActiveUI: options.hostedActiveUI)
            .build(lines, moduleName: moduleName)
        return Loaded(module: module, imports: collected.imports)
    }

    /// Parsed APIs, by graph: a graph is megabytes of JSON, and the same one
    /// is read for every run of every program that imports it.
    private static let cache = APICache()

    private final class APICache: @unchecked Sendable {
        private let lock = NSLock()
        private var apis: [String: SwiftAPI] = [:]
        func value(_ key: String) -> SwiftAPI? {
            lock.lock(); defer { lock.unlock() }
            return apis[key]
        }
        func store(_ api: SwiftAPI, _ key: String) {
            lock.lock(); defer { lock.unlock() }
            apis[key] = api
        }
    }
}

extension SwiftAPI {
    /// Keeps only the members a map's shims answer (BASIC-45), so a program
    /// can name nothing the app cannot call: a member the generator had no
    /// shape for, or a map older than the framework. A property whose setter
    /// has no shim is read-only.
    public mutating func keepMapped(_ shims: Set<String>) {
        for index in classes.indices {
            let klass = classes[index]
            classes[index].initializers = klass.initializers.filter {
                shims.contains("basic_new_\(klass.name)_\(SwiftObjectModel.basicArity($0, in: self))")
            }
            classes[index].methods = klass.methods.filter {
                shims.contains(SwiftObjectModel.shimSymbol($0, of: klass.name))
            }
            classes[index].properties = klass.properties.compactMap { property in
                let getter = "basic_get_\(klass.name)_\(property.name)"
                let setter = "basic_set_\(klass.name)_\(property.name)"
                if case .handler = property.type { return shims.contains(setter) ? property : nil }
                guard shims.contains(getter) else { return nil }
                guard property.isSettable, !shims.contains(setter) else { return property }
                return Property(name: property.name, symbol: property.symbol, type: property.type, isSettable: false)
            }
        }
    }
}
