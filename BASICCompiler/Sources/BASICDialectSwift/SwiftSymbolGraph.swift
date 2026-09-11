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
        /// A plain enum — every case bare, none with a payload (E2). BASIC sees
        /// the `ENUM` the interface unit declares for it; the value crosses as
        /// its ordinal and a shim turns that into the case, so how Swift lays
        /// the enum out is never assumed.
        case enumeration(precise: String)
        /// An enum whose cases carry numbers, strings or booleans (E4). BASIC
        /// sees the payload `ENUM` E3 built; a value crosses as the runtime's
        /// record, converted case by case in the shim.
        case payloadEnumeration(precise: String)
        /// `Swift.Duration`, as a BASIC number of milliseconds - the unit
        /// this BASIC's `SLEEP` takes, so `A.schedule(50, ...)` reads like
        /// `SLEEP 50`. Converted in the shim both ways (R5.1).
        case duration
        /// Nothing.
        case void
        /// Something BASIC has no spelling for yet — the spelling is kept for
        /// the report.
        case unsupported(String)

        var isSupported: Bool {
            if case .unsupported = self { return false }
            return true
        }

        /// Either kind of imported enum.
        var isEnumeration: Bool {
            switch self {
            case .enumeration, .payloadEnumeration: return true
            default: return false
            }
        }
    }

    /// One parameter of a method or initializer.
    public struct Parameter: Sendable, Equatable {
        /// The argument label, or nil for `_`.
        public let label: String?
        /// The internal name, which is what BASIC calls the parameter.
        public let name: String
        public var type: ValueType
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
        public var parameters: [Parameter]
        public var returns: ValueType
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
        public var type: ValueType
        public let isSettable: Bool

        public var getterSymbol: String { String(symbol.dropLast(2)) + "vg" }
        public var setterSymbol: String { String(symbol.dropLast(2)) + "vs" }
    }

    /// A struct, and the scalars it flattens to.
    /// A plain Swift enum, as BASIC will know it (E2).
    public struct Enumeration: Sendable, Equatable {
        /// The BASIC spelling. A nested enum's dots become underscores —
        /// `Button.Style` is `Button_Style` — because a BASIC type name cannot
        /// contain one.
        public let name: String
        /// The Swift spelling, for the generated shim.
        public let swiftName: String
        public let precise: String
        /// Cases in declaration order; a case's ordinal is its position here.
        public let cases: [String]
        /// Each case's associated values, parallel to `cases` (E4); empty for
        /// a bare case, and empty throughout for a plain enum.
        public var payloads: [[PayloadField]] = []

        public var isPayload: Bool { payloads.contains { !$0.isEmpty } }

        /// Members declared on the enum (E5). BASIC calls them with a dot, as
        /// VB calls an enum's members: on a value for an instance member, on
        /// the type for a static one.
        public var instanceMethods: [Function] = []
        public var instanceProperties: [Property] = []
        public var staticMethods: [Function] = []
        public var staticProperties: [Property] = []

        /// The BASIC record's slots after the tag: each field name once, in the
        /// order the cases first mention them — the rule E3's compiler uses
        /// for the ENUM this renders as, so the two lay the record out alike.
        public var slots: [PayloadField] {
            var seen = Set<String>()
            var out: [PayloadField] = []
            for fields in payloads {
                for field in fields where seen.insert(field.name.uppercased()).inserted { out.append(field) }
            }
            return out
        }

        /// A field's slot in the record; the tag is slot 0.
        public func slotIndex(of field: String) -> Int? {
            slots.firstIndex { $0.name.uppercased() == field.uppercased() }.map { $0 + 1 }
        }
    }

    /// One associated value of an imported enum case (E4).
    public struct PayloadField: Sendable, Equatable {
        /// The BASIC field name: the Swift label, or `Value` (`Value1`,
        /// `Value2`… when there are several) for an unlabeled one — BASIC has
        /// no positional fields.
        public let name: String
        /// The Swift argument label, when the case declares one.
        public let label: String?
        public let type: ValueType
    }

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
    /// Plain enums, by precise identifier (E2).
    public var enumerations: [String: Enumeration] = [:]
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
            // Numbers, booleans and strings only — the rule this was always
            // documented as. "Supported" is the wrong test: a leaf crosses as
            // one `@_cdecl` parameter, and an enum, an object, a protocol or
            // a closure cannot be one. While enums were unsupported that
            // difference hid; making them importable (E2) turned structs with
            // an enum field into "flattenable" ones, and their shims stopped
            // compiling.
            switch type {
            case .double, .int, .bool, .string: return [type]
            default: return nil
            }
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

        // Plain enums (E2), before any member: a member's type may name one,
        // and whether it can cross depends on which enums made it in. Cases
        // are ordered by where they are written — the symbol list is in no
        // promised order, and the ordinal BASIC sees must be the case order.
        var enumSkipReasons: [String: String] = [:]
        var casesByEnum: [String: [(order: String, line: Int, column: Int, offset: Int, name: String, payload: Bool, fields: [PayloadField]?)]] = [:]
        for (offset, symbol) in symbols.enumerated() {
            // The last path component, not the title: a case's title is
            // qualified (`Tint.red`), and a qualified name backticked in the
            // shim is a case that does not exist.
            guard kind(of: symbol) == "swift.enum.case", let precise = precise(of: symbol),
                  let owner = memberOf[precise],
                  let component = (symbol["pathComponents"] as? [String])?.last else { continue }
            // A case that carries values is named with its labels in the path
            // — `inline(rows:)`, `fixed(_:)` — and the case's name is the part
            // before them (E4). A bare case has none to strip.
            let name = String(component.prefix { $0 != "(" })
            let location = symbol["location"] as? [String: Any]
            let spot = location?["position"] as? [String: Any]
            let declared = fragments(of: symbol["declarationFragments"]).map(\.spelling).joined()
            casesByEnum[owner, default: []].append((
                order: location?["uri"] as? String ?? "", line: spot?["line"] as? Int ?? Int.max,
                column: spot?["character"] as? Int ?? 0, offset: offset,
                name: name, payload: declared.contains("("), fields: payloadFields(of: symbol)
            ))
        }
        for symbol in symbols {
            guard kind(of: symbol) == "swift.enum", let precise = precise(of: symbol),
                  let path = symbol["pathComponents"] as? [String], !path.isEmpty else { continue }
            let cases = (casesByEnum[precise] ?? []).sorted {
                ($0.order, $0.line, $0.column, $0.offset) < ($1.order, $1.line, $1.column, $1.offset)
            }
            let declared = fragments(of: symbol["declarationFragments"]).map(\.spelling).joined()
            if cases.isEmpty {
                enumSkipReasons[precise] = "it has no cases, so there is nothing to name"
            } else if cases.contains(where: { $0.fields == nil }) {
                enumSkipReasons[precise] = "a case carries something other than numbers, strings and booleans, which is all a BASIC ENUM field holds (E4)"
            } else if let clash = payloadClash(cases.map { $0.fields ?? [] }) {
                enumSkipReasons[precise] = clash
            } else if declared.contains("<") {
                enumSkipReasons[precise] = "it is generic, and a BASIC ENUM is not"
            } else if Set(cases.map { $0.name.uppercased() }).count != cases.count {
                enumSkipReasons[precise] = "two of its cases differ only in case, which BASIC cannot tell apart; KNOWN AS would, and is not built"
            } else {
                api.enumerations[precise] = Enumeration(
                    name: path.joined(separator: "_"), swiftName: path.joined(separator: "."),
                    precise: precise, cases: cases.map(\.name),
                    payloads: cases.map { $0.fields ?? [] }
                )
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
            case "swift.method", "swift.init", "swift.func", "swift.type.method":
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
                let isStatic = kind(of: symbol) == "swift.type.method"
                if let owner = memberOf[precise], api.enumerations[owner] != nil, !isInit {
                    // A member of an imported enum (E5).
                    if isStatic { api.enumerations[owner]!.staticMethods.append(function) }
                    else { api.enumerations[owner]!.instanceMethods.append(function) }
                } else if isStatic {
                    api.skipped.append(Skip(member: path, reason: "a static member of something other than an enum; BASIC reaches statics on enums only, for now"))
                } else if let owner = memberOf[precise], let index = classIndex[owner] {
                    if isInit { api.classes[index].initializers.append(function) } else { api.classes[index].methods.append(function) }
                } else if kind(of: symbol) == "swift.func" {
                    api.functions.append(function)
                } else {
                    api.skipped.append(Skip(member: path, reason: "member of something that is not a class"))
                }
            case "swift.property", "swift.type.property":
                let fragments = fragments(of: symbol["declarationFragments"])
                var type = leadingTypeIdentifier(fragments).map { valueType(precise: $0.precise, spelling: $0.spelling) } ?? .unsupported("?")
                // An optional enum has one value no BASIC member names — nil —
                // and the shim cannot hand that back as an ordinal. Refused by
                // name rather than generating a shim that does not compile.
                if case .enumeration = type, isOptional(afterLeadingTypeIn: fragments) {
                    type = .unsupported("an optional enum, whose nil no member names")
                }
                // `[Track]` leads with `Track`, which is the array's element and
                // not its type. E4 made such an enum importable, and the shim
                // then type-checked a Track against a [Track]; refused by name.
                if case .enumeration = type, isWrapped(aroundLeadingTypeIn: fragments) {
                    type = .unsupported("a collection of an enum")
                }
                // A Duration crosses as an argument or a result, through the
                // shim; a property accessor hands back the struct itself.
                if type == .duration { type = .unsupported("a Duration property, which crosses as an argument or result only") }
                let isLet = fragments.contains { $0.kind == "keyword" && $0.spelling == "let" }
                // `{ get }` in the declaration marks a read-only computed
                // property; a stored `var` shows no accessor block.
                let readOnly = isLet || fragments.contains { $0.spelling.contains("{ get }") }
                let isStaticProperty = kind(of: symbol) == "swift.type.property"
                if let owner = memberOf[precise], api.enumerations[owner] != nil {
                    guard type.isSupported else {
                        if case .unsupported(let s) = type { api.skipped.append(Skip(member: path, reason: "no BASIC spelling for \(s)")) }
                        continue
                    }
                    // Read-only from BASIC (E5): an enum's properties are
                    // computed, and a value of it is not a place to store into.
                    let member = Property(name: name, symbol: "$s" + precise.dropFirst(2), type: type, isSettable: false)
                    if isStaticProperty { api.enumerations[owner]!.staticProperties.append(member) }
                    else { api.enumerations[owner]!.instanceProperties.append(member) }
                    continue
                }
                if isStaticProperty {
                    api.skipped.append(Skip(member: path, reason: "a static member of something other than an enum; BASIC reaches statics on enums only, for now"))
                    continue
                }
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
            case "swift.enum":
                if api.enumerations[precise] != nil { continue }
                api.skipped.append(Skip(member: path, reason: enumSkipReasons[precise] ?? "an enum BASIC cannot spell yet"))
            case "swift.enum.case":
                if let owner = memberOf[precise], api.enumerations[owner] != nil { continue }
                api.skipped.append(Skip(member: path, reason: "a case of an enum that did not import; that enum says why"))
            case let other:
                api.skipped.append(Skip(member: path, reason: "\(other) has no BASIC counterpart yet"))
            }
        }
        // An enum whose BASIC name is already taken once case is folded — by
        // a class, or by another enum — would make `DIM x AS Mode` mean two
        // things. Withdrawn by name rather than letting one silently win.
        let classNames = Set(api.classes.map { $0.name.uppercased() })
        var takenEnumNames = Set<String>()
        for (precise, enumeration) in api.enumerations.sorted(by: { $0.value.name < $1.value.name }) {
            let folded = enumeration.name.uppercased()
            if classNames.contains(folded) || !takenEnumNames.insert(folded).inserted {
                api.enumerations[precise] = nil
                api.skipped.append(Skip(member: enumeration.swiftName,
                                        reason: "its BASIC name \(enumeration.name) is already taken"))
            }
        }
        // A reference to an enum that did not import is not a type BASIC can
        // spell. Rewritten here, before anything reads `passed`, so that a
        // *defaulted* parameter of such a type is left out — as it was before
        // E2 — instead of dragging its whole member out with it.
        func settle(_ type: ValueType) -> ValueType {
            guard case .enumeration(let precise) = type else { return type }
            guard let enumeration = api.enumerations[precise] else { return .unsupported(precise) }
            // One whose cases carry values crosses as a record, not an ordinal.
            return enumeration.isPayload ? .payloadEnumeration(precise: precise) : type
        }
        func settle(_ function: Function) -> Function {
            var function = function
            function.parameters = function.parameters.map { var parameter = $0; parameter.type = settle(parameter.type); return parameter }
            function.returns = settle(function.returns)
            return function
        }
        var enumWithdrawals: [Skip] = []
        func keep(_ function: Function, owner: String) -> Bool {
            guard !function.isSupported else { return true }
            enumWithdrawals.append(Skip(member: "\(owner).\(function.name)", reason: "it names an enum that did not import"))
            return false
        }
        for index in api.classes.indices {
            let klass = api.classes[index]
            let methods = klass.methods.map(settle).filter { keep($0, owner: klass.name) }
            let initializers = klass.initializers.map(settle).filter { keep($0, owner: klass.name) }
            let properties = klass.properties.compactMap { original -> Property? in
                var property = original
                property.type = settle(property.type)
                guard property.type.isSupported else {
                    enumWithdrawals.append(Skip(member: "\(klass.name).\(property.name)", reason: "it names an enum that did not import"))
                    return nil
                }
                // An actor's property is read with `await` from outside and
                // not written from there at all.
                if klass.isActor, property.type.isEnumeration, property.isSettable {
                    return Property(name: property.name, symbol: property.symbol, type: property.type, isSettable: false)
                }
                return property
            }
            api.classes[index].methods = methods
            api.classes[index].initializers = initializers
            api.classes[index].properties = properties
        }
        // Enum members settle the same way, and cross only what the shim can
        // carry for them: numbers, strings, booleans, enums and objects (E5).
        func crossesForEnum(_ type: ValueType) -> Bool {
            switch type {
            case .double, .int, .bool, .string, .void, .object, .enumeration, .payloadEnumeration: return true
            default: return false
            }
        }
        for precise in api.enumerations.keys.sorted() {
            guard var enumeration = api.enumerations[precise] else { continue }
            let owner = enumeration.name
            func keepMember(_ function: Function) -> Bool {
                guard keep(function, owner: owner) else { return false }
                guard crossesForEnum(function.returns), function.passed.allSatisfy({ crossesForEnum($0.type) }) else {
                    enumWithdrawals.append(Skip(member: "\(owner).\(function.name)",
                                                reason: "a member of an enum crosses numbers, strings, booleans, enums and objects for now"))
                    return false
                }
                return true
            }
            func settleProperties(_ list: [Property]) -> [Property] {
                list.compactMap { original in
                    var property = original
                    property.type = settle(property.type)
                    guard property.type.isSupported, crossesForEnum(property.type) else {
                        enumWithdrawals.append(Skip(member: "\(owner).\(property.name)",
                                                    reason: "a member of an enum crosses numbers, strings, booleans, enums and objects for now"))
                        return nil
                    }
                    return property
                }
            }
            enumeration.instanceMethods = enumeration.instanceMethods.map(settle).filter(keepMember)
            enumeration.staticMethods = enumeration.staticMethods.map(settle).filter(keepMember)
            enumeration.instanceProperties = settleProperties(enumeration.instanceProperties)
            enumeration.staticProperties = settleProperties(enumeration.staticProperties)
            api.enumerations[precise] = enumeration
        }
        let functions = api.functions.map(settle).filter { keep($0, owner: api.module) }
        api.functions = functions
        api.skipped += enumWithdrawals

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
            } else if let qualified = Self.qualifiedType(Array(afterColon)) {
                type = qualified
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
        if let qualified = qualifiedType(fragments) { return qualified }
        guard fragments.count == 1, let only = fragments.first, only.kind == "typeIdentifier" else {
            return .unsupported(fragments.map(\.spelling).joined())
        }
        return valueType(precise: only.precise, spelling: only.spelling)
    }
    /// A type written as a qualified path to a nested type — `Button.Style`,
    /// which the graph spells as identifiers with a dot between — resolved to
    /// the type the whole path means, or nil when the fragments are anything
    /// else. The *last* identifier's precise is that type; reading the first
    /// took `Button.Style` for `Button`, and a nested enum for its class.
    static func qualifiedType(_ fragments: [Fragment]) -> ValueType? {
        let meaningful = fragments.filter { !$0.spelling.trimmingCharacters(in: .whitespaces).isEmpty }
        guard meaningful.count >= 3, meaningful.count % 2 == 1 else { return nil }
        for (index, fragment) in meaningful.enumerated() {
            if index % 2 == 0 {
                guard fragment.kind == "typeIdentifier" else { return nil }
            } else {
                guard fragment.spelling.trimmingCharacters(in: .whitespaces) == "." else { return nil }
            }
        }
        let last = meaningful[meaningful.count - 1]
        return valueType(precise: last.precise, spelling: meaningful.map(\.spelling).joined())
    }

    /// The identifier a property's declared type starts with, following a
    /// qualified path to its end — `Button.Style` gives `Style`, whose
    /// precise is the nested type's.
    static func leadingTypeIdentifier(_ fragments: [Fragment]) -> Fragment? {
        guard var index = fragments.firstIndex(where: { $0.kind == "typeIdentifier" }) else { return nil }
        while index + 2 < fragments.count,
              fragments[index + 1].spelling.trimmingCharacters(in: .whitespaces) == ".",
              fragments[index + 2].kind == "typeIdentifier" {
            index += 2
        }
        return fragments[index]
    }

    /// An enum case's associated values as BASIC fields, or nil when any is
    /// not a plain number, string or boolean (E4). `case inline(rows: Int)`,
    /// `case fixed(Int)` and `case flexible(Int = 1)` all read; `Int?`,
    /// `[Int]` or a struct do not, and the enum is then skipped by name.
    static func payloadFields(of symbol: [String: Any]) -> [PayloadField]? {
        let all = fragments(of: symbol["declarationFragments"])
        guard let open = all.firstIndex(where: { $0.spelling.contains("(") }) else { return [] }
        let inside = Array(all[open...])
        let text = inside.map(\.spelling).joined()
        guard let start = text.firstIndex(of: "("), let end = text.lastIndex(of: ")"), start < end else { return nil }
        var parts: [String] = []
        var depth = 0
        var current = ""
        for character in text[text.index(after: start)..<end] {
            if "([<".contains(character) { depth += 1 }
            if ")]>".contains(character) { depth -= 1 }
            if character == ",", depth == 0 { parts.append(current); current = ""; continue }
            current.append(character)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        let identifiers = inside.filter { $0.kind == "typeIdentifier" }
        guard !parts.isEmpty, identifiers.count == parts.count else { return nil }
        var out: [PayloadField] = []
        for (index, (part, identifier)) in zip(parts, identifiers).enumerated() {
            let value = valueType(precise: identifier.precise, spelling: identifier.spelling)
            switch value {
            case .double, .int, .bool, .string: break
            default: return nil
            }
            let declared = part.components(separatedBy: "=")[0]
            let pieces = declared.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            // Exactly the type's own name: `Int?` and `[Int]` are other types.
            guard pieces.last == identifier.spelling else { return nil }
            let label = pieces.count == 2 ? pieces[0] : nil
            if let label, label.first?.isLetter != true { return nil }
            out.append(PayloadField(name: label ?? (parts.count == 1 ? "Value" : "Value\(index + 1)"), label: label, type: value))
        }
        return out
    }

    /// Why an imported enum's fields cannot share the one record BASIC lays
    /// out for it, or nil: a field name two cases use with two kinds (E4) —
    /// the rule E3 applies to an ENUM written in BASIC.
    static func payloadClash(_ payloads: [[PayloadField]]) -> String? {
        var seen: [String: String] = [:]
        for fields in payloads {
            for field in fields {
                let kind: String
                switch field.type {
                case .string: kind = "a string"
                case .bool: kind = "a boolean"
                default: kind = "a number"
                }
                let key = field.name.uppercased()
                if let earlier = seen[key], earlier != kind {
                    return "its field \(field.name) is \(earlier) in one case and \(kind) in another, and a BASIC ENUM field has one type"
                }
                seen[key] = kind
            }
        }
        return nil
    }

    /// Whether the declared type wraps its leading identifier — `[T]`,
    /// `[K: T]`, `Set<T>` — rather than being it.
    static func isWrapped(aroundLeadingTypeIn fragments: [Fragment]) -> Bool {
        guard var index = fragments.firstIndex(where: { $0.kind == "typeIdentifier" }) else { return false }
        if index > 0, fragments[index - 1].spelling.contains("[") || fragments[index - 1].spelling.contains("<") { return true }
        while index + 2 < fragments.count,
              fragments[index + 1].spelling.trimmingCharacters(in: .whitespaces) == ".",
              fragments[index + 2].kind == "typeIdentifier" {
            index += 2
        }
        guard index + 1 < fragments.count else { return false }
        let next = fragments[index + 1].spelling.trimmingCharacters(in: .whitespaces)
        return next.hasPrefix("]") || next.hasPrefix(">") || next.hasPrefix(":")
    }

    /// Whether the declared type ends in `?` or `!` — an Optional.
    static func isOptional(afterLeadingTypeIn fragments: [Fragment]) -> Bool {
        guard var index = fragments.firstIndex(where: { $0.kind == "typeIdentifier" }) else { return false }
        while index + 2 < fragments.count,
              fragments[index + 1].spelling.trimmingCharacters(in: .whitespaces) == ".",
              fragments[index + 2].kind == "typeIdentifier" {
            index += 2
        }
        guard index + 1 < fragments.count else { return false }
        let next = fragments[index + 1].spelling.trimmingCharacters(in: .whitespaces)
        return next.hasPrefix("?") || next.hasPrefix("!")
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
        case "s:s8DurationV": return .duration
        case let precise? where precise.hasSuffix("C"): return .object(precise: precise)
        // `V` is a struct. Whether it can actually cross is decided later, by
        // whether it flattens to scalars — this only says what it is.
        case let precise? where precise.hasSuffix("V"): return .structure(precise: precise)
        case let precise? where precise.hasSuffix("P"): return .protocolType(precise: precise)
        // `O` is an enum. Whether it imported is settled once the enums are
        // read; a reference to one that did not becomes unsupported then.
        case let precise? where precise.hasSuffix("O"): return .enumeration(precise: precise)
        default: return .unsupported(spelling)
        }
    }
}
