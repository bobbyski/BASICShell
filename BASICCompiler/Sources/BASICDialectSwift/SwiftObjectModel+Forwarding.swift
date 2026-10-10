import BASICCompilerKit
import Foundation

// A program class that inherits a framework class, in a mapped module
// (BASIC-45, slice 11d). See ``SwiftForwarding`` for the forwarding classes
// the map compiles; this is the program's half:
//
//   NEW Gauge()   → the base's initializer, made as BASICForward_<Base>; the
//                   object told it is a Gauge, given Gauge's record, and the
//                   thunk for each method Gauge overrides
//   G.level       → Gauge's record, through thunks of its own
//   G.isHidden    → the base's property, as the base reaches it
//   Swift calls refreshSelf() on it → BASICForward_AUIView asks the object
//                   → `forward.GAUGE.REFRESHSELF`, which reads the arguments
//                   from the frame and calls Gauge's REFRESHSELF

extension SwiftObjectModel {
    /// After a forwarded class's object is made: what it is, its record, and
    /// its overrides, by slot.
    func forwardingSetup(_ forwarded: Forwarded, object: String, temp: () -> String) -> String {
        let index = forwarded.composite.index
        let record = temp()
        var body = "  \(record) = call ptr @basic_rt_composite_new(i64 \(index))\n"
        body += "  call void @basic_forward_setup(ptr \(object), i64 \(index), ptr \(record))\n"
        for (slot, function) in forwardOverrides(forwarded) {
            body += "  call void @basic_forward_override(ptr \(object), i64 \(slot), ptr @\"\(Self.forwardThunk(function.name))\")\n"
        }
        return body
    }

    /// The BASIC bodies that override the base's forwardable methods, by
    /// slot: for each, the nearest class from this one up that declares a
    /// method of that name whose signature crosses.
    func forwardOverrides(_ forwarded: Forwarded) -> [(slot: Int, function: BIRFunction)] {
        var chain: [BIRCompositeType] = []
        var walk: BIRCompositeType? = forwarded.composite
        while let here = walk, here.externalModule == nil {
            chain.append(here)
            walk = here.base.flatMap { index in module.types.first { $0.index == index } }
        }
        var out: [(Int, BIRFunction)] = []
        for (slot, method) in SwiftForwarding.methods(of: forwarded.base.klass, in: forwarded.base.api).enumerated() {
            for klass in chain {
                guard let function = module.functions.first(where: {
                    $0.name == "\(klass.name).\(method.name.uppercased())" && !$0.isExternal
                }), Self.forwardMatches(function, method) else { continue }
                out.append((slot, function))
                break
            }
        }
        return out
    }

    /// Whether a BASIC method can stand for a framework method an override
    /// forwards: ME, then each argument, and the result, as the frame
    /// carries them.
    static func forwardMatches(_ function: BIRFunction, _ method: SwiftAPI.Function) -> Bool {
        guard function.parameters.count == method.parameters.count + 1 else { return false }
        for (parameter, swift) in zip(function.parameters.dropFirst(), method.parameters)
        where !forwardMatches(parameter.type, swift.type) { return false }
        return forwardMatches(function.returnType, method.returns)
    }

    static func forwardMatches(_ basic: BIRType, _ swift: SwiftAPI.ValueType) -> Bool {
        switch (basic, swift) {
        case (.void, .void), (.number, .double), (.number, .int), (.number, .cgFloat),
             (.boolean, .bool), (.string, .string): return true
        default: return false
        }
    }

    /// The thunk a forwarding class's override calls for a BASIC method.
    static func forwardThunk(_ function: String) -> String { "forward.\(function)" }

    /// A forwarded class's own definitions: constructors, its own fields'
    /// accessors over its record, and the thunks for its overrides.
    func perForwardedClass(_ forwarded: Forwarded) -> String {
        let name = forwarded.composite.name
        var out = "; \(forwarded.composite.displayName), a BASIC class inheriting \(forwarded.base.module).\(forwarded.base.klass.name)\n"
        out += perImportedClass(forwarded.base, forwarding: forwarded)
        for (index, field) in forwarded.composite.fields.enumerated() where index >= forwarded.baseFieldCount {
            let type: String, get: String, set: String
            switch field.type {
            case .number: (type, get, set) = ("double", "basic_rt_composite_get_number", "basic_rt_composite_set_number")
            case .boolean: (type, get, set) = ("i1", "basic_rt_composite_get_boolean", "basic_rt_composite_set_boolean")
            case .string: (type, get, set) = ("ptr", "basic_rt_composite_get_string", "basic_rt_composite_set_string")
            case .composite: (type, get, set) = ("ptr", "basic_rt_composite_get_composite", "basic_rt_composite_set_composite")
            default: continue
            }
            out += "define \(type) @\"\(name).get.\(index)\"(ptr %o) {\n"
            out += "  %r = call ptr @basic_forward_record(ptr %o)\n"
            out += "  %v = call \(type) @\(get)(ptr %r, i64 \(index))\n  ret \(type) %v\n}\n"
            out += "define void @\"\(name).set.\(index)\"(ptr %o, \(type) %v) {\n"
            out += "  %r = call ptr @basic_forward_record(ptr %o)\n"
            out += "  call void @\(set)(ptr %r, i64 \(index), \(type) %v)\n  ret void\n}\n"
        }
        return out
    }

