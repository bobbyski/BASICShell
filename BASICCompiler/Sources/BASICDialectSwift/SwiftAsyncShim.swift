import Foundation

/// Swift source that lets a compiled BASIC program call an imported `async`
/// method (R3.3).
///
/// ## Why this is generated Swift rather than emitted IR
///
/// Everything else `basicc` imports is called by its mangled symbol straight
/// from emitted IR, because an ordinary Swift function is an ordinary call.
/// An `async` function is not: its ABI is a context pointer and a
/// continuation, and reaching it means creating a task and resuming it — work
/// the Swift runtime does through code the compiler generates, not through a
/// call anyone can hand-write.
///
/// So for these, and only these, `basicc` writes a few lines of Swift and
/// compiles them against the framework. The shim starts a **real task**,
/// which really suspends, and waits for it — so the concurrency is Swift's,
/// and BASIC's side of the call blocks, which is what `AWAIT` already means
/// in the interpreter.
///
/// ## What it is not
///
/// It is not a bridge object, and it is not a reimplementation of anything.
/// Each shim is a `@_cdecl` wrapper of one method: unwrap the receiver, start
/// the task, wait, hand back the value.
public struct SwiftAsyncShim {
    /// One method that needs a shim.
    public struct Method: Sendable {
        /// The class the method is on.
        public let className: String
        /// The method's Swift name.
        public let name: String
        /// Its argument labels, in order, for the call.
        public let labels: [String?]
        /// The Swift spelling of each parameter type.
        public let parameterTypes: [String]
        /// The Swift spelling of the result, or nil for `Void`.
        public let returns: String?
        /// Whether it also throws.
        public let isThrowing: Bool
        /// Whether it is awaited, or merely takes a handler (R4.5).
        public var isAsync: Bool = true
        /// Whether this constructs the class rather than calling a method.
        ///
        /// A constructor needs a shim for the same reasons a method does — a
        /// protocol parameter is an existential, not a pointer, and calling
        /// one as though it were walks off the end of the value.
        public var isInitializer: Bool = false
        /// How many arguments BASIC passes, for the symbol's name.
        public var basicArity: Int = 0
        /// Which parameters are `() -> Void` handlers.
        public var closureParameters: Set<Int> = []
        /// Which parameters are class references, by the class's Swift name.
        ///
        /// A `@_cdecl` function cannot mention a Swift class that is not
        /// `@objc`, so these cross as pointers and are bridged here — the
        /// same way the receiver always has.
        public var objectParameters: [Int: String] = [:]
        /// The class this returns, when it returns one.
        public var objectResult: String?
        /// Protocol parameters, by position: the protocol's Swift name. The
        /// value arrives as an object pointer and is cast — BASIC's INTERFACE
        /// and Swift's protocol mean the same thing here, and the graph
        /// already says which classes conform.
        public var protocolParameters: [Int: String] = [:]
        /// Struct parameters, by position: the Swift spelling of each leaf
        /// the struct flattens to, and an expression that rebuilds it from
        /// them. The expression is nested where the struct is —
        /// `Rect(origin: Point(x: …, y: …), size: Size(width: …, height: …))`
        /// — because the memberwise initializer takes `origin:` and `size:`,
        /// not four numbers. BASIC passes the four (R4.4).
        public var structParameters: [Int: (leafTypes: [String], build: String)] = [:]
        /// Array parameters, by position, tagged with their element kind
        /// (`double`, `int`, `bool`, `string`). The value arrives as the
        /// runtime's boxed array and is read element by element through the
        /// bridge — the element type is known here, so nothing dynamic is
        /// being guessed at (R4.7).
        public var arrayParameters: [Int: String] = [:]
        /// The element kind this returns an array of, when it does. The
        /// result goes back as a BASIC array in a VARIANT, which is the shape
        /// BASIC already has for an array a function hands back.
        public var arrayResult: String?
        /// Plain-enum parameters, by position (E2): BASIC passes the ordinal
        /// and the shim turns it into the case, so nothing here depends on
        /// how Swift lays an enum out in memory.
        public var enumParameters: [Int: PlainEnum] = [:]
        /// The plain enum this returns, when it returns one.
        public var enumResult: PlainEnum?
        /// String parameters, by position. They cross as the runtime's own
        /// string pointer and become a `Swift.String` inside the shim: a
        /// `@_cdecl` function spells `Swift.String` as a bridged `NSString*`,
        /// one pointer, where emitted IR passes Swift's two words — so a
        /// String never appears in a shim's C signature at all.
        public var stringParameters: Set<Int> = []
        /// Whether the result is a String, handed back as an owned runtime
        /// string for the same reason.
        public var stringResult = false
        /// Parameters whose enum carries values, by position (E4): the
        /// runtime's record arrives and the shim reads it case by case.
        public var payloadParameters: [Int: PayloadEnum] = [:]
        /// The enum-with-values this returns, when it does; the shim builds
        /// the record, given its type index as a trailing argument.
        public var payloadResult: PayloadEnum?
        /// What the member is called on (E5): an object, as for every class
        /// member; an enum value, arriving as its ordinal or its record; or,
        /// for a static, the type itself, by its Swift name.
        public enum Receiver: Sendable { case object, plainEnum(PlainEnum), payloadEnum(PayloadEnum), type(String) }
        public var receiver: Receiver = .object
        /// Whether the member is a property, read without parentheses.
        public var isProperty = false

