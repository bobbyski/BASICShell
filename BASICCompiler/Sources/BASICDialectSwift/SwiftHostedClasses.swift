import BASICCompilerKit
import Foundation

/// BASIC classes whose base is an imported Swift class (R1.5).
///
/// Laid out by swiftc, not by basicc. basicc writes each such class as Swift —
/// a stored property per BASIC field, an initializer forwarding to the base's,
/// and an `override` per `OVERRIDES` method whose body calls the BASIC body —
/// and compiles it against the framework. That is the whole reason it works
/// for a *resilient* base as well as a fixed-layout one: a library-evolution
/// superclass needs its subclass's metadata instantiated from a pattern at run
/// time (`swift_initClassMetadata2`, override tables, field offsets computed
/// on the device), and swiftc emits exactly that for its own classes. Asking
/// the toolchain rather than reimplementing it is R0.5's rule, applied here to
/// layout.
///
/// The compiled class is then read back through its own symbol graph and handed
/// to the object model the way an imported class is, so construction, fields
/// and inherited calls take the paths imports already take. What is new is the
/// bridge each override calls: a Swift-callable entry onto the BASIC body.
public struct SwiftHostedClasses: Sendable {
    /// A program class found to inherit an imported one.
    struct Found: Sendable {
        let composite: BIRCompositeType
        let baseComposite: BIRCompositeType
        let baseModule: String
        let baseAPI: SwiftAPI
        let baseClass: SwiftAPI.Class
    }

    /// A hosted class as the object model takes it: like an imported class,
    /// plus the overrides whose bodies are BASIC's.
    public struct Entry: Sendable {
        public let composite: BIRCompositeType
        public let module: String
        /// The base's API with this class added, so a member lookup walks
        /// from the class into its base.
        public let api: SwiftAPI
        public let klass: SwiftAPI.Class
        /// Each override: the BIR function holding the BASIC body, and the
        /// Swift method it overrides.
        public let overrides: [(function: String, method: SwiftAPI.Function)]
    }

    /// Program classes whose direct base is an imported class.
    static func find(in module: BIRModule, imports: [String: SwiftAPI]) -> [Found] {
        var out: [Found] = []
        for type in module.types where type.isClass && type.externalModule == nil {
            guard let baseIndex = type.base,
                  let baseComposite = module.types.first(where: { $0.index == baseIndex }),
                  let baseModule = baseComposite.externalModule,
                  let api = imports[baseModule],
                  let klass = api.classes.first(where: { $0.name.uppercased() == baseComposite.name })
            else { continue }
            out.append(Found(composite: type, baseComposite: baseComposite, baseModule: baseModule, baseAPI: api, baseClass: klass))
        }
        return out
    }

    /// The generated module's name.
    static func moduleName(for program: String) -> String {
        "BASICHosted_" + SwiftObjectModel.swiftModuleName(program)
    }

    // Scalars are spelled bare — `String`, not `Swift.String` — because the
    // symbol graph of the generated class is read back by the same reader
    // imports use, and a qualified spelling reads as the type `Swift`.

    /// A BASIC field as a Swift stored property.
    static func storedProperty(_ type: BIRType) -> (spelling: String, zero: String)? {
        switch type {
        case .number: return ("Double", "0")
        case .boolean: return ("Bool", "false")
        case .string: return ("String", "\"\"")
        default: return nil
        }
    }

    /// A value that crosses an override's bridge.
    static func scalarSpelling(_ type: SwiftAPI.ValueType) -> String? {
        switch type {
        case .double: return "Double"
        case .int: return "Int"
        case .bool: return "Bool"
        case .string: return "String"
        default: return nil
        }
    }

    /// Whether a BASIC function's result can stand for a Swift method's.
    static func matches(_ basic: BIRType, _ swift: SwiftAPI.ValueType) -> Bool {
        switch (basic, swift) {
        case (.void, .void), (.number, .double), (.number, .int), (.boolean, .bool), (.string, .string): return true
        default: return false
        }
    }

    /// The overrides a hosted class declares: each BASIC method named like
    /// an overridable base method whose signature crosses the bridge.
    static func overrides(of found: Found, in module: BIRModule) -> [(function: String, method: SwiftAPI.Function)] {
        var out: [(String, SwiftAPI.Function)] = []
        let prefix = found.composite.name + "."
        for function in module.functions where function.name.hasPrefix(prefix) && !function.isExternal {
            let methodName = String(function.name.dropFirst(prefix.count))
            guard let method = SwiftObjectModel.method(named: methodName, of: found.baseClass, in: found.baseAPI),
                  method.isOverridable, !method.isAsync, !method.isThrowing,
                  method.passed.count == method.parameters.count,
                  method.parameters.allSatisfy({ scalarSpelling($0.type) != nil }),
                  method.returns == .void || scalarSpelling(method.returns) != nil,
                  matches(function.returnType, method.returns),
                  function.parameters.count == method.parameters.count + 1
            else { continue }
            out.append((function.name, method))
        }
        return out
    }

    /// The Swift function name a bridge is declared under.
    static func bridgeName(_ function: String) -> String {
        "basicHosted_" + function.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    }

