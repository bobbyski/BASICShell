import BASICCompilerKit
import CryptoKit
import Foundation

/// Gets a module's mangled symbols from `swiftc` instead of computing them
/// (R0.5).
///
/// ## Why not compute them
///
/// Swift's mangler compresses repeated *words* inside an identifier and
/// repeated *types* inside a signature. Measured against 6.3.1 in a module
/// called `Roids`:
///
/// | Declared | Mangled |
/// |---|---|
/// | `class Sprite` | `$s5Roids6SpriteC` |
/// | `class RoidsSprite` | `$s5Roids0A6SpriteC` |
/// | `class AbRoids` | `$s5Roids02AbA0C` |
/// | `class XYRoids` | `$s5Roids7XYRoidsC` — *not* substituted |
/// | `func f(Double) -> Double` | `…yS2dF` — `Sd` twice, compressed |
///
/// Most of that is derivable. The `XYRoids` row is not: it is the same shape
/// as `AbRoids` and behaves differently, and a mangler written to a rule that
/// does not explain it would produce symbols that link on Tuesday and not on
/// Wednesday. A near-miss here is not a near-miss — it is a symbol nothing
/// resolves, or worse, one that resolves to something else.
///
/// So the compiler declares the shapes it is about to emit in a scratch Swift
/// file, compiles it to IR, and reads the names back. The toolchain that will
/// link the program is the authority on what the program's symbols are
/// called, which is the only source that cannot drift from it.
///
/// This is not a workaround with a cost — it is what makes arbitrary
/// signatures possible. Emitting only shapes whose mangling had been verified
/// by hand meant two.
///
/// ## The cost, and what it buys
///
/// One `swiftc -emit-ir` per program that declares classes, cached in the
/// user's cache directory by a hash of the declarations. A program whose
/// classes have not changed pays nothing.
public struct SwiftManglingProbe {
    /// A class whose symbols are wanted.
    public struct Declaration: Sendable {
        /// The Swift class name.
        public let name: String
        /// The base class's name, when it is in this module.
        public let base: String?
        /// Stored properties: name and Swift type spelling.
        public let properties: [(name: String, type: String)]
        /// Methods: name, parameter type spellings, and return spelling
        /// (`nil` for `Void`).
        public let methods: [(name: String, parameters: [String], returns: String?)]

        public init(name: String, base: String? = nil,
                    properties: [(name: String, type: String)] = [],
                    methods: [(name: String, parameters: [String], returns: String?)] = []) {
            self.name = name
            self.base = base
            self.properties = properties
            self.methods = methods
        }
    }

    /// The symbols a probe found, by the key the caller asked under.
    public struct Symbols: Sendable {
        /// Class name → mangled class prefix (`$s5Roids6SpriteC`).
        public var classes: [String: String] = [:]
        /// "Class.member" → mangled symbol.
        public var members: [String: String] = [:]

        /// No symbols — what a module with no classes has, and what a failed
        /// probe leaves behind.
        public init(classes: [String: String] = [:], members: [String: String] = [:]) {
            self.classes = classes
            self.members = members
        }

        /// The metadata symbol for a class.
        public func metadata(of className: String) -> String? {
            classes[className].map { $0 + "N" }
        }
        /// A member's symbol.
        public func member(_ name: String, of className: String) -> String? {
            members["\(className).\(name)"]
        }
    }

    /// The probe could not be run or its output could not be read.
    public struct Failure: Error, CustomStringConvertible {
        public let problem: String
        public var description: String { "could not determine Swift symbol names: \(problem)" }
    }

    /// Bumped whenever ``parse(_:)`` changes what it records, so cached
    /// answers from an older reader are not reused. The toolchain's own
    /// version is hashed alongside it, since a new Swift may mangle
    /// differently and every cached name would then be a stale claim.
    static let readerVersion = "2"

    /// The module the declarations belong to.
    public let module: String
    /// The classes.
    public let declarations: [Declaration]
    /// The module the root class comes from, imported by the probe.
    public let rootModule: String
    /// The root class every declared class descends from.
    public let rootClass: String