        public init(className: String, name: String, labels: [String?],
                    parameterTypes: [String], returns: String?, isThrowing: Bool) {
            self.className = className
            self.name = name
            self.labels = labels
            self.parameterTypes = parameterTypes
            self.returns = returns
            self.isThrowing = isThrowing
        }

        /// The C symbol the emitted IR calls.
        public var symbol: String {
            if isInitializer { return "basic_new_\(className)_\(basicArity)" }
            return (isAsync ? "basic_await_" : "basic_handler_") + "\(className)_\(name)"
        }
    }

    /// An enum whose cases carry numbers, strings or booleans (E4), as a
    /// shim sees it: each case's name and associated values, with the BASIC
    /// record slot each value lives in. Both directions of the conversion are
    /// generated from this one description, so they cannot disagree.
    public struct PayloadEnum: Sendable, Hashable {
        public struct Field: Sendable, Hashable {
            public let label: String?
            /// `Swift.Int`, `Swift.Double`, `Swift.String` or `Swift.Bool`.
            public let swiftType: String
            public let slot: Int
            public init(label: String?, swiftType: String, slot: Int) {
                self.label = label
                self.swiftType = swiftType
                self.slot = slot
            }
        }
        public struct Case: Sendable, Hashable {
            public let name: String
            public let fields: [Field]
            public init(name: String, fields: [Field]) {
                self.name = name
                self.fields = fields
            }
        }
        public let swiftName: String
        public let cases: [Case]
        public init(swiftName: String, cases: [Case]) {
            self.swiftName = swiftName
            self.cases = cases
        }
        var stem: String { swiftName.replacingOccurrences(of: ".", with: "_") }
    }

    /// A property whose enum carries values (E4).
    public struct PayloadProperty: Sendable {
        public let className: String
        public let name: String
        public let type: PayloadEnum
        public let isSettable: Bool
        public let isActor: Bool
        public init(className: String, name: String, type: PayloadEnum, isSettable: Bool, isActor: Bool) {
            self.className = className
            self.name = name
            self.type = type
            self.isSettable = isSettable
            self.isActor = isActor
        }
        public var getter: String { "basic_get_\(className)_\(name)" }
        public var setter: String { "basic_set_\(className)_\(name)" }
    }

    /// A plain Swift enum as a shim sees it (E2): its Swift spelling and its
    /// cases in order. The ordinal BASIC uses is the position in `cases`, and
    /// both directions of the conversion are generated from this one list, so
    /// they cannot disagree.
    public struct PlainEnum: Sendable, Hashable {
        public let swiftName: String
        public let cases: [String]
        public init(swiftName: String, cases: [String]) {
            self.swiftName = swiftName
            self.cases = cases
        }
        /// An identifier-safe stem for its conversion functions.
        var stem: String { swiftName.replacingOccurrences(of: ".", with: "_") }
    }