    /// The thunks for every override any forwarded class registers, once
    /// each: `(frame) -> double`, the callbacks' shape. The frame carries ME
    /// and the arguments, and takes the result.
    func forwardThunks() -> String {
        var done = Set<String>()
        var out = ""
        for name in forwardedByName.keys.sorted() {
            for (_, function) in forwardOverrides(forwardedByName[name]!) where done.insert(function.name).inserted {
                var body = "  %me = call ptr @basic_forward_arg_pointer(ptr %frame, i64 0)\n"
                var arguments = ["ptr %me"]
                for (offset, parameter) in function.parameters.dropFirst().enumerated() {
                    let value = "%a\(offset)"
                    switch parameter.type {
                    case .boolean:
                        body += "  \(value) = call i1 @basic_forward_arg_boolean(ptr %frame, i64 \(offset + 1))\n"
                        arguments.append("i1 \(value)")
                    case .string:
                        body += "  \(value) = call ptr @basic_forward_arg_pointer(ptr %frame, i64 \(offset + 1))\n"
                        arguments.append("ptr \(value)")
                    default:
                        body += "  \(value) = call double @basic_forward_arg_number(ptr %frame, i64 \(offset + 1))\n"
                        arguments.append("double \(value)")
                    }
                }
                let call = "@\"F.\(function.name)\"(\(arguments.joined(separator: ", ")))"
                switch function.returnType {
                case .void:
                    body += "  call void \(call)\n"
                case .boolean:
                    body += "  %r = call i1 \(call)\n  call void @basic_forward_result_boolean(ptr %frame, i1 %r)\n"
                case .string:
                    body += "  %r = call ptr \(call)\n  call void @basic_forward_result_pointer(ptr %frame, ptr %r)\n"
                default:
                    body += "  %r = call double \(call)\n  call void @basic_forward_result_number(ptr %frame, double %r)\n"
                }
                out += "define double @\"\(Self.forwardThunk(function.name))\"(ptr %frame) {\n\(body)  ret double 0\n}\n"
            }
        }
        return out
    }

    /// The `declare`s a mapped module with forwarded classes needs.
    func forwardingDeclarations() -> String {
        guard !forwardedByName.isEmpty else { return "" }
        var out = """
        declare void @basic_forward_setup(ptr, i64, ptr)
        declare void @basic_forward_override(ptr, i64, ptr)
        declare ptr @basic_forward_record(ptr)
        declare i64 @basic_forward_type_index(ptr)
        declare double @basic_forward_arg_number(ptr, i64)
        declare i1 @basic_forward_arg_boolean(ptr, i64)
        declare ptr @basic_forward_arg_pointer(ptr, i64)
        declare void @basic_forward_result_number(ptr, double)
        declare void @basic_forward_result_boolean(ptr, i1)
        declare void @basic_forward_result_pointer(ptr, ptr)

        """
        var seen = Set<String>()
        for name in forwardedByName.keys.sorted() {
            let base = forwardedByName[name]!.base
            for initializer in base.klass.initializers {
                let shim = "basic_new_\(SwiftForwarding.className(for: base.klass.name))_\(Self.basicArity(initializer, in: base.api))"
                guard seen.insert(shim).inserted else { continue }
                out += "declare ptr @\(shim)(\(Self.shimParameters(initializer.passed, in: base.api).joined(separator: ", ")))\n"
            }
        }
        return out
    }

    /// What a program class inheriting a framework class may not do in a
    /// mapped module, said by name: the shapes R1.5 refuses natively, and a
    /// base the map has no forwarding class for.
    static func forwardingRefusals(_ module: BIRModule, forwarded: [String: Forwarded]) -> [Diagnostic] {
        var out: [Diagnostic] = []
        for name in forwarded.keys.sorted() {
            let class_ = forwarded[name]!
            let display = class_.composite.displayName
            let base = class_.base.klass.name
            func refuse(_ reason: String) {
                out.append(Diagnostic(severity: .error, file: nil, line: nil, message: "CLASS \(display) INHERITS \(base): \(reason)"))
            }
            guard SwiftForwarding.isForwardable(class_.base.klass) else {
                refuse("\(base) is not `open`, so Swift does not let a class outside \(class_.base.module) inherit it")
                continue
            }
            if module.functions.contains(where: { $0.name == class_.composite.name + ".NEW" && !$0.isExternal }) {
                refuse("it declares its own NEW; a class that inherits a framework class takes its base's NEW for now")
            }
            for field in class_.composite.fields.dropFirst(class_.baseFieldCount) {
                switch field.type {
                case .number, .boolean, .string, .composite: continue
                case _ where livesInRuntimeRecord(field.type): continue
                default:
                    refuse("its field \(field.displayName) is \(field.type.name), which a class that inherits a framework class cannot hold yet")
                }
            }
        }
        return out
    }
}
