import Foundation

/// A Swift module's public API, read from the symbol graph `swift package
/// dump-symbol-graph` writes (R4.1).
///
/// The graph is what makes importing a framework a *binding* problem rather
/// than a bridging one: every member arrives with its **canonical mangled
/// symbol** (`s:6Shapes5ShapeC4areaSdyF`), so nothing imported is ever
/// mangled by `basicc` — the toolchain's own name is the one linked.
///
/// ## Skips are reasoned, never silent
///
/// A member whose shape BASIC cannot express yet is kept in ``skipped`` with
/// the reason, and `basicc import-report` prints them. A binding layer that
/// quietly drops half a framework rots without anyone noticing; this one is
/// wrong only out loud.
public struct SwiftAPI: Sendable {
    /// A type a signature names, as far as BASIC can follow it.
    public enum ValueType: Sendable, Equatable {
        /// `Swift.Double` — a BASIC number.
        case double
        /// `Swift.Int` — a BASIC number, converted at the boundary.
        case int
        /// `Swift.Bool`.
        case bool
        /// `Swift.String`, converted at the boundary (R2.0).
        case string
        /// A class from this module, by its mangled prefix (`s:6Shapes5ShapeC`).
        case object(precise: String)
        /// Nothing.
        case void
        /// Something BASIC has no spelling for yet — the spelling is kept for
        /// the report.
        case unsupported(String)

        var isSupported: Bool {
            if case .unsupported = self { return false }
            return true
        }
    }

    /// One parameter of a method or initializer.
    public struct Parameter: Sendable, Equatable {
        /// The argument label, or nil for `_`.
        public let label: String?
        /// The internal name, which is what BASIC calls the parameter.
        public let name: String
        public let type: ValueType
    }

    /// A method, initializer or free function.
    public struct Function: Sendable, Equatable {
        /// The base name: `scale` for `scale(by:)`.
        public let name: String
        /// The symbol's mangled form with its `$s` prefix, callable as is.
        public let symbol: String
        public let parameters: [Parameter]
        public let returns: ValueType
        /// `true` for an initializer, whose symbol is the *initializing* half;
        /// the allocating half is ``allocatingSymbol``.
        public let isInitializer: Bool
        /// Whether a subclass may override it (`open`).
        public let isOverridable: Bool

        /// The allocating initializer, the entry a caller uses: the graph
        /// records `…cfc`, and the allocating twin is `…cfC`.
        public var allocatingSymbol: String {
            guard isInitializer, symbol.hasSuffix("c") else { return symbol }
            return String(symbol.dropLast()) + "C"
        }

        var isSupported: Bool {
            returns.isSupported && parameters.allSatisfy(\.type.isSupported)
        }
    }

    /// A stored or computed property.
    public struct Property: Sendable, Equatable {
        public let name: String
        /// The property symbol (`…vp`); getter is `…vg`, setter `…vs`.
        public let symbol: String
        public let type: ValueType
        public let isSettable: Bool

        public var getterSymbol: String { String(symbol.dropLast(2)) + "vg" }
        public var setterSymbol: String { String(symbol.dropLast(2)) + "vs" }
    }

    /// A class.
    public struct Class: Sendable {
        public let name: String
        /// Mangled prefix, `$s6Shapes5ShapeC`.
        public let symbol: String
        /// The precise identifier as the graph spells it, `s:6Shapes5ShapeC`.
        public let precise: String
        /// The superclass's precise identifier, when it is in this module.
        public let superclassPrecise: String?
        public let isOpen: Bool
        public let isFinal: Bool
        public var initializers: [Function]
        public var methods: [Function]
        public var properties: [Property]
    }

    /// One member left out, and why.
    public struct Skip: Sendable {
        public let member: String
        public let reason: String
    }

    public let module: String
    public var classes: [Class]
    public var functions: [Function]
    public var skipped: [Skip]

    /// A class by its precise identifier.
    public func `class`(precise: String) -> Class? {
        classes.first { $0.precise == precise }
    }

    // MARK: - Reading the graph

