import BASICCompilerKit
import Foundation

/// Lowers a BASIC `CLASS` into a real Swift class — storage, metadata, and
/// method bodies — with no proxy and no wrapper object anywhere.
///
/// This is the point of Rev 2 made executable. A `Sprite` allocated by BASIC
/// is allocated with `swift_allocObject` and this class's own metadata; a
/// Swift program holds that same pointer, dispatches to BASIC method bodies
/// through the vtable, and may inherit from it.
///
/// ```text
///   CLASS Sprite            ─►  @"$s6sprite6SpriteCMf"   metadata
///     PUBLIC X AS DOUBLE    ─►  field offset 16          storage
///     FUNCTION Area()       ─►  @"$s6sprite6SpriteC4AreaSdyF"
///   END CLASS                   in the vtable, so an override finds it
/// ```
///
/// ## The subset, and why it is a subset
///
/// Numbers only, for now: stored properties of type `DOUBLE`/`INTEGER`, and
/// nullary methods whose bodies are arithmetic over fields and literals.
/// That is not a toy restriction chosen for convenience — it is the boundary
/// of what needs no runtime representation decisions. Strings, arrays and
/// objects all wait on R2, which decides what they *are* in this dialect;
/// lowering them now would be inventing an answer the plan has not settled.
///
/// Everything outside the subset is refused by name, with the reason. A back
/// end that silently emitted something plausible for an unsupported construct
/// would produce a program that runs and is wrong, which is worse than one
/// that does not build.
public struct SwiftObjectLowering {
    /// Something the subset does not cover.
    public struct Unsupported: Error, CustomStringConvertible {
        /// Where it was found, in BASIC's terms.
        public let context: String
        /// What was not supported.
        public let reason: String
        public var description: String { "\(context): \(reason)" }
    }

    /// The program.
    public let module: BIRModule
    /// The Swift class every BASIC class descends from.
    public let root: SwiftClassMetadata.Superclass

    /// `BASICRTSwift.BASICObject`, measured against the 6.3.1 toolchain: an
    /// empty `open class` whose only metadata slot is its initializer, and
    /// whose instances are just the two-word object header.
    public static let basicObject = SwiftClassMetadata.Superclass(
        module: "BASICRTSwift",
        name: "BASICObject",
        immediateMembers: [.method("$s12BASICRTSwift11BASICObjectCACycfC")],
        instanceSize: 16
    )

    /// The method descriptor for `BASICObject.init()`, which every BASIC
    /// class overrides — a subclass with its own storage cannot inherit an
    /// initializer that does not know about it, so the slot has to point at
    /// the subclass's own. Measured: `swiftc` emits exactly this override for
    /// a Swift subclass of an empty base.
    public static let basicObjectInitDescriptor = "$s12BASICRTSwift11BASICObjectCACycfCTq"

    /// Creates a lowering.
    public init(module: BIRModule, root: SwiftClassMetadata.Superclass = SwiftObjectLowering.basicObject) {
        self.module = module
        self.root = root
    }

    /// Every `CLASS` in the program.
    public var classes: [BIRCompositeType] { module.types.filter(\.isClass) }

    /// The whole module: preamble, then each class's metadata and code.
    public func render() throws -> String {
        var out = "target triple = \"\(TargetTriple.host.rawValue)\"\n\n"
        out += SwiftClassMetadata.preamble
        // What the root class gives us and this module only refers to.
        let rootMangled = try SwiftMangling.mangleClass(module: root.module, name: root.name)
        out += "@\"\(rootMangled)N\" = external global %swift.type, align 8\n"
        out += "@\"\(rootMangled)Mm\" = external global %objc_class, align 8\n"
        out += "@\"\(rootMangled)Mn\" = external global %swift.type_descriptor, align 4\n"
        out += "@\"\(Self.basicObjectInitDescriptor)\" = external global %swift.method_descriptor, align 4\n"
        for symbol in rootMethodSymbols {
            out += "declare swiftcc ptr @\"\(symbol)\"(ptr swiftself)\n"
        }
        out += "\n"
        for composite in classes {
            out += try render(composite)
        }
        return out
    }

    /// The root class's vtable entries, which this module calls but does not
    /// define.
    var rootMethodSymbols: [String] {
        root.immediateMembers.compactMap { slot in
            if case .method(let symbol) = slot { return symbol }
            return nil
        }
    }

