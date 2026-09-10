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
        /// A `() -> Void` parameter — an event handler (R4.5). BASIC hands
        /// one over as a closure; the shim wraps it in a Swift closure.
        case voidClosure
        /// A protocol — `TerminalDriver`. BASIC sees an INTERFACE, and any
        /// imported class the graph says conforms may be passed (R4.7).
        case protocolType(precise: String)
        /// A struct of scalars — a rect, a point, a colour (R4.4). It crosses
        /// **flattened**: BASIC passes the leaf values and the shim builds the
        /// struct, so `Window.init(frame: Rect)` reads `NEW Window(x, y, w, h)`.
        case structure(precise: String)
        /// A `[T]` of scalars or imported classes (R4.7). It crosses as a
        /// BASIC array carried in a VARIANT — the shape BASIC already has for
        /// "an array a function hands back" — so `LEN(v)` and `v(i)` walk it
        /// with nothing new in the language.
        indirect case array(element: ValueType)
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
        /// Whether the declaration gives it a default.
        ///
        /// A parameter BASIC cannot spell does not have to block the member:
        /// if Swift will supply a value, the shim simply does not pass one.
        /// `HeadlessDriver.init(size:supportsGraphicsChrome:graphicsCapabilities:)`
        /// is constructible from BASIC for exactly this reason — the optional
        /// it could not name defaults to nil.
        public var hasDefault: Bool = false
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
        /// Whether it must be awaited.
        ///
        /// Like `throws`, this is load-bearing: an `async` function has an
        /// entirely different ABI — a context pointer and a continuation, not
        /// a plain call — so importing one as ordinary would not merely lose
        /// the suspension, it would call the wrong thing.
        public var isAsync: Bool = false
        /// Whether it can throw.
        ///
        /// Load-bearing, not decorative: a `throws` function takes a hidden
        /// `swifterror` register in Swift's ABI, so calling one as though it
        /// were an ordinary function passes garbage where the callee will
        /// store a thrown error. It read as an ordinary method before this,
        /// which is a correctness bug and not merely a missing feature.
        public var isThrowing: Bool = false

        /// The allocating initializer, the entry a caller uses: the graph
        /// records `…cfc`, and the allocating twin is `…cfC`.
        public var allocatingSymbol: String {
            guard isInitializer, symbol.hasSuffix("c") else { return symbol }
            return String(symbol.dropLast()) + "C"
        }

        var isSupported: Bool {
            // A parameter that cannot cross blocks the member only when the
            // caller must supply it.
            returns.isSupported && parameters.allSatisfy { $0.type.isSupported || $0.hasDefault }
        }

        /// The parameters BASIC actually passes: the ones it can spell.
        public var passed: [Parameter] {
            parameters.filter { $0.type.isSupported }
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

    /// A struct, and the scalars it flattens to.
    public struct Structure: Sendable {
        public let name: String
        /// The precise identifier, `s:6TUIKit4RectV`.
        public let precise: String
        /// What its initializer takes, in order.
        ///
        /// **The initializer, not the property list.** A struct's properties
        /// include computed ones — `Size` publishes `isEmpty` and
        /// `cellCount`, `Rect` publishes `minX`…`maxY` — and flattening those
        /// built calls like `Size(width:height:isEmpty:cellCount:)`, which is
        /// not an initializer that exists. What a value is *built from* is
        /// exactly what its initializer takes.
        public var fields: [(name: String, type: ValueType)] = []
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
        /// Whether it is an `actor`.
        ///
        /// An actor's methods are isolated to it, so reaching one from
        /// outside means awaiting it — `MainActor.assumeIsolated` is no help
        /// because the isolation is not the main actor's. TUIKit's drivers
        /// are actors, which is how this surfaced.
        public var isActor: Bool = false
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
    /// Structs, by precise identifier.
    public var structures: [String: Structure] = [:]
    /// Protocol names, by precise identifier.
    public var protocols: [String: String] = [:]
    /// Which protocols each class conforms to, by precise identifier.
    public var conformances: [String: [String]] = [:]
    public var functions: [Function]
    public var skipped: [Skip]

    /// The scalars a type flattens to at a call boundary.
    ///
    /// A scalar is itself; a struct is its stored properties, recursively —
    /// `Rect` is `Point` and `Size`, which are two numbers each, so a `Rect`
    /// parameter is four. Nil when something in the tree has no BASIC
    /// spelling, which is what keeps a struct of arrays out.
    ///
    /// Bounded against a cycle, which a value type cannot have but a
    /// malformed graph could describe.
    public func leaves(of type: ValueType, depth: Int = 0) -> [ValueType]? {
        guard depth < 8 else { return nil }
        guard case .structure(let precise) = type else {
            return type.isSupported ? [type] : nil
        }
        guard let structure = structures[precise], !structure.fields.isEmpty else { return nil }
        var out: [ValueType] = []
        for field in structure.fields {
            guard let inner = leaves(of: field.type, depth: depth + 1) else { return nil }
            out += inner
        }
        return out
    }

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
            if kind == "conformsTo" { api.conformances[source, default: []].append(target) }
        }

        for symbol in symbols where kind(of: symbol) == "swift.protocol" {
            guard let precise = precise(of: symbol), let name = name(of: symbol) else { continue }
            api.protocols[precise] = name
        }

        // Structs first: a class member may name one, and flattening it
        // needs its fields already known.
        for symbol in symbols {
            guard kind(of: symbol) == "swift.struct", let precise = precise(of: symbol), let name = name(of: symbol) else { continue }
            api.structures[precise] = Structure(name: name, precise: precise)
        }
        for symbol in symbols {
            guard kind(of: symbol) == "swift.init", let precise = precise(of: symbol),
                  let owner = memberOf[precise], api.structures[owner] != nil else { continue }
            let taken = parameters(of: symbol).map { (name: $0.label ?? $0.name, type: $0.type) }
            // The widest initializer, which is the memberwise one when there
            // is one: a convenience `init()` would flatten the value to
            // nothing and quietly lose its contents.
            if taken.count > (api.structures[owner]?.fields.count ?? 0) {
                api.structures[owner]?.fields = taken
            }
        }

        // Classes next, so members have somewhere to go.
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
                isActor: modifiers.contains("actor"),
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
                    isOverridable: (symbol["accessLevel"] as? String) == "open",
                    // `throws` shows up as a keyword fragment; the return type
                    // looks perfectly ordinary beside it, which is why a
                    // throwing method read as a plain one before this.
                    isAsync: fragments(of: symbol["declarationFragments"])
                        .contains { $0.kind == "keyword" && $0.spelling == "async" },
                    isThrowing: fragments(of: symbol["declarationFragments"])
                        .contains { $0.kind == "keyword" && $0.spelling == "throws" }
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
            case "swift.class", "swift.struct", "swift.protocol":
                continue
            case let other:
                api.skipped.append(Skip(member: path, reason: "\(other) has no BASIC counterpart yet"))
            }
        }
        // A struct is only importable if it flattens to scalars, and that
        // cannot be known while the structs are still being read — so the
        // members that name an unflattenable one are withdrawn here, with a
        // reason, rather than reaching the shim and failing to compile.
        // A method on an actor is awaited, whatever its own declaration says.
        for index in api.classes.indices where api.classes[index].isActor {
            api.classes[index].methods = api.classes[index].methods.map {
                var method = $0
                method.isAsync = true
                return method
            }
        }
        for index in api.classes.indices {
            let klass = api.classes[index]
            // A property whose type is a protocol or a struct comes back as
            // an existential or a value, neither of which crosses as the
            // pointer a property accessor is emitted to return. Declaring one
            // put a type in the generated unit that nothing declares.
            api.classes[index].properties = klass.properties.filter { property in
                switch property.type {
                case .protocolType(let precise):
                    api.skipped.append(Skip(member: "\(klass.name).\(property.name)",
                                            reason: "it is \(api.protocols[precise] ?? precise), a protocol; a property of one does not cross yet"))
                    return false
                case .structure(let precise):
                    api.skipped.append(Skip(member: "\(klass.name).\(property.name)",
                                            reason: "it is \(api.structures[precise]?.name ?? precise), a struct; a struct crosses as arguments, not as a value"))
                    return false
                default:
                    return true
                }
            }
            api.classes[index].methods = klass.methods.filter { method in
                if let bad = api.unflattenable(in: method) {
                    api.skipped.append(Skip(member: "\(klass.name).\(method.name)", reason: bad))
                    return false
                }
                return true
            }
            api.classes[index].initializers = klass.initializers.filter { initializer in
                if let bad = api.unflattenable(in: initializer) {
                    api.skipped.append(Skip(member: "\(klass.name).init", reason: bad))
                    return false
                }
                return true
            }
        }
        return api
    }

    /// Withdraws every member whose symbol the framework does not export.
    ///
    /// The graph describes the API; the binary decides what can be called.
    /// A property the graph presents as a `var` may have no public setter —
    /// an actor's properties are read-only from outside, and a computed one
    /// may never have had one — and a symbol that is not there is a link
    /// error at the end of somebody else's build rather than a diagnostic
    /// here. With `exported` empty, nothing is withdrawn: an unavailable
    /// symbol table must not look like an empty framework.
    public mutating func keepOnly(exported: Set<String>) {
        guard !exported.isEmpty else { return }
        func has(_ symbol: String) -> Bool { exported.contains(String(symbol.dropFirst(2))) || exported.contains(symbol) }

        // A class whose *metadata* is not exported cannot be constructed or
        // recognised at run time. A generic class is the usual reason —
        // `Ref<Value>` has a metadata accessor rather than one fixed symbol —
        // and emitting a reference to metadata that does not exist is a link
        // error rather than anything a program could have done differently.
        let withdrawn = Set(classes.filter { !has($0.symbol + "N") }.map(\.precise))
        if !withdrawn.isEmpty {
            for klass in classes where withdrawn.contains(klass.precise) {
                skipped.append(Skip(member: klass.name, reason: "the framework exports no type metadata for it; a generic class has none to export"))
            }
            classes.removeAll { withdrawn.contains($0.precise) }
            // And anything that names one of them: its type has gone.
            for index in classes.indices {
                let klass = classes[index]
                func mentions(_ function: Function) -> Bool {
                    if case .object(let precise) = function.returns, withdrawn.contains(precise) { return true }
                    return function.passed.contains {
                        if case .object(let precise) = $0.type { return withdrawn.contains(precise) }
                        return false
                    }
                }
                classes[index].methods = klass.methods.filter { !mentions($0) }
                classes[index].initializers = klass.initializers.filter { !mentions($0) }
                classes[index].properties = klass.properties.filter {
                    if case .object(let precise) = $0.type { return !withdrawn.contains(precise) }
                    return true
                }
            }
        }
        for index in classes.indices {
            let klass = classes[index]
            classes[index].methods = klass.methods.filter { method in
                guard has(method.symbol) else {
                    skipped.append(Skip(member: "\(klass.name).\(method.name)",
                                        reason: "the framework does not export it"))
                    return false
                }
                return true
            }
            classes[index].initializers = klass.initializers.filter { has($0.allocatingSymbol) }
            classes[index].properties = klass.properties.compactMap { property in
                guard has(property.getterSymbol) else {
                    skipped.append(Skip(member: "\(klass.name).\(property.name)",
                                        reason: "the framework exports no getter for it"))
                    return nil
                }
                guard property.isSettable, !has(property.setterSymbol) else { return property }
                // Readable but not writable — which is the truth for an
                // actor's property, and for any computed one without a setter.
                return Property(name: property.name, symbol: property.symbol,
                                type: property.type, isSettable: false)
            }
        }
    }

    /// Why a member cannot cross, when a struct in its signature does not
    /// flatten to scalars.
    func unflattenable(in function: Function) -> String? {
        for parameter in function.passed {
            // A struct or protocol this graph does not describe belongs to
            // another module, so nothing here can name it — and it must not
            // be spelled as a placeholder, which lands in generated Swift as
            // `Never` and fails to compile.
            if case .protocolType(let precise) = parameter.type, protocols[precise] == nil {
                return "\(parameter.name) is a protocol from another module (\(precise))"
            }
            if case .structure(let precise) = parameter.type, structures[precise] == nil {
                return "\(parameter.name) is a struct from another module (\(precise))"
            }
        }
        // Only what BASIC actually passes: a defaulted parameter it cannot
        // spell is left to Swift, so its shape is none of our business.
        for parameter in function.passed {
            guard case .structure(let precise) = parameter.type else { continue }
            if leaves(of: parameter.type) == nil {
                let name = structures[precise]?.name ?? precise
                return "\(parameter.name) is \(name), a struct that does not flatten to numbers, booleans or strings"
            }
        }
        if case .structure(let precise) = function.returns {
            return "it returns \(structures[precise]?.name ?? precise); a struct comes back as one value and BASIC has no name for it yet"
        }
        return nil
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

    /// Which parameters the declaration gives defaults to.
    ///
    /// Read from the declaration text, because the per-parameter fragments do
    /// not carry it. Split paren-aware: a default may itself be a call, and
    /// `Size(width: 80, height: 24)` contains the comma this would otherwise
    /// split on.
    static func defaulted(in symbol: [String: Any]) -> [Bool] {
        let declaration = fragments(of: symbol["declarationFragments"]).map(\.spelling).joined()
        guard let open = declaration.firstIndex(of: "("), let close = declaration.lastIndex(of: ")"), open < close else { return [] }
        let inside = declaration[declaration.index(after: open)..<close]
        var parts: [String] = []
        var depth = 0
        var current = ""
        for character in inside {
            if character == "(" || character == "[" { depth += 1 }
            if character == ")" || character == "]" { depth -= 1 }
            if character == ",", depth == 0 { parts.append(current); current = ""; continue }
            current.append(character)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts.map { $0.contains(" = ") }
    }

    static func parameters(of symbol: [String: Any]) -> [Parameter] {
        let signature = symbol["functionSignature"] as? [String: Any]
        let titleLabels = labels(of: symbol)
        let defaults = defaulted(in: symbol)
        return ((signature?["parameters"] as? [[String: Any]]) ?? []).enumerated().map { position, parameter in
            let fragments = fragments(of: parameter["declarationFragments"])
            // Everything after the `: ` is the type, and it counts only when
            // it is exactly one type identifier. Taking the first identifier
            // and ignoring what surrounds it made `[Shape]` import as
            // `Shape` — a parameter that would take the array's element.
            let afterColon = fragments.drop { !$0.spelling.contains(":") }.dropFirst()
            // The declared type as written, which is the only way to tell a
            // *function* type apart: its single `typeIdentifier` is the
            // result, so `() -> Void` looks exactly like `Void` if you read
            // the identifiers and ignore the punctuation between them.
            let written = fragments.drop { $0.kind == "identifier" }
                .map(\.spelling).joined()
                .drop { $0 == ":" || $0 == " " }
            let type: ValueType
            // Attributes are noise for this question: `@escaping`,
            // `@MainActor` and `@Sendable` describe *how* a handler is used,
            // not what shape it is. Matching only the bare spelling skipped
            // every handler a UI framework declares, which is most of them.
            var shape = String(written)
            for attribute in ["@escaping ", "@MainActor ", "@Sendable ", "@autoclosure "] {
                shape = shape.replacingOccurrences(of: attribute, with: "")
            }
            if shape == "() -> Void" {
                type = .voidClosure
            } else if let array = Self.arrayType(fragments) {
                type = array
            } else if afterColon.count == 1, let only = afterColon.first, only.kind == "typeIdentifier" {
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
            return Parameter(label: label, name: internalName, type: type,
                             hasDefault: defaults.indices.contains(position) ? defaults[position] : false)
        }
    }
    static func returnType(of symbol: [String: Any]) -> ValueType {
        let signature = symbol["functionSignature"] as? [String: Any]
        let fragments = fragments(of: signature?["returns"])
        if fragments.isEmpty || fragments.map(\.spelling).joined() == "()" { return .void }
        // A bare type identifier is the whole return type; anything wrapped
        // (`[Shape]`, `Shape?`) is more than one fragment and unsupported.
        if let array = arrayType(fragments) { return array }
        guard fragments.count == 1, let only = fragments.first, only.kind == "typeIdentifier" else {
            return .unsupported(fragments.map(\.spelling).joined())
        }
        return valueType(precise: only.precise, spelling: only.spelling)
    }
    /// `[T]` read from the fragments of a declared type, or nil when the
    /// fragments are not exactly a bracketed type identifier.
    ///
    /// A symbol graph spells an array as three fragments — `[`, the element,
    /// `]` — and there is no `precise` for the array itself, so this is the
    /// only place its shape is visible.
    static func arrayType(_ fragments: [Fragment]) -> ValueType? {
        // Matched on the *text*, not on fragment positions. A parameter's
        // brackets do not get a fragment of their own — the graph writes
        // `labels` then `: [` then `String` then `]`, so the opening bracket
        // rides along with the colon and any rule counting fragments misses
        // every array parameter while matching every array return.
        let identifiers = fragments.filter { $0.kind == "typeIdentifier" }
        guard identifiers.count == 1 else { return nil }
        let joined = fragments.map(\.spelling).joined().replacingOccurrences(of: " ", with: "")
        let written = joined.firstIndex(of: ":").map { String(joined[joined.index(after: $0)...]) } ?? joined
        guard written == "[\(identifiers[0].spelling)]" else { return nil }
        let element = valueType(precise: identifiers[0].precise, spelling: identifiers[0].spelling)
        // An array of something BASIC cannot spell is not an array BASIC can
        // spell. Nested arrays stop here too: a BASIC array of arrays is a
        // rank-2 array, which is a different thing.
        switch element {
        case .double, .int, .bool, .string: return .array(element: element)
        // Deliberately not `[SomeClass]`. A BASIC array holds the runtime's
        // own records, and an imported object is the framework's — the two
        // are not the same thing, and a program that stored one in the other
        // used to build and then die on the first read. Refused here so the
        // member is reported with a reason instead.
        default: return nil
        }
    }

    static func valueType(precise: String?, spelling: String) -> ValueType {
        switch precise {
        case "s:Sd": return .double
        case "s:Si": return .int
        case "s:Sb": return .bool
        case "s:SS": return .string
        case let precise? where precise.hasSuffix("C"): return .object(precise: precise)
        // `V` is a struct. Whether it can actually cross is decided later, by
        // whether it flattens to scalars — this only says what it is.
        case let precise? where precise.hasSuffix("V"): return .structure(precise: precise)
        case let precise? where precise.hasSuffix("P"): return .protocolType(precise: precise)
        default: return .unsupported(spelling)
        }
    }
}
