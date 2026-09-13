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
        /// Every symbol those objects actually define.
        ///
        /// The graph says what the API *is*; this says what the binary
        /// *exports*, and they are not the same. A property the graph
        /// presents as a `var` may have no public setter — an actor's
        /// properties are read-only from outside, and a computed one may have
        /// no setter at all — and calling a symbol that is not there is a
        /// link error at the end of someone else's build. The plan asks for
        /// exactly this check ("validate every generated symbol against nm,
        /// or bindings rot silently").
        public var exported: Set<String> = []
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
        return ResolvedPackage(name: importName, path: path, symbolGraph: symbolGraph,
                               objects: objects, exported: Self.exportedSymbols(of: objects))
    }

    /// Compiles the async shim for `api`, or nil when it has no async
    /// methods. The object joins the program's link line.
    public func buildAsyncShim(for api: SwiftAPI, package: ResolvedPackage) throws -> String? {
        var methods: [SwiftAsyncShim.Method] = []
        for klass in api.classes {
            // Awaited methods, and methods taking a handler: the two shapes
            // that cannot be reached by a plain call from emitted IR.
            for method in klass.methods {
                let passed = method.passed
                let handlers = Set(passed.indices.filter { passed[$0].type == .voidClosure })
                // One predicate, asked in both places. When the emitter and
                // the shim generator each decided this for themselves they
                // disagreed, and a disagreement here is a call to a symbol
                // nothing defines.
                guard SwiftObjectModel.needsShim(method) else { continue }
                guard method.returns.isSupported else { continue }
                var shim = SwiftAsyncShim.Method(
                    className: klass.name, name: method.name,
                    labels: passed.map(\.label),
                    parameterTypes: passed.map { Self.spelling($0.type, in: api) },
                    returns: method.returns == .void ? nil : Self.spelling(method.returns, in: api),
                    isThrowing: method.isThrowing
                )
                shim.isAsync = method.isAsync
                shim.closureParameters = handlers
                shim.stringParameters = Set(passed.indices.filter { passed[$0].type == .string })
                shim.stringResult = method.returns == .string
                shim.durationParameters = Set(passed.indices.filter { passed[$0].type == .duration })
                shim.durationResult = method.returns == .duration
                for (index, parameter) in passed.enumerated() {
                    if case .object(let precise) = parameter.type, let klass = api.class(precise: precise) {
                        shim.objectParameters[index] = klass.name
                    }
                }
                if case .object(let precise) = method.returns, let klass = api.class(precise: precise) {
                    shim.objectResult = klass.name
                }
                if case .array(let element) = method.returns { shim.arrayResult = Self.elementKind(element) }
                for (index, parameter) in passed.enumerated() {
                    if case .array(let element) = parameter.type { shim.arrayParameters[index] = Self.elementKind(element) }
                }
                if case .payloadEnumeration(let precise) = method.returns, let type = api.enumerations[precise] {
                    shim.payloadResult = Self.payloadEnum(type, in: api)
                }
                for (index, parameter) in passed.enumerated() {
                    if case .payloadEnumeration(let precise) = parameter.type, let type = api.enumerations[precise] {
                        shim.payloadParameters[index] = Self.payloadEnum(type, in: api)
                    }
                }
                if case .enumeration(let precise) = method.returns, let type = api.enumerations[precise] {
                    shim.enumResult = Self.plainEnum(type)
                }
                for (index, parameter) in passed.enumerated() {
                    if case .enumeration(let precise) = parameter.type, let type = api.enumerations[precise] {
                        shim.enumParameters[index] = Self.plainEnum(type)
                    }
                }
                for (index, parameter) in passed.enumerated() {
                    if case .protocolType(let precise) = parameter.type, let name = api.protocols[precise] {
                        shim.protocolParameters[index] = name
                    }
                    guard case .structure = parameter.type else { continue }
                    var next = 0
                    guard let build = Self.rebuild(parameter.type, in: api, prefix: "a\(index)_", next: &next),
                          let leaves = api.leaves(of: parameter.type)
                    else { continue }
                    shim.structParameters[index] = (leaves.map { Self.spelling($0, in: api) }, build)
                }
                methods.append(shim)
            }
        }
        // Constructors need shims for the same reasons methods do.
        //
        // **One shim per arity, and the first one wins** — the same rule the
        // object model applies to its thunks, because the two have to agree on
        // which initializer `NEW C(x, y)` means. BASIC has a single NEW per
        // class, and two Swift initializers collapse onto one arity once
        // defaulted parameters are dropped: ActiveUI's `AUIStepper` has two
        // that both take three, and the shim defined the same `@_cdecl` symbol
        // twice, which does not compile.
        var emittedNew = Set<String>()
        for klass in api.classes {
            for initializer in klass.initializers {
                let passed = initializer.passed
                guard SwiftObjectModel.needsInitializerShim(initializer) else { continue }
                let arity = SwiftObjectModel.basicArity(initializer, in: api)
                guard emittedNew.insert("\(klass.name).\(arity)").inserted else { continue }
                var shim = SwiftAsyncShim.Method(
                    className: klass.name, name: "init",
                    labels: passed.map(\.label),
                    parameterTypes: passed.map { Self.spelling($0.type, in: api) },
                    returns: nil, isThrowing: initializer.isThrowing
                )
                shim.isAsync = false
                shim.isInitializer = true
                shim.basicArity = passed.reduce(0) { total, parameter in
                    if case .structure = parameter.type { return total + (api.leaves(of: parameter.type)?.count ?? 1) }
                    return total + 1
                }
                shim.closureParameters = Set(passed.indices.filter { passed[$0].type == .voidClosure })
                shim.stringParameters = Set(passed.indices.filter { passed[$0].type == .string })
                shim.durationParameters = Set(passed.indices.filter { passed[$0].type == .duration })
                shim.defaultedPointerSuffix = SwiftObjectModel.defaultedPointerSuffix(initializer)
                for (index, parameter) in passed.enumerated() {
                    if case .protocolType(let precise) = parameter.type, let name = api.protocols[precise] {
                        shim.protocolParameters[index] = name
                    }
                    if case .object(let precise) = parameter.type, let k = api.class(precise: precise) {
                        shim.objectParameters[index] = k.name
                    }
                    if case .array(let element) = parameter.type { shim.arrayParameters[index] = Self.elementKind(element) }
                    if case .payloadEnumeration(let precise) = parameter.type, let type = api.enumerations[precise] {
                        shim.payloadParameters[index] = Self.payloadEnum(type, in: api)
                    }
                    if case .enumeration(let precise) = parameter.type, let type = api.enumerations[precise] {
                        shim.enumParameters[index] = Self.plainEnum(type)
                    }
                    guard case .structure = parameter.type else { continue }
                    var next = 0
                    guard let build = Self.rebuild(parameter.type, in: api, prefix: "a\(index)_", next: &next),
                          let leaves = api.leaves(of: parameter.type) else { continue }
                    shim.structParameters[index] = (leaves.map { Self.spelling($0, in: api) }, build)
                }
                methods.append(shim)
            }
        }
        // Members on enums (E5): the receiver arrives as the enum value — an
        // ordinal or a record — or, for a static, there is none.
        for enumeration in api.enumerations.values.sorted(by: { $0.name < $1.name }) {
            let stem = enumeration.swiftName.replacingOccurrences(of: ".", with: "_")
            for (member, isStatic, isProperty) in SwiftInterfaceUnit.members(of: enumeration) {
                let passed = member.passed
                var shim = SwiftAsyncShim.Method(
                    className: stem, name: member.name, labels: passed.map(\.label),
                    parameterTypes: passed.map { Self.spelling($0.type, in: api) },
                    returns: member.returns == .void ? nil : Self.spelling(member.returns, in: api),
                    isThrowing: member.isThrowing
                )
                shim.isAsync = false
                shim.isProperty = isProperty
                shim.receiver = isStatic ? .type(enumeration.swiftName)
                    : enumeration.isPayload ? .payloadEnum(Self.payloadEnum(enumeration, in: api)) : .plainEnum(Self.plainEnum(enumeration))
                shim.stringParameters = Set(passed.indices.filter { passed[$0].type == .string })
                shim.stringResult = member.returns == .string
                for (index, parameter) in passed.enumerated() {
                    switch parameter.type {
                    case .object(let precise): shim.objectParameters[index] = api.class(precise: precise)?.name
                    case .enumeration(let precise): shim.enumParameters[index] = api.enumerations[precise].map(Self.plainEnum)
                    case .payloadEnumeration(let precise): shim.payloadParameters[index] = api.enumerations[precise].map { Self.payloadEnum($0, in: api) }
                    default: break
                    }
                }
                switch member.returns {
                case .object(let precise): shim.objectResult = api.class(precise: precise)?.name
                case .enumeration(let precise): shim.enumResult = api.enumerations[precise].map(Self.plainEnum)
                case .payloadEnumeration(let precise): shim.payloadResult = api.enumerations[precise].map { Self.payloadEnum($0, in: api) }
                default: break
                }
                methods.append(shim)
            }
        }
        // Enum-typed properties, read and written through the shim (E2).
        // Generated for the class that declares each one; a subclass's thunk
        // calls the same shim.
        var properties: [SwiftAsyncShim.EnumProperty] = []
        for klass in api.classes {
            for property in klass.properties {
                guard case .enumeration(let precise) = property.type, let type = api.enumerations[precise] else { continue }
                properties.append(SwiftAsyncShim.EnumProperty(
                    className: klass.name, name: property.name, type: Self.plainEnum(type),
                    isSettable: property.isSettable, isActor: klass.isActor
                ))
            }
        }
        // And those whose enum carries values (E4): a record each way.
        var payloadProperties: [SwiftAsyncShim.PayloadProperty] = []
        for klass in api.classes {
            for property in klass.properties {
                guard case .payloadEnumeration(let precise) = property.type, let type = api.enumerations[precise] else { continue }
                payloadProperties.append(SwiftAsyncShim.PayloadProperty(
                    className: klass.name, name: property.name, type: Self.payloadEnum(type, in: api),
                    isSettable: property.isSettable, isActor: klass.isActor
                ))
            }
        }
        guard let source = SwiftAsyncShim(module: api.module, methods: methods, properties: properties,
                                          payloadProperties: payloadProperties).source() else { return nil }

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

    /// An expression that rebuilds `type` from the flattened arguments named
    /// `<prefix><n>`, nested exactly as the struct is.
    ///
    /// The memberwise initializer's labels are its stored property names, in
    /// declaration order — which is the order the leaves arrive in.
    static func rebuild(_ type: SwiftAPI.ValueType, in api: SwiftAPI, prefix: String, next: inout Int) -> String? {
        guard case .structure(let precise) = type else {
            defer { next += 1 }
            return "\(prefix)\(next)"
        }
        guard let structure = api.structures[precise], !structure.fields.isEmpty else { return nil }
        var arguments: [String] = []
        for field in structure.fields {
            guard let inner = rebuild(field.type, in: api, prefix: prefix, next: &next) else { return nil }
            arguments.append("\(field.name): \(inner)")
        }
        return "\(structure.name)(\(arguments.joined(separator: ", ")))"
    }

    /// An enum whose cases carry values, as the shim generator takes it (E4):
    /// each case with its fields' Swift types and record slots.
    static func payloadEnum(_ type: SwiftAPI.Enumeration, in api: SwiftAPI) -> SwiftAsyncShim.PayloadEnum {
        SwiftAsyncShim.PayloadEnum(swiftName: type.swiftName, cases: type.cases.enumerated().map { index, name in
            let fields = type.payloads.indices.contains(index) ? type.payloads[index] : []
            return SwiftAsyncShim.PayloadEnum.Case(name: name, fields: fields.map { field in
                SwiftAsyncShim.PayloadEnum.Field(label: field.label, swiftType: spelling(field.type, in: api),
                                                 slot: type.slotIndex(of: field.name) ?? 0)
            })
        })
    }

    /// A plain enum as the shim generator takes it.
    static func plainEnum(_ type: SwiftAPI.Enumeration) -> SwiftAsyncShim.PlainEnum {
        SwiftAsyncShim.PlainEnum(swiftName: type.swiftName, cases: type.cases)
    }

    /// The tag the shim generator uses for an array's element kind.
    static func elementKind(_ type: SwiftAPI.ValueType) -> String {
        switch type {
        case .int: return "int"
        case .bool: return "bool"
        case .string: return "string"
        default: return "double"
        }
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
        // Named by the shim, which rebuilds it from the scalars BASIC passed.
        case .structure(let precise): return api.structures[precise]?.name ?? "Swift.Never"
        case .protocolType(let precise): return api.protocols[precise] ?? "Swift.Never"
        case .array(let element): return "[\(spelling(element, in: api))]"
        case .enumeration(let precise): return api.enumerations[precise]?.swiftName ?? "Swift.Never"
        case .payloadEnumeration(let precise): return api.enumerations[precise]?.swiftName ?? "Swift.Never"
        case .duration: return "Swift.Duration"
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
    /// The symbols a set of objects defines, without the leading underscore
    /// Mach-O adds.
    static func exportedSymbols(of objects: [String]) -> Set<String> {
        guard !objects.isEmpty,
              let result = try? ProcessRunner.run("/usr/bin/xcrun", ["nm", "-gjU"] + objects)
        else { return [] }
        var found = Set<String>()
        for line in result.stdout.split(separator: "\n") {
            let name = line.hasPrefix("_") ? String(line.dropFirst()) : String(line)
            if name.hasPrefix("$s") { found.insert(name) }
        }
        return found
    }

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