    public init(module: String, declarations: [Declaration],
                rootModule: String = "BASICRTSwift", rootClass: String = "BASICObject") {
        self.module = module
        self.declarations = declarations
        self.rootModule = rootModule
        self.rootClass = rootClass
    }

    /// The Swift source the probe compiles.
    ///
    /// Bodies are the minimum that type-checks; only the *declarations*
    /// matter, because only they decide a symbol's name.
    ///
    /// **The real root class is deliberately absent.** A class's mangled name
    /// and its members' names do not mention its base, so the probe needs no
    /// `import BASICRTSwift` — and asking for one coupled the probe to a
    /// `.swiftmodule` built by whichever toolchain SwiftPM used, which is not
    /// always the one `xcrun` finds. A class with no base in this module
    /// simply has none here.
    public func source() -> String {
        var lines = ["// Generated by basicc to ask swiftc what these symbols are called."]
        // What each class inherits, so a redeclaration is spelled `override`
        // — Swift refuses it otherwise, and the whole probe fails to compile
        // over a keyword that has nothing to do with the names being asked for.
        var inheritedMembers: [String: Set<String>] = [:]
        for declaration in ordered() {
            let inherits = declaration.base.map { ": \($0)" } ?? ""
            var visible = declaration.base.flatMap { inheritedMembers[$0] } ?? []
            lines.append("public class \(declaration.name)\(inherits) {")
            for property in declaration.properties {
                let modifier = visible.contains("var " + property.name) ? "override " : ""
                lines.append("  \(modifier)public var \(property.name): \(property.type) { get { fatalError() } set { } }")
                visible.insert("var " + property.name)
            }
            for method in declaration.methods {
                let parameters = method.parameters.enumerated()
                    .map { "_ a\($0.offset): \($0.element)" }.joined(separator: ", ")
                let returns = method.returns.map { " -> \($0)" } ?? ""
                let signature = "func \(method.name)(\(method.parameters.joined(separator: ",")))"
                let modifier = visible.contains(signature) ? "override " : ""
                // `throws`, as the interface declares every BASIC method (R4.6):
                // it is part of the mangled name (`…KF`), so the probe must ask
                // about the same shape the object file will define.
                lines.append("  \(modifier)public func \(method.name)(\(parameters)) throws\(returns) { fatalError() }")
                visible.insert(signature)
            }
            lines.append(declaration.base == nil ? "  public init() { }" : "  public override init() { super.init() }")
            lines.append("}")
            inheritedMembers[declaration.name] = visible
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Declarations with every base before its subclasses.
    func ordered() -> [Declaration] {
        var out: [Declaration] = []
        var placed = Set<String>()
        let byName = Dictionary(uniqueKeysWithValues: declarations.map { ($0.name, $0) })
        func place(_ declaration: Declaration) {
            guard !placed.contains(declaration.name) else { return }
            if let base = declaration.base, let parent = byName[base] { place(parent) }
            placed.insert(declaration.name)
            out.append(declaration)
        }
        for declaration in declarations { place(declaration) }
        return out
    }

    /// Runs the probe (or reads its cached answer) and returns the symbols.
    public func run(searchPaths: [String] = []) throws -> Symbols {
        guard !declarations.isEmpty else { return Symbols() }
        let text = source()
        var hasher = SHA256()
        hasher.update(data: Data(text.utf8))
        hasher.update(data: Data(searchPaths.joined(separator: ":").utf8))
        // The reader's version, so a fix to *parsing* invalidates entries the
        // old reader wrote. Hashing only the probe source meant a corrected
        // parser kept handing back the answers the broken one had cached.
        hasher.update(data: Data(Self.readerVersion.utf8))
        hasher.update(data: Data(((try? ProcessRunner.run("/usr/bin/xcrun", ["swiftc", "-version"]).stdout) ?? "").utf8))
        let digest = hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()

        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("basicc/mangling")
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cached = cacheDirectory.appendingPathComponent("\(module)-\(digest).json")
        if let data = try? Data(contentsOf: cached),
           let stored = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]],
           let classes = stored["classes"], let members = stored["members"] {
            return Symbols(classes: classes, members: members)
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("mangle-\(digest)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appendingPathComponent("Probe.swift")
        try text.write(to: file, atomically: true, encoding: .utf8)

        var arguments = ["swiftc", "-emit-ir", "-module-name", module, file.path]
        for path in searchPaths { arguments += ["-I", path] }
        let result = try ProcessRunner.run("/usr/bin/xcrun", arguments)
        guard result.exitCode == 0 else {
            throw Failure(problem: "the probe did not compile: \(result.stderr)")
        }
        let symbols = try parse(result.stdout)
        if let data = try? JSONSerialization.data(withJSONObject: ["classes": symbols.classes, "members": symbols.members]) {
            try? data.write(to: cached)
        }
        return symbols
    }

    /// Reads the emitted IR for the names.
    ///
    /// A class is found by its metadata symbol (`…CN`), which the IR always
    /// defines; members are matched by their demangled path, so nothing here
    /// has to know the mangling — which is the point.
    func parse(_ ir: String) throws -> Symbols {
        var symbols = Symbols()
        let mangled = Self.mangledNames(in: ir)
        guard !mangled.isEmpty else { throw Failure(problem: "the probe emitted no symbols") }
        let demangled = try Self.demangle(Array(mangled))
        for (symbol, name) in demangled {
            // `type metadata for Roids.Sprite` → the class's prefix.
            if symbol.hasSuffix("CN"), let className = name.components(separatedBy: "\(module).").last,
               name.hasPrefix("type metadata for "), declarations.contains(where: { $0.name == className }) {
                symbols.classes[className] = String(symbol.dropLast())
                continue
            }
            // `Roids.Sprite.area() -> Swift.Double` → Sprite.area
            guard let range = name.range(of: "\(module).") else { continue }
            let path = name[range.upperBound...]
            let parts = path.split(separator: ".", maxSplits: 1)
            guard parts.count == 2, declarations.contains(where: { $0.name == parts[0] }) else { continue }
            var member = String(parts[1].prefix { $0 != "(" && $0 != " " })
            // An accessor demangles as `Box.width.getter`; the member is the
            // property, and the role is the suffix.
            for role in [".getter", ".setter", ".modify", ".read", ".unsafeMutableAddressor"]
            where member.hasSuffix(role) {
                member = String(member.dropLast(role.count))
            }
            guard !member.isEmpty else { continue }
            let key = "\(parts[0]).\(member)"
            // Accessors and the initializer are distinguished by suffix, so
            // the first plain match wins and setters are recorded apart.
            if symbol.hasSuffix("vg") { symbols.members["\(key).get"] = symbol }
            else if symbol.hasSuffix("vs") { symbols.members["\(key).set"] = symbol }
            else if symbol.hasSuffix("F") { symbols.members[key] = symbol }
            else if symbol.hasSuffix("fC") { symbols.members["\(parts[0]).init"] = symbol }
        }
        return symbols
    }

    /// Every `$s…` symbol the IR defines or declares.
    static func mangledNames(in ir: String) -> Set<String> {
        var found = Set<String>()
        var current = ""
        var collecting = false
        for character in ir {
            if collecting {
                if character.isLetter || character.isNumber || character == "_" || character == "$" {
                    current.append(character)
                    continue
                }
                if current.count > 3 { found.insert(current) }
                collecting = false
                current = ""
            }
            if character == "$" { collecting = true; current = "$" }
        }
        if collecting, current.count > 3 { found.insert(current) }
        return found
    }

    /// Asks `swift demangle` what each symbol means.
    static func demangle(_ symbols: [String]) throws -> [(String, String)] {
        guard !symbols.isEmpty else { return [] }
        let result = try ProcessRunner.run("/usr/bin/xcrun", ["swift", "demangle", "-compact"] + symbols)
        guard result.exitCode == 0 else {
            throw Failure(problem: "swift demangle failed: \(result.stderr)")
        }
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return zip(symbols, lines).map { ($0, $1) }
    }
}