    /// One class.
    func render(_ composite: BIRCompositeType) throws -> String {
        let name = composite.displayName
        for field in composite.fields where field.type != .number {
            throw Unsupported(
                context: "CLASS \(name), field \(field.displayName)",
                reason: "\(field.type.name) fields are not lowered as Swift storage yet — the swift dialect lowers numbers only, until R2 settles what a string is here"
            )
        }
        let methods = try methods(of: composite)
        let metadata = SwiftClassMetadata(
            module: module.name,
            name: name,
            superclass: root,
            overrides: [
                .init(
                    baseMethodDescriptor: Self.basicObjectInitDescriptor,
                    implementation: try SwiftMangling.mangleInitializer(
                        module: module.name, className: name, allocating: true
                    ),
                    slot: 0
                )
            ],
            storedProperties: composite.fields.map { .init(name: $0.displayName) },
            methods: try methods.map { .init(name: $0.basicName, implementation: try $0.symbol(module: module.name, className: name)) }
        )
        var out = try metadata.render()
        out += try constructor(for: composite, metadata: metadata)
        out += try destructor(for: composite, metadata: metadata)
        for method in methods {
            out += try body(of: method, in: composite, metadata: metadata)
        }
        return out + "\n"
    }

    /// A method of a class: BIR names it `CLASS.METHOD` and passes the
    /// receiver first.
    public struct Method {
        /// The BIR function.
        public let function: BIRFunction
        /// The name as BASIC wrote it.
        public let basicName: String

        /// Its parameters, the receiver excluded.
        public var arguments: [BIRVariable] { Array(function.parameters.dropFirst()) }

        /// Its Swift symbol.
        public func symbol(module: String, className: String) throws -> String {
            try SwiftMangling.mangleMethod(
                module: module, className: className, method: basicName,
                returns: function.returnType == .void ? .void : .number,
                parameters: arguments.map { _ in .number }
            )
        }
    }

    /// The class's methods, refusing any shape the subset does not cover.
    public func methods(of composite: BIRCompositeType) throws -> [Method] {
        let prefix = composite.name + "."
        return try module.functions.filter { $0.name.hasPrefix(prefix) }.map { function in
            let basicName = String(function.name.dropFirst(prefix.count))
            for parameter in function.parameters.dropFirst() where parameter.type != .number {
                throw Unsupported(
                    context: "\(composite.displayName).\(basicName)",
                    reason: "parameter \(parameter.name) is \(parameter.type.name); the swift dialect lowers numbers only for now"
                )
            }
            guard function.returnType == .number || function.returnType == .void else {
                throw Unsupported(
                    context: "\(composite.displayName).\(basicName)",
                    reason: "returns \(function.returnType.name); the swift dialect lowers numbers only for now"
                )
            }
            return Method(function: function, basicName: basicName)
        }
    }

    /// `NEW Sprite` — allocate with this class's metadata, then zero the
    /// fields. Both halves of Swift's initializer, because a Swift subclass
    /// calls the initializing one through `super.init()`.
    func constructor(for composite: BIRCompositeType, metadata: SwiftClassMetadata) throws -> String {
        let mangled = try SwiftMangling.mangleClass(module: module.name, name: composite.displayName)
        let allocating = try SwiftMangling.mangleInitializer(module: module.name, className: composite.displayName, allocating: true)
        let initializing = try SwiftMangling.mangleInitializer(module: module.name, className: composite.displayName, allocating: false)
        var out = "define swiftcc ptr @\"\(initializing)\"(ptr swiftself %self) {\n"
        for offset in metadata.ownFieldOffsets {
            out += "  %p\(offset) = getelementptr inbounds i8, ptr %self, i64 \(offset)\n"
            out += "  store double 0.0, ptr %p\(offset), align 8\n"
        }
        out += "  ret ptr %self\n}\n"
        out += "define swiftcc ptr @\"\(allocating)\"(ptr swiftself %type) {\n"
        out += "  %obj = call ptr @swift_allocObject(ptr %type, i64 \(metadata.instanceSize), i64 7)\n"
        out += "  %r = call swiftcc ptr @\"\(initializing)\"(ptr swiftself %obj)\n"
        out += "  ret ptr %r\n}\n"
        _ = mangled
        return out
    }

    /// Teardown. Numbers own nothing, so the destroying half has nothing to
    /// release; the deallocating half hands the storage back.
    func destructor(for composite: BIRCompositeType, metadata: SwiftClassMetadata) throws -> String {
        let destroying = try SwiftMangling.mangleDestructor(module: module.name, className: composite.displayName, deallocating: false)
        let deallocating = try SwiftMangling.mangleDestructor(module: module.name, className: composite.displayName, deallocating: true)
        return """
        define swiftcc ptr @"\(destroying)"(ptr swiftself %self) { ret ptr %self }
        define swiftcc void @"\(deallocating)"(ptr swiftself %self) {
          %o = call swiftcc ptr @"\(destroying)"(ptr swiftself %self)
          call void @swift_deallocClassInstance(ptr %o, i64 \(metadata.instanceSize), i64 7)
          ret void
        }

        """
    }