    /// An enum-typed property, read and written through the shim (E2).
    ///
    /// Swift's own accessor returns the enum in whatever layout Swift chose;
    /// going through a few lines of generated Swift is what makes that layout
    /// nobody's business, the same reason every other non-trivial value
    /// crosses here.
    public struct EnumProperty: Sendable {
        public let className: String
        public let name: String
        public let type: PlainEnum
        public let isSettable: Bool
        /// An actor's property is read with `await` from outside it.
        public let isActor: Bool
        public init(className: String, name: String, type: PlainEnum, isSettable: Bool, isActor: Bool) {
            self.className = className
            self.name = name
            self.type = type
            self.isSettable = isSettable
            self.isActor = isActor
        }
        public var getter: String { "basic_get_\(className)_\(name)" }
        public var setter: String { "basic_set_\(className)_\(name)" }
    }

    /// The module being imported.
    public let module: String
    /// Its async methods.
    public let methods: [Method]
    /// Its enum-typed properties (E2).
    public let properties: [EnumProperty]
    /// Its properties whose enum carries values (E4).
    public let payloadProperties: [PayloadProperty]

    public init(module: String, methods: [Method], properties: [EnumProperty] = [], payloadProperties: [PayloadProperty] = []) {
        self.module = module
        self.methods = methods
        self.properties = properties
        self.payloadProperties = payloadProperties
    }