    /// The generated Swift source.
    static func source(for found: [Found], module: BIRModule) throws -> String {
        var lines = [
            "// Generated by basicc: BASIC classes that inherit Swift classes (R1.5).",
            "// Laid out by swiftc; the method bodies are BASIC's. See SwiftHostedClasses.",
            "import Foundation",
        ]
        for name in Set(found.map(\.baseModule)).sorted() { lines.append("import \(name)") }
        lines.append("")
        for hosted in found {
            let display = hosted.composite.displayName
            let base = hosted.baseClass.name
            func refuse(_ reason: String) -> CompileError {
                CompileError("CLASS \(display) INHERITS \(base): \(reason)", at: nil)
            }
            guard SwiftObjectModel.isIdentifier(display) else { throw refuse("'\(display)' is not a Swift identifier") }
            guard hosted.baseClass.isOpen else { throw refuse("\(base) is not `open`, so Swift does not let it be subclassed outside its module") }
            let overrides = Self.overrides(of: hosted, in: module)
            if module.functions.contains(where: { $0.name == hosted.composite.name + ".NEW" && !$0.isExternal }) {
                throw refuse("it declares its own NEW; a class that inherits a Swift class takes its base's NEW for now")
            }
            for (function, method) in overrides {
                let parameters = ["_ me: UnsafeMutableRawPointer"]
                    + method.parameters.enumerated().map { "_ a\($0.offset): \(scalarSpelling($0.element.type)!)" }
                let returns = method.returns == .void ? "" : " -> \(scalarSpelling(method.returns)!)"
                lines.append("@_silgen_name(\"basic.hosted.\(function)\")")
                lines.append("private func \(bridgeName(function))(\(parameters.joined(separator: ", ")))\(returns)")
            }
            lines.append("open class \(display): \(hosted.baseModule).\(base) {")
            // Only the class's own fields: the base's are the framework's.
            let inherited = Set(hosted.baseComposite.fields.map(\.name))
            for field in hosted.composite.fields where !inherited.contains(field.name) {
                guard field.dimensions.isEmpty, let stored = storedProperty(field.type) else {
                    throw refuse("its field \(field.displayName) is \(field.type.name); a class that inherits a Swift class holds numbers, strings and booleans for now")
                }
                lines.append("    public var \(field.displayName): \(stored.spelling) = \(stored.zero)")
            }
            // NEW takes the base's arguments: the one initializer BASIC's NEW
            // means for the base, forwarded unchanged.
            guard let initializer = SwiftInterfaceUnit(api: hosted.baseAPI).chosenInitializer(of: hosted.baseClass) else {
                throw refuse("\(base) has no initializer BASIC can call")
            }
            var declared: [String] = []
            var forwarded: [String] = []
            for (offset, parameter) in initializer.passed.enumerated() {
                let spelling: String
                if let scalar = scalarSpelling(parameter.type) {
                    spelling = scalar
                } else if case .object(let precise) = parameter.type, let klass = hosted.baseAPI.class(precise: precise) {
                    spelling = "\(hosted.baseModule).\(klass.name)"
                } else {
                    throw refuse("\(base)'s initializer takes \(parameter.name), which a class inheriting it cannot forward yet")
                }
                declared.append("\(parameter.label ?? "_") a\(offset): \(spelling)")
                forwarded.append((parameter.label.map { "\($0): " } ?? "") + "a\(offset)")
            }
            // `override` exactly when this is the base's designated initializer
            // unchanged; leaving out a defaulted parameter makes it a new one.
            let isOverride = initializer.passed.count == initializer.parameters.count
            lines.append("    public \(isOverride ? "override " : "")init(\(declared.joined(separator: ", "))) {")
            lines.append("        super.init(\(forwarded.joined(separator: ", ")))")
            lines.append("    }")
            for (function, method) in overrides {
                let parameters = method.parameters.enumerated()
                    .map { "\($0.element.label ?? "_") a\($0.offset): \(scalarSpelling($0.element.type)!)" }
                let returns = method.returns == .void ? "" : " -> \(scalarSpelling(method.returns)!)"
                let arguments = (["Unmanaged.passUnretained(self).toOpaque()"] + method.parameters.indices.map { "a\($0)" })
                    .joined(separator: ", ")
                lines.append("    public override func \(method.name)(\(parameters.joined(separator: ", ")))\(returns) {")
                lines.append("        \(method.returns == .void ? "" : "return ")\(bridgeName(function))(\(arguments))")
                lines.append("    }")
            }
            lines.append("}")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Writes, compiles and reads back the hosted classes of a program.
    static func build(_ found: [Found], module: BIRModule) throws -> (object: String, entries: [Entry]) {
        let moduleName = moduleName(for: module.name)
        let source = try source(for: found, module: module)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("basicc-hosted-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let file = (directory as NSString).appendingPathComponent("\(moduleName).swift")
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        let object = (directory as NSString).appendingPathComponent("\(moduleName).o")
        var arguments = [
            "swiftc", "-parse-as-library", "-wmo", "-O", "-module-name", moduleName,
            "-emit-object", "-o", object,
            "-emit-module", "-emit-module-path", (directory as NSString).appendingPathComponent("\(moduleName).swiftmodule"),
            "-emit-symbol-graph", "-emit-symbol-graph-dir", directory, file,
        ]
        for path in Set(found.flatMap(\.baseAPI.searchPaths)).sorted() { arguments += ["-I", path] }
        let result = try ProcessRunner.run("/usr/bin/xcrun", arguments)
        guard result.exitCode == 0 else {
            throw CompileError("a class that inherits a Swift class did not compile as Swift (\(file)): \(result.stderr)", at: nil)
        }
        let api = try SwiftAPI.read(fileAt: (directory as NSString).appendingPathComponent("\(moduleName).symbols.json"))
        var entries: [Entry] = []
        for hosted in found {
            guard let klass = api.classes.first(where: { $0.name == hosted.composite.displayName }) else {
                throw CompileError("CLASS \(hosted.composite.displayName) compiled, but swiftc reported no class by that name", at: nil)
            }
            var merged = hosted.baseAPI
            merged.classes.append(klass)
            entries.append(Entry(composite: hosted.composite, module: moduleName, api: merged, klass: klass,
                                 overrides: overrides(of: hosted, in: module)))
        }
        return (object, entries)
    }
}