    /// Reads `<Module>.symbols.json`.
    public static func read(fileAt path: String) throws -> SwiftAPI {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let graph = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReadError(path: path, problem: "not a JSON object")
        }
        return try parse(graph, path: path)
    }

    /// The file could not be read as a symbol graph.
    public struct ReadError: Error, CustomStringConvertible {
        public let path: String
        public let problem: String
        public var description: String { "\(path): \(problem)" }
    }

    static func parse(_ graph: [String: Any], path: String) throws -> SwiftAPI {
        guard let moduleInfo = graph["module"] as? [String: Any], let module = moduleInfo["name"] as? String,
              let symbols = graph["symbols"] as? [[String: Any]],
              let relationships = graph["relationships"] as? [[String: Any]]
        else { throw ReadError(path: path, problem: "missing module, symbols or relationships") }

        var api = SwiftAPI(module: module, classes: [], functions: [], skipped: [])
        var memberOf: [String: String] = [:]
        var inherits: [String: String] = [:]
        for relationship in relationships {
            guard let kind = relationship["kind"] as? String,
                  let source = relationship["source"] as? String,
                  let target = relationship["target"] as? String else { continue }
            if kind == "memberOf" { memberOf[source] = target }
            if kind == "inheritsFrom" { inherits[source] = target }
        }

        // Classes first, so members have somewhere to go.
        var classIndex: [String: Int] = [:]
        for symbol in symbols {
            guard kind(of: symbol) == "swift.class", let precise = precise(of: symbol), let name = name(of: symbol) else { continue }
            let fragments = fragments(of: symbol["declarationFragments"])
            let modifiers = Set(fragments.filter { $0.kind == "keyword" }.map(\.spelling))
            classIndex[precise] = api.classes.count
            api.classes.append(Class(
                name: name, symbol: "$s" + precise.dropFirst(2), precise: precise,
                superclassPrecise: inherits[precise],
                // `open` is an access level, not a declaration keyword —
                // the fragments say `class`, the accessLevel says `open`.
                isOpen: (symbol["accessLevel"] as? String) == "open",
                isFinal: modifiers.contains("final"),
                initializers: [], methods: [], properties: []
            ))
        }

        for symbol in symbols {
            guard let precise = precise(of: symbol), let name = name(of: symbol) else { continue }
            let path = (symbol["pathComponents"] as? [String])?.joined(separator: ".") ?? name
            // Synthesized members (`Unit.!=`) belong to the standard library.
            if precise.contains("::SYNTHESIZED::") { continue }
            switch kind(of: symbol) {
            case "swift.method", "swift.init", "swift.func":
                let isInit = kind(of: symbol) == "swift.init"
                let function = Function(
                    name: isInit ? "init" : name,
                    symbol: "$s" + precise.dropFirst(2),
                    parameters: parameters(of: symbol),
                    returns: isInit ? .void : returnType(of: symbol),
                    isInitializer: isInit,
                    isOverridable: (symbol["accessLevel"] as? String) == "open"
                )
                if !function.isSupported {
                    let bad = function.parameters.compactMap { p -> String? in
                        if case .unsupported(let spelling) = p.type { return "\(p.name): \(spelling)" }
                        return nil
                    } + { if case .unsupported(let s) = function.returns { return ["returns \(s)"] } else { return [] } }()
                    api.skipped.append(Skip(member: path, reason: "no BASIC spelling for " + bad.joined(separator: ", ")))
                    continue
                }
                if let owner = memberOf[precise], let index = classIndex[owner] {
                    if isInit { api.classes[index].initializers.append(function) } else { api.classes[index].methods.append(function) }
                } else if kind(of: symbol) == "swift.func" {
                    api.functions.append(function)
                } else {
                    api.skipped.append(Skip(member: path, reason: "member of something that is not a class"))
                }
            case "swift.property":
                let fragments = fragments(of: symbol["declarationFragments"])
                let type = fragments.first { $0.kind == "typeIdentifier" }.map { valueType(precise: $0.precise, spelling: $0.spelling) } ?? .unsupported("?")
                let isLet = fragments.contains { $0.kind == "keyword" && $0.spelling == "let" }
                // `{ get }` in the declaration marks a read-only computed
                // property; a stored `var` shows no accessor block.
                let readOnly = isLet || fragments.contains { $0.spelling.contains("{ get }") }
                guard let owner = memberOf[precise], let index = classIndex[owner] else {
                    api.skipped.append(Skip(member: path, reason: "a property of something that is not a class")); continue
                }
                guard type.isSupported else {
                    if case .unsupported(let s) = type { api.skipped.append(Skip(member: path, reason: "no BASIC spelling for \(s)")) }
                    continue
                }
                api.classes[index].properties.append(Property(name: name, symbol: "$s" + precise.dropFirst(2), type: type, isSettable: !readOnly))
            case "swift.class":
                continue
            case let other:
                api.skipped.append(Skip(member: path, reason: "\(other) has no BASIC counterpart yet"))
            }
        }
        return api
    }

    // MARK: - Graph pieces

    struct Fragment { let kind: String; let spelling: String; let precise: String? }

    static func kind(of symbol: [String: Any]) -> String { (symbol["kind"] as? [String: Any])?["identifier"] as? String ?? "" }
    static func precise(of symbol: [String: Any]) -> String? { (symbol["identifier"] as? [String: Any])?["precise"] as? String }
    static func name(of symbol: [String: Any]) -> String? {
        // `scale(by:)` → `scale`; `init(radius:)` → `init`.
        ((symbol["names"] as? [String: Any])?["title"] as? String).map { String($0.prefix { $0 != "(" }) }
    }
    static func fragments(of value: Any?) -> [Fragment] {
        ((value as? [[String: Any]]) ?? []).map {
            Fragment(kind: $0["kind"] as? String ?? "", spelling: $0["spelling"] as? String ?? "", precise: $0["preciseIdentifier"] as? String)
        }
    }
    /// The argument labels a member's title spells: `scale(by:)` → `["by"]`,
    /// `compare(_:)` → `[nil]`.
    ///
    /// The title is the only place the graph distinguishes `_` from a label:
    /// a parameter's `name` field carries the *internal* name when there is
    /// no external one, so `func compare(_ other: Shape)` reports "other"
    /// there and would import as `compare(other:)` — a call Swift refuses.
    static func labels(of symbol: [String: Any]) -> [String?] {
        guard let title = (symbol["names"] as? [String: Any])?["title"] as? String,
              let open = title.firstIndex(of: "("), title.hasSuffix(")")
        else { return [] }
        let inside = title[title.index(after: open)..<title.index(before: title.endIndex)]
        guard !inside.isEmpty else { return [] }
        return inside.split(separator: ":", omittingEmptySubsequences: false).dropLast().map {
            $0 == "_" ? nil : String($0)
        }
    }

    static func parameters(of symbol: [String: Any]) -> [Parameter] {
        let signature = symbol["functionSignature"] as? [String: Any]
        let titleLabels = labels(of: symbol)
        return ((signature?["parameters"] as? [[String: Any]]) ?? []).enumerated().map { position, parameter in
            let fragments = fragments(of: parameter["declarationFragments"])
            // Everything after the `: ` is the type, and it counts only when
            // it is exactly one type identifier. Taking the first identifier
            // and ignoring what surrounds it made `[Shape]` import as
            // `Shape` — a parameter that would take the array's element.
            let afterColon = fragments.drop { !$0.spelling.contains(":") }.dropFirst()
            let type: ValueType
            if afterColon.count == 1, let only = afterColon.first, only.kind == "typeIdentifier" {
                type = valueType(precise: only.precise, spelling: only.spelling)
            } else {
                // The whole declared type, for the report: dropping the name
                // and then the ": " lost the leading bracket, so `[Shape]`
                // was reported as `Shape]`.
                let declared = fragments.drop { $0.kind == "identifier" }
                    .map(\.spelling).joined()
                    .drop { $0 == ":" || $0 == " " }
                type = .unsupported(String(declared))
            }
            let declared = parameter["name"] as? String
            let internalName = parameter["internalName"] as? String ?? declared ?? "value"
            let label = titleLabels.indices.contains(position) ? titleLabels[position] : declared
            return Parameter(label: label, name: internalName, type: type)
        }
    }
    static func returnType(of symbol: [String: Any]) -> ValueType {
        let signature = symbol["functionSignature"] as? [String: Any]
        let fragments = fragments(of: signature?["returns"])
        if fragments.isEmpty || fragments.map(\.spelling).joined() == "()" { return .void }
        // A bare type identifier is the whole return type; anything wrapped
        // (`[Shape]`, `Shape?`) is more than one fragment and unsupported.
        guard fragments.count == 1, let only = fragments.first, only.kind == "typeIdentifier" else {
            return .unsupported(fragments.map(\.spelling).joined())
        }
        return valueType(precise: only.precise, spelling: only.spelling)
    }
    static func valueType(precise: String?, spelling: String) -> ValueType {
        switch precise {
        case "s:Sd": return .double
        case "s:Si": return .int
        case "s:Sb": return .bool
        case "s:SS": return .string
        case let precise? where precise.hasSuffix("C"): return .object(precise: precise)
        default: return .unsupported(spelling)
        }
    }
}
