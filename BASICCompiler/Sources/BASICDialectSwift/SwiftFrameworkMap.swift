import Foundation

/// A framework *map* (BASIC-45): what lets a program BASICStudio runs as
/// WebAssembly `IMPORT` a framework Studio itself contains — ActiveUI,
/// TUIKit — with no swiftc and no `swift build` where it runs (an iPad).
///
/// ```text
///   basicc framework-map (on a Mac, when the frameworks change)
///     ├─ <Module>.symbols.json, <Module>.exported   what IMPORT declares (R4.1, R4.2)
///     ├─ <Module>Shims.swift     R4's shims for EVERY member, compiled into Studio
///     └─ <Module>Entries.swift   shim name → an entry taking its arguments as
///                                numbers, as a WebAssembly import passes them
/// ```
///
/// The shims are R4's own (``SwiftPackageResolver/shimModel(for:mapped:)``),
/// so a map and basicc's native Swift dialect share one binding. The entries
/// are generated from the shims' signatures as written, so the two cannot
/// disagree about an argument.
public enum SwiftFrameworkMap {
    /// One `@_cdecl` function's C signature, as the generated Swift spells it.
    public struct Signature: Equatable, Sendable {
        public let name: String
        public let parameters: [String]
        /// Nil for `Void`.
        public let returns: String?
        /// For a handler property's setter (P1.2): how many arguments the
        /// handler takes, read from the shim's own cast of the BASIC body.
        public var handlerArguments: Int?
        /// For a provider's setter, a handler the framework waits on for an
        /// answer (BASIC-45): the C type the shim reads the answer as —
        /// `Swift.Double`, `Swift.Bool`, `UnsafeMutableRawPointer?` (a
        /// string). Nil for a handler that answers nothing.
        public var handlerResult: String?
    }