    /// A method body, from BIR.
    func body(of method: Method, in composite: BIRCompositeType, metadata: SwiftClassMetadata) throws -> String {
        let symbol = try method.symbol(module: module.name, className: composite.displayName)
        let context = "\(composite.displayName).\(method.basicName)"
        guard method.function.blocks.count == 1 else {
            throw Unsupported(context: context, reason: "control flow is not lowered yet — the body must be a single straight-line block")
        }
        let block = method.function.blocks[0]
        var emitter = Emitter(offsets: metadata.ownFieldOffsets, context: context)
        // Swift passes arguments in order, with the receiver in the swiftself
        // register — so a BASIC parameter is just the next SSA argument.
        for (index, parameter) in method.arguments.enumerated() {
            emitter.parameters[parameter.name] = "%arg\(index)"
        }
        for instruction in block.instructions {
            try emitter.emit(instruction.operation)
        }
        let signature = (method.arguments.enumerated().map { "double %arg\($0.offset)" } + ["ptr swiftself %self"])
            .joined(separator: ", ")
        switch block.terminator {
        case .ret(let expression?):
            let result = try emitter.emit(expression)
            return "define swiftcc double @\"\(symbol)\"(\(signature)) {\n\(emitter.text)  ret double \(result)\n}\n"
        case .ret(nil), .end:
            return "define swiftcc void @\"\(symbol)\"(\(signature)) {\n\(emitter.text)  ret void\n}\n"
        default:
            throw Unsupported(context: context, reason: "the body must end in RETURN")
        }
    }

    /// Emits straight-line arithmetic over a receiver's fields.
    struct Emitter {
        let offsets: [Int]
        let context: String
        var text = ""
        /// A BASIC parameter's name to the SSA value holding it.
        var parameters: [String: String] = [:]

        init(offsets: [Int], context: String) {
            self.offsets = offsets
            self.context = context
        }
        var next = 0

        /// One statement. Only assignment to `ME`'s own numeric fields, which
        /// is what a BASIC setter is.
        mutating func emit(_ operation: BIROperation) throws {
            guard case .storeField(let place, let value) = operation,
                  case .field(_, let index, .number) = place else {
                throw Unsupported(
                    context: context,
                    reason: "only assignment to ME's numeric fields is lowered yet"
                )
            }
            guard offsets.indices.contains(index) else {
                throw Unsupported(context: context, reason: "field #\(index) is outside this class")
            }
            let result = try emit(value)
            let pointer = temporary()
            text += "  \(pointer) = getelementptr inbounds i8, ptr %self, i64 \(offsets[index])\n"
            text += "  store double \(result), ptr \(pointer), align 8\n"
        }

        mutating func temporary() -> String {
            defer { next += 1 }
            return "%t\(next)"
        }

        mutating func emit(_ expression: BIRExpression) throws -> String {
            switch expression {
            case .number(let value):
                // Hex form: LLVM's decimal float literals must be exactly
                // representable, and BASIC's are not in general.
                return "0x" + String(format: "%016llX", value.bitPattern)
            case .negate(let inner):
                let operand = try emit(inner)
                let result = temporary()
                text += "  \(result) = fneg double \(operand)\n"
                return result
            case .arithmetic(let op, let lhs, let rhs):
                let left = try emit(lhs), right = try emit(rhs)
                let instruction: String
                switch op {
                case .add: instruction = "fadd"
                case .subtract: instruction = "fsub"
                case .multiply: instruction = "fmul"
                case .divide: instruction = "fdiv"
                }
                let result = temporary()
                text += "  \(result) = \(instruction) double \(left), \(right)\n"
                return result
            case .load(let variable):
                guard let value = parameters[variable.name] else {
                    throw Unsupported(context: context, reason: "local variable \(variable.name) is not lowered yet — only parameters and ME's fields are")
                }
                return value
            case .field(_, let index, .number):
                guard offsets.indices.contains(index) else {
                    throw Unsupported(context: context, reason: "field #\(index) is outside this class")
                }
                let pointer = temporary()
                text += "  \(pointer) = getelementptr inbounds i8, ptr %self, i64 \(offsets[index])\n"
                let result = temporary()
                text += "  \(result) = load double, ptr \(pointer), align 8\n"
                return result
            default:
                throw Unsupported(
                    context: context,
                    reason: "this expression is outside the subset the swift dialect lowers (numbers, ME's numeric fields, and + - * /)"
                )
            }
        }
    }
}