    /// The Swift source, or nil when there is nothing to shim.
    public func source() -> String? {
        guard !methods.isEmpty || !properties.isEmpty || !payloadProperties.isEmpty else { return nil }
        var lines = [
            "// Generated by basicc so a BASIC program can await \(module)'s",
            "// async methods. Nothing here is hand-written; see SwiftAsyncShim.",
            "import Foundation",
            "import \(module)",
            "",
            "/// The runtime's error raiser, declared by symbol rather than",
            "/// imported: the shim compiles against the *framework*, and adding",
            "/// BASICRTSwift to its search path would tie a generated file to",
            "/// wherever the compiler happens to be installed.",
            "@_silgen_name(\"basic_rt_swift_error_raise\")",
            "private func basicAwaitRaise(_ error: Error) -> Never",
            "",
            "/// Strings cross as the runtime's own string pointer, never as a",
            "/// `Swift.String` in a C signature (see SwiftAsyncShim.Method).",
            "@_silgen_name(\"basic_rt_swift_string_in\")",
            "private func basicStringIn(_ p: UnsafeMutableRawPointer?) -> String",
            "@_silgen_name(\"basic_rt_swift_string_out\")",
            "private func basicStringOut(_ s: String) -> UnsafeMutableRawPointer",
            "",
            "/// Records of an enum whose cases carry values (E4): made, read and",
            "/// written through the runtime, which alone knows what a record is.",
            "@_silgen_name(\"basic_rt_swift_enum_make\")",
            "private func basicEnumMake(_ typeIndex: Int, _ tag: Int) -> UnsafeMutableRawPointer",
            "@_silgen_name(\"basic_rt_swift_enum_tag\")",
            "private func basicEnumTag(_ p: UnsafeMutableRawPointer?) -> Int",
            "@_silgen_name(\"basic_rt_swift_enum_number\")",
            "private func basicEnumNumber(_ p: UnsafeMutableRawPointer?, _ slot: Int) -> Double",
            "@_silgen_name(\"basic_rt_swift_enum_string\")",
            "private func basicEnumString(_ p: UnsafeMutableRawPointer?, _ slot: Int) -> String",
            "@_silgen_name(\"basic_rt_swift_enum_boolean\")",
            "private func basicEnumBoolean(_ p: UnsafeMutableRawPointer?, _ slot: Int) -> Bool",
            "@_silgen_name(\"basic_rt_swift_enum_set_number\")",
            "private func basicEnumSetNumber(_ p: UnsafeMutableRawPointer, _ slot: Int, _ v: Double)",
            "@_silgen_name(\"basic_rt_swift_enum_set_string\")",
            "private func basicEnumSetString(_ p: UnsafeMutableRawPointer, _ slot: Int, _ v: String)",
            "@_silgen_name(\"basic_rt_swift_enum_set_boolean\")",
            "private func basicEnumSetBoolean(_ p: UnsafeMutableRawPointer, _ slot: Int, _ v: Bool)",
            "",
            "/// The array side of the same boundary (R4.7). A `[T]` crosses as",
            "/// the runtime's own array carried in a VARIANT, so BASIC walks it",
            "/// with `LEN(v)` and `v(i)` and learns nothing new.",
            "@_silgen_name(\"basic_rt_swift_array_count\")",
            "private func basicArrayCount(_ p: UnsafeMutableRawPointer?) -> Int",
            "@_silgen_name(\"basic_rt_swift_array_number\")",
            "private func basicArrayNumber(_ p: UnsafeMutableRawPointer?, _ i: Int) -> Double",
            "@_silgen_name(\"basic_rt_swift_array_boolean\")",
            "private func basicArrayBoolean(_ p: UnsafeMutableRawPointer?, _ i: Int) -> Bool",
            "@_silgen_name(\"basic_rt_swift_array_string\")",
            "private func basicArrayString(_ p: UnsafeMutableRawPointer?, _ i: Int) -> String",
            "@_silgen_name(\"basic_rt_swift_array_out_numbers\")",
            "private func basicArrayOutNumbers(_ v: [Double]) -> UnsafeMutableRawPointer",
            "@_silgen_name(\"basic_rt_swift_array_out_booleans\")",
            "private func basicArrayOutBooleans(_ v: [Bool]) -> UnsafeMutableRawPointer",
            "@_silgen_name(\"basic_rt_swift_array_out_strings\")",
            "private func basicArrayOutStrings(_ v: [String]) -> UnsafeMutableRawPointer",
            "",
            "/// Carries a result out of the task that produced it.",
            "private final class BASICAwaitBox<Value>: @unchecked Sendable {",
            "    var value: Value?",
            "    var failure: Error?",
            "}",
            "",
            "/// Runs `body` as a real task and waits for it.",
            "///",
            "/// The suspension is Swift's — the task really suspends and really",
            "/// resumes. The waiting is BASIC's, which is what `AWAIT` means",
            "/// there: the statement does not finish until the value is in hand.",
            "private func basicAwait<Value>(_ body: @escaping @Sendable () async throws -> Value) throws -> Value {",
            "    let box = BASICAwaitBox<Value>()",
            "    let semaphore = DispatchSemaphore(value: 0)",
            "    Task.detached {",
            "        do { box.value = try await body() } catch { box.failure = error }",
            "        semaphore.signal()",
            "    }",
            "    semaphore.wait()",
            "    if let failure = box.failure { throw failure }",
            "    return box.value!",
            "}",
            "",
        ]
        // Plain enums (E2): one pair of conversions per enum, both generated
        // from the same ordered case list. Every case name is backticked, so
        // a case called `default` or `self` is still one.
        var enums: [PlainEnum] = []
        for method in methods {
            for type in method.enumParameters.values where !enums.contains(type) { enums.append(type) }
            if let type = method.enumResult, !enums.contains(type) { enums.append(type) }
            if case .plainEnum(let type) = method.receiver, !enums.contains(type) { enums.append(type) }
        }
        for property in properties where !enums.contains(property.type) { enums.append(property.type) }
        var payloadEnums: [PayloadEnum] = []
        for method in methods {
            for type in method.payloadParameters.values where !payloadEnums.contains(type) { payloadEnums.append(type) }
            if let type = method.payloadResult, !payloadEnums.contains(type) { payloadEnums.append(type) }
            if case .payloadEnum(let type) = method.receiver, !payloadEnums.contains(type) { payloadEnums.append(type) }
        }
        for property in payloadProperties where !payloadEnums.contains(property.type) { payloadEnums.append(property.type) }
        if !enums.isEmpty || !payloadEnums.isEmpty {
            lines += [
                "/// A number BASIC handed over that no case has. Raised as a BASIC",
                "/// error, so ON ERROR catches it like any other.",
                "private struct BASICEnumRange: Error, CustomStringConvertible {",
                "    let description: String",
                "}",
                "",
            ]
        }
        for type in enums.sorted(by: { $0.stem < $1.stem }) {
            lines.append("private func basicEnumIn_\(type.stem)(_ value: Int) -> \(type.swiftName) {")
            lines.append("    switch value {")
            for (ordinal, name) in type.cases.enumerated() {
                lines.append("    case \(ordinal): return .`\(name)`")
            }
            lines.append("    default: basicAwaitRaise(BASICEnumRange(description: \"\(type.swiftName) has no member \\(value)\"))")
            lines.append("    }")
            lines.append("}")
            lines.append("private func basicEnumOut_\(type.stem)(_ value: \(type.swiftName)) -> Int {")
            lines.append("    switch value {")
            for (ordinal, name) in type.cases.enumerated() {
                lines.append("    case .`\(name)`: return \(ordinal)")
            }
            lines.append("    }")
            lines.append("}")
            lines.append("")
        }
        // Enums whose cases carry values (E4): a record in, a case out, and
        // back. Every case name is backticked, as for a plain enum.
        for type in payloadEnums.sorted(by: { $0.stem < $1.stem }) {
            func read(_ field: PayloadEnum.Field) -> String {
                switch field.swiftType {
                case "Swift.Int": return "Swift.Int(basicEnumNumber(p, \(field.slot)))"
                case "Swift.Double": return "basicEnumNumber(p, \(field.slot))"
                case "Swift.String": return "basicEnumString(p, \(field.slot))"
                default: return "basicEnumBoolean(p, \(field.slot))"
                }
            }
            lines.append("private func basicPayloadIn_\(type.stem)(_ p: UnsafeMutableRawPointer?) -> \(type.swiftName) {")
            lines.append("    let tag = basicEnumTag(p)")
            lines.append("    switch tag {")
            for (ordinal, member) in type.cases.enumerated() {
                if member.fields.isEmpty {
                    lines.append("    case \(ordinal): return .`\(member.name)`")
                } else {
                    let arguments = member.fields.map { field in field.label.map { "\($0): \(read(field))" } ?? read(field) }
                    lines.append("    case \(ordinal): return .`\(member.name)`(\(arguments.joined(separator: ", ")))")
                }
            }
            lines.append("    default: basicAwaitRaise(BASICEnumRange(description: \"\(type.swiftName) has no member \\(tag)\"))")
            lines.append("    }")
            lines.append("}")
            lines.append("private func basicPayloadOut_\(type.stem)(_ value: \(type.swiftName), _ typeIndex: Int) -> UnsafeMutableRawPointer {")
            lines.append("    switch value {")
            for (ordinal, member) in type.cases.enumerated() {
                if member.fields.isEmpty {
                    lines.append("    case .`\(member.name)`: return basicEnumMake(typeIndex, \(ordinal))")
                    continue
                }
                lines.append("    case .`\(member.name)`(\(member.fields.indices.map { "let f\($0)" }.joined(separator: ", "))):")
                lines.append("        let made = basicEnumMake(typeIndex, \(ordinal))")
                for (position, field) in member.fields.enumerated() {
                    switch field.swiftType {
                    case "Swift.Int": lines.append("        basicEnumSetNumber(made, \(field.slot), Swift.Double(f\(position)))")
                    case "Swift.Double": lines.append("        basicEnumSetNumber(made, \(field.slot), f\(position))")
                    case "Swift.String": lines.append("        basicEnumSetString(made, \(field.slot), f\(position))")
                    default: lines.append("        basicEnumSetBoolean(made, \(field.slot), f\(position))")
                    }
                }
                lines.append("        return made")
            }
            lines.append("    }")
            lines.append("}")
            lines.append("")
        }
        for method in methods {
            // A handler parameter arrives as the pair BASIC can supply — a C
            // function pointer and the closure it should invoke — and becomes
            // an ordinary Swift closure right here, which is the whole point:
            // the framework stores a Swift closure, not a wrapper object.
            var parameters: [String]
            switch method.receiver {
            case _ where method.isInitializer: parameters = []
            case .object: parameters = ["_ me: UnsafeMutableRawPointer"]
            case .plainEnum: parameters = ["_ me: Int"]
            case .payloadEnum: parameters = ["_ me: UnsafeMutableRawPointer?"]
            case .type: parameters = []
            }
            var callArguments: [String] = []
            for (index, type) in method.parameterTypes.enumerated() {
                if method.closureParameters.contains(index) {
                    parameters.append("_ fn\(index): @convention(c) (UnsafeMutableRawPointer?) -> Void")
                    parameters.append("_ ctx\(index): UnsafeMutableRawPointer?")
                    callArguments.append("{ fn\(index)(ctx\(index)) }")
                } else if let structure = method.structParameters[index] {
                    // One BASIC argument per leaf, in declaration order —
                    // which is the order the memberwise initializers take
                    // them, so `Rect` is `x, y, w, h`.
                    for (leaf, spelling) in structure.leafTypes.enumerated() {
                        if spelling == "Swift.String" {
                            // Raw here, converted before the struct is built.
                            parameters.append("_ r\(index)_\(leaf): UnsafeMutableRawPointer?")
                        } else {
                            parameters.append("_ a\(index)_\(leaf): \(spelling)")
                        }
                    }
                    callArguments.append("s\(index)")
                } else if method.payloadParameters[index] != nil {
                    parameters.append("_ a\(index): UnsafeMutableRawPointer?")
                    callArguments.append("q\(index)")
                } else if method.enumParameters[index] != nil {
                    parameters.append("_ a\(index): Int")
                    callArguments.append("e\(index)")
                } else if method.arrayParameters[index] != nil {
                    parameters.append("_ a\(index): UnsafeMutableRawPointer?")
                    callArguments.append("v\(index)")
                } else if method.protocolParameters[index] != nil {
                    parameters.append("_ a\(index): UnsafeMutableRawPointer")
                    callArguments.append("p\(index)")
                } else if method.objectParameters[index] != nil {
                    parameters.append("_ a\(index): UnsafeMutableRawPointer")
                    // Bridged before the call, never inside the task's
                    // closure: capturing a raw pointer there is a concurrency
                    // error in Swift 6, and the object reference is what the
                    // call wants anyway.
                    callArguments.append("o\(index)")
                } else if method.stringParameters.contains(index) {
                    parameters.append("_ a\(index): UnsafeMutableRawPointer?")
                    callArguments.append("t\(index)")
                } else {
                    parameters.append("_ a\(index): \(type)")
                    callArguments.append("a\(index)")
                }
            }
            let labelled = zip(method.labels, callArguments.indices)
                .map { label, index in label.map { "\($0): \(callArguments[index])" } ?? callArguments[index] }
                .joined(separator: ", ")
            // The member itself: on the object or the enum value, or on the
            // type for a static (E5); a property takes no parentheses.
            let target: String
            if case .type(let swiftName) = method.receiver { target = swiftName } else { target = "object" }
            let invocation = method.isProperty ? "\(target).`\(method.name)`" : "\(target).\(method.name)(\(labelled))"
            // A class result crosses as a pointer too, unretained: an
            // imported object belongs to the framework, and BASIC holding one
            // aliases it rather than owning a copy (ruling D15).
            // The record's type index, which only the caller knows (E4).
            if method.payloadResult != nil { parameters.append("_ ti: Int") }
            let result: String
            if method.isInitializer || method.objectResult != nil || method.arrayResult != nil || method.stringResult
                || method.payloadResult != nil {
                result = " -> UnsafeMutableRawPointer"
            } else if method.enumResult != nil {
                // The ordinal, which BASIC reads as the ENUM member.
                result = " -> Int"
            } else {
                result = method.returns.map { " -> \($0)" } ?? ""
            }
            func handOut(_ expression: String) -> String {
                if let type = method.payloadResult {
                    return "basicPayloadOut_\(type.stem)(\(expression), ti)"
                }
                if let type = method.enumResult {
                    return "basicEnumOut_\(type.stem)(\(expression))"
                }
                if method.stringResult {
                    return "basicStringOut(\(expression))"
                }
                if method.objectResult != nil {
                    return "Unmanaged.passUnretained(\(expression)).toOpaque()"
                }
                switch method.arrayResult {
                case "double": return "basicArrayOutNumbers(\(expression))"
                // A Swift `Int` is a BASIC number, here as everywhere else.
                case "int": return "basicArrayOutNumbers(\(expression).map(Swift.Double.init))"
                case "bool": return "basicArrayOutBooleans(\(expression))"
                case "string": return "basicArrayOutStrings(\(expression))"
                default: return expression
                }
            }
            lines.append("@_cdecl(\"\(method.symbol)\")")
            lines.append("public func \(method.symbol)(\(parameters.joined(separator: ", ")))\(result) {")
            if !method.isInitializer {
                switch method.receiver {
                case .object: lines.append("    let object = Unmanaged<\(method.className)>.fromOpaque(me).takeUnretainedValue()")
                case .plainEnum(let type): lines.append("    let object = basicEnumIn_\(type.stem)(me)")
                case .payloadEnum(let type): lines.append("    let object = basicPayloadIn_\(type.stem)(me)")
                case .type: break
                }
            }
            for (index, className) in method.objectParameters.sorted(by: { $0.key < $1.key }) {
                lines.append("    let o\(index) = Unmanaged<\(className)>.fromOpaque(a\(index)).takeUnretainedValue()")
            }
            // Read out of the runtime's array before the call, for the same
            // reason an object parameter is bridged before it: what goes into
            // the framework is a Swift value, not a pointer some later closure
            // would have to capture.
            for (index, type) in method.enumParameters.sorted(by: { $0.key < $1.key }) {
                lines.append("    let e\(index) = basicEnumIn_\(type.stem)(a\(index))")
            }
            for (index, type) in method.payloadParameters.sorted(by: { $0.key < $1.key }) {
                lines.append("    let q\(index) = basicPayloadIn_\(type.stem)(a\(index))")
            }
            for index in method.stringParameters.sorted() {
                lines.append("    let t\(index) = basicStringIn(a\(index))")
            }
            for (index, structure) in method.structParameters.sorted(by: { $0.key < $1.key }) {
                for (leaf, spelling) in structure.leafTypes.enumerated() where spelling == "Swift.String" {
                    lines.append("    let a\(index)_\(leaf) = basicStringIn(r\(index)_\(leaf))")
                }
            }
            for (index, kind) in method.arrayParameters.sorted(by: { $0.key < $1.key }) {
                let read: String
                switch kind {
                case "int": read = "Swift.Int(basicArrayNumber(a\(index), $0))"
                case "bool": read = "basicArrayBoolean(a\(index), $0)"
                case "string": read = "basicArrayString(a\(index), $0)"
                default: read = "basicArrayNumber(a\(index), $0)"
                }
                lines.append("    let v\(index) = (0..<basicArrayCount(a\(index))).map { \(read) }")
            }
            for (index, name) in method.protocolParameters.sorted(by: { $0.key < $1.key }) {
                // `as!` rather than `as?`: the only way to reach here is a
                // BASIC variable of the matching INTERFACE type, which the
                // unit only lets conforming classes satisfy. A failure would
                // be a compiler bug, and trapping says so immediately.
                lines.append("    let p\(index) = Unmanaged<AnyObject>.fromOpaque(a\(index)).takeUnretainedValue() as! \(name)")
            }
            // Rebuild each struct from the leaves BASIC passed.
            for (index, structure) in method.structParameters.sorted(by: { $0.key < $1.key }) {
                lines.append("    let s\(index) = \(structure.build)")
            }
            if method.isAsync {
                let awaited = method.isThrowing
                    ? "try await \(invocation)"
                    : "await \(invocation)"
                lines.append("    do {")
                if method.returns == nil {
                    lines.append("        _ = try basicAwait { \(awaited) }")
                } else {
                    lines.append("        return \(handOut("try basicAwait { \(awaited) }"))")
                }
                lines.append("    } catch {")
                lines.append("        basicAwaitRaise(error)")
                lines.append("    }")
            } else if method.isThrowing {
                lines.append("    do {")
                let called = "try \(invocation)"
                lines.append(method.returns == nil ? "        _ = \(called)" : "        return \(handOut(called))")
                lines.append("    } catch {")
                lines.append("        basicAwaitRaise(error)")
                lines.append("    }")
            } else if method.isInitializer {
                // Retained: the object is new and BASIC holds the only
                // reference. An imported object is the framework's to manage
                // (D15), and there is no release path for one yet — so this
                // keeps it alive rather than handing back a corpse.
                lines.append("    let made = MainActor.assumeIsolated { \(method.className)(\(labelled)) }")
                lines.append("    return Unmanaged.passRetained(made).toOpaque()")
            } else {
                // **`MainActor.assumeIsolated`, and it is load-bearing.** A
                // UI framework's API is usually `@MainActor`-isolated, and a
                // `@_cdecl` entry point is nonisolated — so calling one from
                // the other is refused outright. A compiled BASIC program
                // runs its statements on the main thread, so the assertion is
                // true; stating it is what lets a main-actor framework be
                // imported at all. It traps rather than corrupts if a future
                // caller is ever elsewhere.
                let called = "\(invocation)"
                if method.returns == nil {
                    lines.append("    MainActor.assumeIsolated { \(called) }")
                } else if let type = method.payloadResult {
                    // Built inside the isolated closure and carried out as a
                    // bit pattern: assumeIsolated wants a Sendable result, and
                    // neither the enum nor a raw pointer is one.
                    lines.append("    let bits = MainActor.assumeIsolated { Int(bitPattern: basicPayloadOut_\(type.stem)(\(called), ti)) }")
                    lines.append("    return UnsafeMutableRawPointer(bitPattern: bits)!")
                } else if let type = method.enumResult {
                    // Converted inside the isolated closure: assumeIsolated
                    // wants a Sendable result, and the ordinal is one where a
                    // public enum from another module need not be.
                    lines.append("    return MainActor.assumeIsolated { basicEnumOut_\(type.stem)(\(called)) }")
                } else if method.objectResult != nil || method.arrayResult != nil || method.stringResult {
                    // The pointer is made *outside* the isolated closure: a
                    // raw pointer is explicitly not Sendable, and returning
                    // one across that boundary is an error in Swift 6.
                    lines.append("    let result = MainActor.assumeIsolated { \(called) }")
                    lines.append("    return \(handOut("result"))")
                } else {
                    lines.append("    return MainActor.assumeIsolated { \(called) }")
                }
            }
            lines.append("}")
            lines.append("")
        }
        for property in properties {
            lines.append("@_cdecl(\"\(property.getter)\")")
            lines.append("public func \(property.getter)(_ me: UnsafeMutableRawPointer) -> Int {")
            lines.append("    let object = Unmanaged<\(property.className)>.fromOpaque(me).takeUnretainedValue()")
            if property.isActor {
                lines.append("    do {")
                lines.append("        return try basicAwait { basicEnumOut_\(property.type.stem)(await object.`\(property.name)`) }")
                lines.append("    } catch {")
                lines.append("        basicAwaitRaise(error)")
                lines.append("    }")
            } else {
                lines.append("    return MainActor.assumeIsolated { basicEnumOut_\(property.type.stem)(object.`\(property.name)`) }")
            }
            lines.append("}")
            lines.append("")
            guard property.isSettable, !property.isActor else { continue }
            lines.append("@_cdecl(\"\(property.setter)\")")
            lines.append("public func \(property.setter)(_ me: UnsafeMutableRawPointer, _ value: Int) {")
            lines.append("    let object = Unmanaged<\(property.className)>.fromOpaque(me).takeUnretainedValue()")
            lines.append("    let converted = basicEnumIn_\(property.type.stem)(value)")
            lines.append("    MainActor.assumeIsolated { object.`\(property.name)` = converted }")
            lines.append("}")
            lines.append("")
        }
        for property in payloadProperties {
            lines.append("@_cdecl(\"\(property.getter)\")")
            lines.append("public func \(property.getter)(_ me: UnsafeMutableRawPointer, _ ti: Int) -> UnsafeMutableRawPointer {")
            lines.append("    let object = Unmanaged<\(property.className)>.fromOpaque(me).takeUnretainedValue()")
            if property.isActor {
                lines.append("    do {")
                lines.append("        return try basicAwait { basicPayloadOut_\(property.type.stem)(await object.`\(property.name)`, ti) }")
                lines.append("    } catch {")
                lines.append("        basicAwaitRaise(error)")
                lines.append("    }")
            } else {
                lines.append("    let bits = MainActor.assumeIsolated { Int(bitPattern: basicPayloadOut_\(property.type.stem)(object.`\(property.name)`, ti)) }")
                lines.append("    return UnsafeMutableRawPointer(bitPattern: bits)!")
            }
            lines.append("}")
            lines.append("")
            guard property.isSettable, !property.isActor else { continue }
            lines.append("@_cdecl(\"\(property.setter)\")")
            lines.append("public func \(property.setter)(_ me: UnsafeMutableRawPointer, _ value: UnsafeMutableRawPointer?) {")
            lines.append("    let object = Unmanaged<\(property.className)>.fromOpaque(me).takeUnretainedValue()")
            lines.append("    let converted = basicPayloadIn_\(property.type.stem)(value)")
            lines.append("    MainActor.assumeIsolated { object.`\(property.name)` = converted }")
            lines.append("}")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