    /// Every `@_cdecl` function in `source`, in order.
    public static func signatures(in source: String) -> [Signature] {
        var found: [Signature] = []
        let lines = source.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() where line.hasPrefix("@_cdecl(\"") && index + 1 < lines.count {
            let declaration = lines[index + 1]
            guard declaration.hasPrefix("public func "),
                  let open = declaration.firstIndex(of: "("),
                  let close = matchingParenthesis(in: declaration, from: open) else { continue }
            let name = String(declaration[declaration.index(declaration.startIndex, offsetBy: "public func ".count)..<open])
            let inside = String(declaration[declaration.index(after: open)..<close])
            let parameters = splitTopLevel(inside).compactMap { parameter -> String? in
                // `_ name: Type`
                guard let colon = parameter.firstIndex(of: ":") else { return nil }
                return parameter[parameter.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let tail = declaration[declaration.index(after: close)...]
            var returns: String?
            if let arrow = tail.range(of: "->") {
                returns = tail[arrow.upperBound...].replacingOccurrences(of: "{", with: "").trimmingCharacters(in: .whitespaces)
            }
            var signature = Signature(name: name, parameters: parameters, returns: returns)
            if parameters.contains("UnsafeRawPointer?") {
                // `unsafeBitCast(fn, to: (@convention(c) (UnsafeMutableRawPointer?, A…) -> R).self)`
                for body in lines[(index + 2)...] {
                    if body.hasPrefix("@_cdecl(") { break }
                    guard let start = body.range(of: "@convention(c) ("),
                          let close = matchingParenthesis(in: body, from: body.index(before: start.upperBound)) else { continue }
                    let inside = String(body[start.upperBound..<close])
                    signature.handlerArguments = max(0, splitTopLevel(inside).count - 1)
                    // The shim keeps the answer (`let r = body(…)`) only
                    // for a provider; a `() -> Void` handler drops it.
                    let setter = lines[(index + 2)...].prefix { !$0.hasPrefix("@_cdecl(") }
                    if setter.contains(where: { $0.contains("let r = body(") }),
                       let arrow = body[close...].range(of: "-> "),
                       let end = body[arrow.upperBound...].range(of: ").self") {
                        signature.handlerResult = String(body[arrow.upperBound..<end.lowerBound])
                    }
                    break
                }
            }
            found.append(signature)
        }
        return found
    }

    /// The entry table for a module's shims: `<Module>Entries`, a dictionary
    /// from each shim's name to a ``WasmEntryPoint`` that converts the
    /// numbers a WebAssembly import passes and calls it.
    public static func entriesSource(module: String, signatures: [Signature]) -> String {
        let stem = module.replacingOccurrences(of: ".", with: "_")
        var lines = [
            "// Generated by `basicc framework-map` (BASIC-45). Nothing here is",
            "// hand-written: each entry is \(module)'s shim of the same name, with",
            "// its arguments as a WebAssembly import passes them — numbers.",
            "import BASICWasmRunner",
            "import CoreGraphics",
            "import Foundation",
            "",
            "public let \(stem)Entries: [String: WasmEntryPoint] = [",
        ]
        for signature in signatures {
            var arguments: [String] = []
            var prelude: [String] = []
            var slot = 0
            var index = 0
            while index < signature.parameters.count {
                let type = signature.parameters[index]
                if type.hasPrefix("@convention(c)") {
                    // A `() -> Void` handler's pair (R4.5): the module passes
                    // the BASIC closure as the context, and a native function
                    // that calls it back into the module is made here.
                    prelude.append("let c\(slot) = WasmCallbacks.voidClosure(a[\(slot + 1)])")
                    arguments.append("c\(slot).function")
                    arguments.append("c\(slot).context")
                    slot += 2
                    index += 2
                    continue
                }
                if type == "UnsafeRawPointer?" {
                    // A handler property's compiled body and its environment
                    // (P1.2): the module's table slot and the closure's
                    // environment, made a native function and a context.
                    let member = signature.name.replacingOccurrences(of: "basic_set_", with: "")
                        .replacingOccurrences(of: "_", with: ".")
                    // A provider's answer, by the C type its shim reads.
                    let answers: String
                    switch signature.handlerResult {
                    case nil: answers = ""
                    case "Swift.Bool"?: answers = ", result: .boolean"
                    case "UnsafeMutableRawPointer?"?: answers = ", result: .string"
                    default: answers = ", result: .number"
                    }
                    prelude.append("let h\(slot) = WasmCallbacks.handler(function: a[\(slot)], environment: a[\(slot + 1)], parameters: \(signature.handlerArguments ?? 0)\(answers), name: \"\(member)\")")
                    arguments.append("h\(slot).function")
                    arguments.append("h\(slot).context")
                    slot += 2
                    index += 2
                    continue
                }
                // Read now, on the run's thread: the import's arguments are
                // the next import's once a callback runs during the call.
                prelude.append("let p\(slot) = \(argument(type, "a[\(slot)]"))")
                arguments.append("p\(slot)")
                slot += 1
                index += 1
            }
            // The arguments are read on the run's thread; the shim runs on
            // the main thread, which its main-actor isolation asserts. Not
            // the class index, which touches no framework state and is asked
            // at every copy and release of any object.
            let call = "\(signature.name)(\(arguments.joined(separator: ", ")))"
            let inner = result(signature.returns, call)
            let isClassIndex = signature.name.hasPrefix("basic_classid_")
            let body = (prelude + [isClassIndex ? inner : "return WasmMainThread.run { \(inner) }"]).joined(separator: "; ")
            lines.append("    \"\(signature.name)\": WasmEntryPoint(arity: \(slot)) { a in \(body) },")
        }
        lines.append("]")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// A number, as the parameter type wants it.
    static func argument(_ type: String, _ value: String) -> String {
        switch type {
        case "UnsafeMutableRawPointer": return "unsafeBitCast(UnsafeMutableRawPointer(bitPattern: UInt(\(value))), to: UnsafeMutableRawPointer.self)"
        case "UnsafeMutableRawPointer?": return "UnsafeMutableRawPointer(bitPattern: UInt(\(value)))"
        case "Int", "Swift.Int": return "Int(\(value))"
        case "Bool", "Swift.Bool": return "\(value) != 0"
        case "CGFloat", "CoreGraphics.CGFloat": return "CGFloat(\(value))"
        default: return value
        }
    }

    /// The call's result, as the number a WebAssembly import returns.
    static func result(_ type: String?, _ call: String) -> String {
        switch type {
        case nil, "Void": return "\(call); return 0"
        case "UnsafeMutableRawPointer": return "return Double(UInt(bitPattern: \(call)))"
        case "UnsafeMutableRawPointer?": return "return (\(call)).map { Double(UInt(bitPattern: $0)) } ?? 0"
        case "Int", "Swift.Int": return "return Double(\(call))"
        case "Bool", "Swift.Bool": return "return \(call) ? 1 : 0"
        case "CGFloat", "CoreGraphics.CGFloat": return "return Double(\(call))"
        default: return "return \(call)"
        }
    }

    private static func matchingParenthesis(in text: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            switch text[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Splits a parameter list at the commas that are not inside a nested
    /// parenthesis — a function type's own parameter list is one parameter.
    private static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for character in text {
            switch character {
            case "(": depth += 1; current.append(character)
            case ")": depth -= 1; current.append(character)
            case "," where depth == 0:
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default: current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current.trimmingCharacters(in: .whitespaces)) }
        return parts
    }
}
