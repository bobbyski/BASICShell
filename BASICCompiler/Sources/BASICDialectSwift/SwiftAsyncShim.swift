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

    /// The module being imported.
    public let module: String
    /// Its async methods.
    public let methods: [Method]

    public init(module: String, methods: [Method]) {
        self.module = module
        self.methods = methods
    }

    /// The Swift source, or nil when there is nothing to shim.
    public func source() -> String? {
        guard !methods.isEmpty else { return nil }
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
        for method in methods {
            // A handler parameter arrives as the pair BASIC can supply — a C
            // function pointer and the closure it should invoke — and becomes
            // an ordinary Swift closure right here, which is the whole point:
            // the framework stores a Swift closure, not a wrapper object.
            var parameters = method.isInitializer ? [] : ["_ me: UnsafeMutableRawPointer"]
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
                        parameters.append("_ a\(index)_\(leaf): \(spelling)")
                    }
                    callArguments.append("s\(index)")
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
                } else {
                    parameters.append("_ a\(index): \(type)")
                    callArguments.append("a\(index)")
                }
            }
            let labelled = zip(method.labels, callArguments.indices)
                .map { label, index in label.map { "\($0): \(callArguments[index])" } ?? callArguments[index] }
                .joined(separator: ", ")
            // A class result crosses as a pointer too, unretained: an
            // imported object belongs to the framework, and BASIC holding one
            // aliases it rather than owning a copy (ruling D15).
            let result = (method.isInitializer || method.objectResult != nil || method.arrayResult != nil)
                ? " -> UnsafeMutableRawPointer"
                : (method.returns.map { " -> \($0)" } ?? "")
            func handOut(_ expression: String) -> String {
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
                lines.append("    let object = Unmanaged<\(method.className)>.fromOpaque(me).takeUnretainedValue()")
            }
            for (index, className) in method.objectParameters.sorted(by: { $0.key < $1.key }) {
                lines.append("    let o\(index) = Unmanaged<\(className)>.fromOpaque(a\(index)).takeUnretainedValue()")
            }
            // Read out of the runtime's array before the call, for the same
            // reason an object parameter is bridged before it: what goes into
            // the framework is a Swift value, not a pointer some later closure
            // would have to capture.
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
                    ? "try await object.\(method.name)(\(labelled))"
                    : "await object.\(method.name)(\(labelled))"
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
                let called = "try object.\(method.name)(\(labelled))"
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
                let called = "object.\(method.name)(\(labelled))"
                if method.returns == nil {
                    lines.append("    MainActor.assumeIsolated { \(called) }")
                } else if method.objectResult != nil || method.arrayResult != nil {
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
        return lines.joined(separator: "\n")
    }
}
