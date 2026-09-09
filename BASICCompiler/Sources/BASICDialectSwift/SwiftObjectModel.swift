import BASICCompilerKit
import BASICDialectTraditional
import Foundation

/// Rev 2's answer to "where do objects live": a `CLASS` is a Swift object.
///
/// This is the in-program object model — the one a whole compiled BASIC
/// program runs on, as opposed to ``SwiftObjectLowering``, which emits a
/// standalone class for Swift to link against. It plugs into Rev 1's emitter
/// through ``ObjectModel``: the emitter keeps every site it had and asks
/// this for the symbol to call, so **value semantics are the emitter's** —
/// assignment copies, a method call copies the receiver in and writes it
/// back — and a class laid out as a Swift object behaves, observably, like
/// one the runtime holds. Ruling D13.
///
/// ## Two representations, one program
///
/// Not every class qualifies (see ``analyse``), and an interface-typed
/// variable may hold either kind. So the whole-object operations —
/// `obj.copy`, `obj.release`, `obj.typeIndex`, … — decide **at run time**
/// which representation they were handed: an object whose metadata chain
/// reaches `BASICRTSwift.BASICObject` is one of ours; anything else is the
/// runtime's `RTComposite`, and gets the runtime's entry point. Field access
/// needs no such check — a field's base has a static class.
///
/// ## The runtime does what it already does
///
/// Printing, JSON, VARIANT boxing and defaults are not reimplemented. A
/// Swift object is *converted* to a temporary runtime record for those
/// (`toRuntime`) and back (`fromRuntime`), so the text `PRINT A` produces is
/// the runtime's own, byte for byte. Value semantics make those copies not
/// merely safe but correct: the runtime would have copied there too.
///
/// ## What falls back, and why it is said out loud
///
/// A class the analysis declines is lowered exactly as Rev 1 lowers it, and
/// ``notes`` says which and why — so a program that runs the same but did
/// not get Swift objects is a reported fact, not a silent one.
public struct SwiftObjectModel: ObjectModel {
    /// One class laid out as a Swift object.
    public struct ClassLayout: Sendable {
        /// The composite, as BIR has it.
        public let composite: BIRCompositeType
        /// The mangled class prefix, `$s<module><Name>C`.
        public let mangled: String
        /// The normalized name of the base class, when it is one of ours.
        public let base: String?
        /// Byte offset of every field, inherited ones first.
        public let fieldOffsets: [Int]
        /// The metadata emitter, fully configured.
        public let metadata: SwiftClassMetadata
        /// Swift-visible methods: BASIC name, Swift symbol, BIR function.
        public let visibleMethods: [(name: String, symbol: String, function: BIRFunction)]
        /// Where each visible method sits in the metadata's slot list.
        public let methodSlots: [String: Int]
        /// This class's position in ``SwiftObjectModel/classes``.
        public let ordinal: Int

        var name: String { composite.name }
        var instanceSize: Int { metadata.instanceSize }
        var typeIndex: Int { composite.index }
    }

    public let module: BIRModule
    /// Classes laid out as Swift objects, bases before subclasses.
    public let classes: [ClassLayout]
    /// Why each declined class was declined.
    public let notes: [String]

    private let byName: [String: ClassLayout]

    /// Analyses `module` and lays out every class that qualifies.
    public init(module: BIRModule) {
        self.module = module
        let (accepted, notes) = Self.analyse(module)
        self.notes = notes
        var layouts: [ClassLayout] = []
        var byName: [String: ClassLayout] = [:]
        // Bases first: a subclass's layout starts where its base's ends.
        for composite in Self.dependencyOrder(accepted, in: module) {
            let layout = Self.layout(composite, in: module, bases: byName, ordinal: layouts.count)
            layouts.append(layout)
            byName[composite.name] = layout
        }
        self.classes = layouts
        self.byName = byName
    }

    // MARK: - Which classes qualify

    /// The classes that can be Swift objects, and a note for each that cannot.
    ///
    /// A class qualifies when everything that touches it is something this
    /// model handles. The rules, each of which names a runtime path that
    /// would otherwise receive a Swift object and misread it:
    ///
    /// - its fields are numbers, booleans, strings, or other qualifying
    ///   classes — arrays, dictionaries and VARIANTs inside an object are the
    ///   runtime's containers (R2);
    /// - it is never an array's element type — the runtime's arrays hold
    ///   `RTComposite`s (R2.2);
    /// - no `TYPE` record, closure environment or declined class has a field
    ///   of its type — those are runtime records, and a runtime record's
    ///   field holds a runtime value;
    /// - its base, if any, qualifies;
    /// - its name and the module's mangle (see `SwiftMangling`).
    ///
    /// Iterated to a fixed point, since declining one class can decline
    /// another that holds it.
    static func analyse(_ module: BIRModule) -> (accepted: Set<String>, notes: [String]) {
        var notes: [String] = []
        var accepted = Set<String>()
        guard Self.isIdentifier(module.name) else {
            return ([], ["no class is a Swift object: the module name '\(module.name)' is not a Swift identifier"])
        }
        var reasons: [String: String] = [:]
        for type in module.types where type.isClass {
            if !Self.isIdentifier(type.displayName) {
                reasons[type.name] = "'\(type.displayName)' is not a Swift identifier"
            } else if (try? SwiftMangling.mangleClass(module: module.name, name: type.displayName)) == nil {
                reasons[type.name] = "its name needs Swift's word substitution, which basicc does not emit yet (R0.5)"
            } else {
                accepted.insert(type.name)
            }
        }
        // Element types of arrays, anywhere.
        var arrayElements = Set<String>()
        func noteArray(_ type: BIRType, rank: Int?) {
            if rank != nil, case .composite(let name) = type { arrayElements.insert(name) }
            if case .array(let element, _) = type, case .composite(let name) = element { arrayElements.insert(name) }
        }
        for variable in module.globals { noteArray(variable.type, rank: variable.rank) }
        for function in [module.main] + module.functions {
            for variable in function.locals + function.parameters { noteArray(variable.type, rank: variable.rank) }
        }
        for type in module.types {
            for field in type.fields { noteArray(field.type, rank: field.dimensions.isEmpty ? nil : field.dimensions.count) }
        }
        for name in arrayElements where accepted.contains(name) {
            accepted.remove(name)
            reasons[name] = "it is an array's element type, and the runtime's arrays hold runtime records (R2.2)"
        }
        // Fixed point over field rules.
        var changed = true
        while changed {
            changed = false
            for type in module.types {
                let isSwift = accepted.contains(type.name)
                for field in type.fields {
                    switch field.type {
                    case .number, .boolean, .string:
                        continue
                    case .composite(let held):
                        if isSwift, !accepted.contains(held) {
                            accepted.remove(type.name)
                            reasons[type.name] = "its field \(field.displayName) is a \(module.types.first { $0.name == held }?.displayName ?? held), which is not a Swift object"
                            changed = true
                        } else if !isSwift, accepted.contains(held) {
                            accepted.remove(held)
                            reasons[held] = "\(type.displayName).\(field.displayName) holds one, and \(type.displayName) is a runtime record"
                            changed = true
                        }
                    default:
                        if isSwift {
                            accepted.remove(type.name)
                            reasons[type.name] = "its field \(field.displayName) is \(field.type.name), a runtime container (R2)"
                            changed = true
                        }
                    }
                }
                if isSwift, let base = type.base,
                   let baseType = module.types.first(where: { $0.index == base }),
                   !accepted.contains(baseType.name) {
                    accepted.remove(type.name)
                    reasons[type.name] = "its base \(baseType.displayName) is not a Swift object"
                    changed = true
                }
            }
        }
        for type in module.types where type.isClass && !accepted.contains(type.name) {
            notes.append("CLASS \(type.displayName) stays a runtime object: \(reasons[type.name] ?? "declined")")
        }
        return (accepted, notes)
    }

    static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) }
    }

    /// Accepted classes with every base before its subclasses.
    static func dependencyOrder(_ accepted: Set<String>, in module: BIRModule) -> [BIRCompositeType] {
        var ordered: [BIRCompositeType] = []
        var placed = Set<String>()
        func place(_ type: BIRCompositeType) {
            guard accepted.contains(type.name), !placed.contains(type.name) else { return }
            if let base = type.base, let baseType = module.types.first(where: { $0.index == base }) { place(baseType) }
            placed.insert(type.name)
            ordered.append(type)
        }
        for type in module.types where type.isClass { place(type) }
        return ordered
    }

    // MARK: - Layout

    /// Field storage: size and alignment, Swift's natural layout.
    static func storage(of type: BIRType) -> (size: Int, alignment: Int) {
        type == .boolean ? (1, 1) : (8, 8)
    }

    static func layout(_ composite: BIRCompositeType, in module: BIRModule, bases: [String: ClassLayout], ordinal: Int) -> ClassLayout {
        let mangled = try! SwiftMangling.mangleClass(module: module.name, name: composite.displayName)
        let baseLayout = composite.base.flatMap { index in
            module.types.first { $0.index == index }.flatMap { bases[$0.name] }
        }
        let superclass: SwiftClassMetadata.Superclass
        if let baseLayout {
            superclass = SwiftClassMetadata.Superclass(
                module: module.name, name: baseLayout.composite.displayName,
                immediateMembers: (try? baseLayout.metadata.slots()) ?? [],
                instanceSize: baseLayout.instanceSize
            )
        } else {
            superclass = SwiftObjectLowering.basicObject
        }
        let inheritedCount = baseLayout?.composite.fields.count ?? 0
        let ownFields = composite.fields.dropFirst(inheritedCount)
        let stored = ownFields.map { field -> SwiftClassMetadata.StoredProperty in
            let (size, alignment) = storage(of: field.type)
            return .init(name: field.displayName, size: size, alignment: alignment)
        }

        // Swift-visible methods: a Swift identifier, a signature whose
        // mangling is verified, and not the constructor.
        let prefix = composite.name + "."
        var visible: [(name: String, symbol: String, function: BIRFunction)] = []
        var overrides: [SwiftClassMetadata.Override] = [
            .init(baseMethodDescriptor: SwiftObjectLowering.basicObjectInitDescriptor,
                  implementation: try! SwiftMangling.mangleInitializer(module: module.name, className: composite.displayName, allocating: true),
                  slot: 0),
        ]
        var newMethods: [SwiftClassMetadata.Method] = []
        for function in module.functions where function.name.hasPrefix(prefix) {
            let basicName = String(function.name.dropFirst(prefix.count))
            guard basicName != "NEW", isIdentifier(basicName) else { continue }
            let parameters = function.parameters.dropFirst()
            guard parameters.allSatisfy({ $0.type == .number }),
                  function.returnType == .number || function.returnType == .void,
                  let symbol = try? SwiftMangling.mangleMethod(
                    module: module.name, className: composite.displayName, method: basicName,
                    returns: function.returnType == .void ? .void : .number,
                    parameters: parameters.map { _ in .number })
            else { continue }
            visible.append((basicName, symbol, function))
            // An inherited visible method with the same name is overridden
            // in place; anything else is a new slot.
            if let baseLayout, let slot = baseLayout.methodSlots[basicName],
               let baseSymbol = baseLayout.visibleMethods.first(where: { $0.name == basicName })?.symbol {
                overrides.append(.init(baseMethodDescriptor: baseSymbol + "Tq", implementation: symbol, slot: slot))
            } else {
                newMethods.append(.init(name: basicName, implementation: symbol))
            }
        }
        let metadata = SwiftClassMetadata(
            module: module.name, name: composite.displayName, superclass: superclass,
            overrides: overrides, storedProperties: stored, methods: newMethods
        )
        // Slot bookkeeping: inherited slots keep their numbers; new methods
        // follow the own field offsets.
        var slots = baseLayout?.methodSlots ?? [:]
        var next = superclass.positiveSizeInWords - SwiftClassMetadata.headerSizeInWords + stored.count
        for method in newMethods {
            slots[method.name] = next
            next += 1
        }
        let offsets = (baseLayout?.fieldOffsets ?? []) + metadata.ownFieldOffsets
        return ClassLayout(
            composite: composite, mangled: mangled, base: baseLayout?.name,
            fieldOffsets: offsets, metadata: metadata,
            visibleMethods: visible, methodSlots: slots, ordinal: ordinal
        )
    }

    // MARK: - ObjectModel

    public func isSwiftObject(_ typeName: String) -> Bool { byName[typeName] != nil }

    public var symbols: ObjectSymbols {
        guard !classes.isEmpty else { return .runtime }
        return ObjectSymbols(
            copy: "\"obj.copy\"", assign: "\"obj.assign\"", release: "\"obj.release\"",
            typeIndex: "\"obj.typeIndex\"", text: "\"obj.text\"", print: "\"obj.print\"",
            box: "\"obj.box\"", unbox: "\"obj.unbox\""
        )
    }

    public func newSymbol(for typeName: String) -> String? {
        byName[typeName].map { "\($0.name).new" }
    }

    public func fieldGetSymbol(for typeName: String, field index: Int) -> String? {
        guard let layout = byName[typeName], layout.fieldOffsets.indices.contains(index) else { return nil }
        return "\(layout.name).get.\(index)"
    }

    public func fieldSetSymbol(for typeName: String, field index: Int) -> String? {
        guard let layout = byName[typeName], layout.fieldOffsets.indices.contains(index) else { return nil }
        return "\(layout.name).set.\(index)"
    }

    public var declarations: String {
        guard !classes.isEmpty else { return "" }
        let root = SwiftObjectLowering.basicObject
        let rootMangled = (try? SwiftMangling.mangleClass(module: root.module, name: root.name)) ?? ""
        var out = SwiftClassMetadata.preamble
        out += "declare void @swift_retain(ptr)\n"
        out += "declare void @swift_release(ptr)\n"
        out += "@\"\(rootMangled)N\" = external global %swift.type, align 8\n"
        out += "@\"\(rootMangled)Mm\" = external global %objc_class, align 8\n"
        out += "@\"\(rootMangled)Mn\" = external global %swift.type_descriptor, align 4\n"
        out += "@\"\(SwiftObjectLowering.basicObjectInitDescriptor)\" = external global %swift.method_descriptor, align 4\n"
        for slot in root.immediateMembers {
            if case .method(let symbol) = slot { out += "declare swiftcc ptr @\"\(symbol)\"(ptr swiftself)\n" }
        }
        return out
    }

    public func definitions(for module: BIRModule) -> String {
        guard !classes.isEmpty else { return "" }
        var out = "; ---- Rev 2: classes as Swift objects ----\n"
        var shared = Set<String>()
        var used: [String] = []
        for layout in classes {
            out += (try? layout.metadata.render(shared: &shared, emitUsed: false)) ?? ""
            used += (try? layout.metadata.usedSymbols) ?? []
            out += perClass(layout)
        }
        out += SwiftClassMetadata.usedDirective(used)
        out += helpers()
        return out
    }

    // MARK: - Per-class IR

    func perClass(_ layout: ClassLayout) -> String {
        let name = layout.name
        let fields = layout.composite.fields
        var out = ""

        // Field accessors, all fields, by index.
        for (index, field) in fields.enumerated() {
            let offset = layout.fieldOffsets[index]
            switch field.type {
            case .number:
                out += """
                define double @"\(name).get.\(index)"(ptr %o) {
                  %p = getelementptr inbounds i8, ptr %o, i64 \(offset)
                  %v = load double, ptr %p, align 8
                  ret double %v
                }
                define void @"\(name).set.\(index)"(ptr %o, double %v) {
                  %p = getelementptr inbounds i8, ptr %o, i64 \(offset)
                  store double %v, ptr %p, align 8
                  ret void
                }

                """
            case .boolean:
                out += """
                define i1 @"\(name).get.\(index)"(ptr %o) {
                  %p = getelementptr inbounds i8, ptr %o, i64 \(offset)
                  %b = load i8, ptr %p, align 1
                  %v = trunc i8 %b to i1
                  ret i1 %v
                }
                define void @"\(name).set.\(index)"(ptr %o, i1 %v) {
                  %p = getelementptr inbounds i8, ptr %o, i64 \(offset)
                  %b = zext i1 %v to i8
                  store i8 %b, ptr %p, align 1
                  ret void
                }

                """
            case .string:
                // Get is +1, as the runtime's is; set retains the new and
                // releases the old. A null pointer is the empty string.
                out += """
                define ptr @"\(name).get.\(index)"(ptr %o) {
                  %p = getelementptr inbounds i8, ptr %o, i64 \(offset)
                  %v = load ptr, ptr %p, align 8
                  %r = call ptr @"obj.retainString"(ptr %v)
                  ret ptr %r
                }
                define void @"\(name).set.\(index)"(ptr %o, ptr %v) {
                  %p = getelementptr inbounds i8, ptr %o, i64 \(offset)
                  %n = call ptr @"obj.retainString"(ptr %v)
                  %old = load ptr, ptr %p, align 8
                  store ptr %n, ptr %p, align 8
                  call void @basic_rt_string_release(ptr %old)
                  ret void
                }

                """
            case .composite(let held):
                // Get is borrowed, as the runtime's is (so `a.b.c = 1`
                // mutates in place); set stores a copy, as the runtime does.
                out += """
                define ptr @"\(name).get.\(index)"(ptr %o) {
                  %p = getelementptr inbounds i8, ptr %o, i64 \(offset)
                  %v = load ptr, ptr %p, align 8
                  ret ptr %v
                }
                define void @"\(name).set.\(index)"(ptr %o, ptr %v) {
                  %p = getelementptr inbounds i8, ptr %o, i64 \(offset)
                  %n = call ptr @"\(held).copy"(ptr %v)
                  %old = load ptr, ptr %p, align 8
                  store ptr %n, ptr %p, align 8
                  call void @"obj.release"(ptr %old)
                  ret void
                }

                """
            default:
                break
            }
        }

        // Loading from a runtime record: how defaults, unboxing and `NEW` all
        // get their field values — the runtime's, exactly.
        out += "define void @\"\(name).load\"(ptr %o, ptr %rt) {\n"
        for (index, field) in fields.enumerated() {
            switch field.type {
            case .number:
                out += "  %n\(index) = call double @basic_rt_composite_get_number(ptr %rt, i64 \(index))\n"
                out += "  call void @\"\(name).set.\(index)\"(ptr %o, double %n\(index))\n"
            case .boolean:
                out += "  %b\(index) = call i1 @basic_rt_composite_get_boolean(ptr %rt, i64 \(index))\n"
                out += "  call void @\"\(name).set.\(index)\"(ptr %o, i1 %b\(index))\n"
            case .string:
                out += "  %s\(index) = call ptr @basic_rt_composite_get_string(ptr %rt, i64 \(index))\n"
                out += "  call void @\"\(name).set.\(index)\"(ptr %o, ptr %s\(index))\n"
                out += "  call void @basic_rt_string_release(ptr %s\(index))\n"
            case .composite(let held):
                out += "  %c\(index) = call ptr @basic_rt_composite_get_composite(ptr %rt, i64 \(index))\n"
                out += "  %w\(index) = call ptr @\"\(held).fromRuntime\"(ptr %c\(index))\n"
                out += "  %p\(index) = getelementptr inbounds i8, ptr %o, i64 \(layout.fieldOffsets[index])\n"
                out += "  %old\(index) = load ptr, ptr %p\(index), align 8\n"
                out += "  store ptr %w\(index), ptr %p\(index), align 8\n"
                out += "  call void @\"obj.release\"(ptr %old\(index))\n"
            default:
                break
            }
        }
        out += "  ret void\n}\n"

        // Storing into a runtime record: the runtime's own copy semantics.
        out += "define ptr @\"\(name).toRuntime\"(ptr %o) {\n"
        out += "  %rt = call ptr @basic_rt_composite_new(i64 \(layout.typeIndex))\n"
        for (index, field) in fields.enumerated() {
            switch field.type {
            case .number:
                out += "  %n\(index) = call double @\"\(name).get.\(index)\"(ptr %o)\n"
                out += "  call void @basic_rt_composite_set_number(ptr %rt, i64 \(index), double %n\(index))\n"
            case .boolean:
                out += "  %b\(index) = call i1 @\"\(name).get.\(index)\"(ptr %o)\n"
                out += "  call void @basic_rt_composite_set_boolean(ptr %rt, i64 \(index), i1 %b\(index))\n"
            case .string:
                out += "  %s\(index) = call ptr @\"\(name).get.\(index)\"(ptr %o)\n"
                out += "  call void @basic_rt_composite_set_string(ptr %rt, i64 \(index), ptr %s\(index))\n"
                out += "  call void @basic_rt_string_release(ptr %s\(index))\n"
            case .composite(let held):
                out += "  %c\(index) = call ptr @\"\(name).get.\(index)\"(ptr %o)\n"
                out += "  %w\(index) = call ptr @\"\(held).toRuntime\"(ptr %c\(index))\n"
                out += "  call void @basic_rt_composite_set_composite(ptr %rt, i64 \(index), ptr %w\(index))\n"
                out += "  call void @basic_rt_composite_release(ptr %w\(index))\n"
            default:
                break
            }
        }
        out += "  ret ptr %rt\n}\n"

        let alloc = "call ptr @swift_allocObject(ptr @\"\(layout.mangled)N\", i64 \(layout.instanceSize), i64 7)"
        // Zero the *fields*, never the header. `swift_allocObject` has just
        // written the metadata pointer and refcount into the first sixteen
        // bytes; clearing from offset 0 wiped them, the object answered to
        // no class, and the runtime's copy dereferenced it as an RTComposite.
        let clear = """
          %fields = getelementptr inbounds i8, ptr %o, i64 16
          call void @llvm.memset.p0.i64(ptr %fields, i8 0, i64 \(layout.instanceSize - 16), i1 false)
        """
        let initializing = try! SwiftMangling.mangleInitializer(module: module.name, className: layout.composite.displayName, allocating: false)
        let allocating = try! SwiftMangling.mangleInitializer(module: module.name, className: layout.composite.displayName, allocating: true)
        let destroying = try! SwiftMangling.mangleDestructor(module: module.name, className: layout.composite.displayName, deallocating: false)
        let deallocating = try! SwiftMangling.mangleDestructor(module: module.name, className: layout.composite.displayName, deallocating: true)

        // A fresh instance starts as a zeroed allocation: every reference
        // field null, which the accessors above treat as empty.
        out += """
        define ptr @"\(name).fromRuntime"(ptr %rt) {
          %isnull = icmp eq ptr %rt, null
          br i1 %isnull, label %none, label %make
        make:
          %o = \(alloc)
        \(clear)
          call void @"\(name).load"(ptr %o, ptr %rt)
          ret ptr %o
        none:
          ret ptr null
        }
        define swiftcc ptr @"\(initializing)"(ptr swiftself %self) {
          %rt = call ptr @basic_rt_composite_new(i64 \(layout.typeIndex))
          call void @"\(name).load"(ptr %self, ptr %rt)
          call void @basic_rt_composite_release(ptr %rt)
          ret ptr %self
        }
        define swiftcc ptr @"\(allocating)"(ptr swiftself %type) {
          %o = call ptr @swift_allocObject(ptr %type, i64 \(layout.instanceSize), i64 7)
        \(clear)
          %r = call swiftcc ptr @"\(initializing)"(ptr swiftself %o)
          ret ptr %r
        }
        define ptr @"\(name).new"() {
          %r = call swiftcc ptr @"\(allocating)"(ptr swiftself @"\(layout.mangled)N")
          ret ptr %r
        }
        define ptr @"\(name).copy"(ptr %src) {
          %isnull = icmp eq ptr %src, null
          br i1 %isnull, label %none, label %make
        make:
          %o = \(alloc)
        \(clear)
          call void @"\(name).assign"(ptr %o, ptr %src)
          ret ptr %o
        none:
          ret ptr null
        }
        define void @"\(name).assign"(ptr %dst, ptr %src) {

        """
        for (index, field) in fields.enumerated() {
            let type: String
            switch field.type {
            case .number: type = "double"
            case .boolean: type = "i1"
            default: type = "ptr"
            }
            out += "  %v\(index) = call \(type) @\"\(name).get.\(index)\"(ptr %src)\n"
            out += "  call void @\"\(name).set.\(index)\"(ptr %dst, \(type) %v\(index))\n"
            if field.type == .string {
                // get was +1; set retained its own.
                out += "  call void @basic_rt_string_release(ptr %v\(index))\n"
            }
        }
        out += "  ret void\n}\n"

        // Teardown releases what the object owns.
        out += "define swiftcc ptr @\"\(destroying)\"(ptr swiftself %self) {\n"
        for (index, field) in fields.enumerated() {
            switch field.type {
            case .string:
                out += "  %s\(index)p = getelementptr inbounds i8, ptr %self, i64 \(layout.fieldOffsets[index])\n"
                out += "  %s\(index) = load ptr, ptr %s\(index)p, align 8\n"
                out += "  call void @basic_rt_string_release(ptr %s\(index))\n"
            case .composite:
                out += "  %c\(index)p = getelementptr inbounds i8, ptr %self, i64 \(layout.fieldOffsets[index])\n"
                out += "  %c\(index) = load ptr, ptr %c\(index)p, align 8\n"
                out += "  call void @\"obj.release\"(ptr %c\(index))\n"
            default:
                break
            }
        }
        out += "  ret ptr %self\n}\n"
        out += """
        define swiftcc void @"\(deallocating)"(ptr swiftself %self) {
          %o = call swiftcc ptr @"\(destroying)"(ptr swiftself %self)
          call void @swift_deallocClassInstance(ptr %o, i64 \(layout.instanceSize), i64 7)
          ret void
        }

        """

        // Thunks: the Swift ABI over Rev 1's `F.*` functions, so a Swift
        // caller (or subclass) reaches the body BASIC wrote. The receiver is
        // passed straight through — a Swift caller expects reference
        // semantics, and gets them.
        for method in layout.visibleMethods {
            let function = "F.\(method.function.name)"
            if method.function.returnType == .void {
                out += """
                define swiftcc void @"\(method.symbol)"(double %a, ptr swiftself %self) {
                  call void @"\(function)"(ptr %self, double %a)
                  ret void
                }

                """
            } else {
                out += """
                define swiftcc double @"\(method.symbol)"(ptr swiftself %self) {
                  %r = call double @"\(function)"(ptr %self)
                  ret double %r
                }

                """
            }
        }
        return out
    }

    // MARK: - Module helpers

    /// The whole-object operations that decide representation at run time.
    func helpers() -> String {
        var out = """
        declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)

        ; A string reference, retained; null is the empty string and stays null.
        define ptr @"obj.retainString"(ptr %s) {
          %isnull = icmp eq ptr %s, null
          br i1 %isnull, label %done, label %keep
        keep:
          call void @basic_rt_string_retain(ptr %s)
          br label %done
        done:
          ret ptr %s
        }

        ; Which of this module's classes an object is, walking the metadata
        ; chain from its dynamic type — so an instance of a Swift subclass
        ; answers with its nearest BASIC ancestor. -1 for the runtime's records.
        define i64 @"obj.classOf"(ptr %o) {
        entry:
          %isnull = icmp eq ptr %o, null
          br i1 %isnull, label %none, label %start
        start:
          %isa0 = load ptr, ptr %o, align 8
          br label %loop
        loop:
          %isa = phi ptr [ %isa0, %start ], [ %next, %step ]
          %end = icmp eq ptr %isa, null
          br i1 %end, label %none, label %check0

        """
        for (k, layout) in classes.enumerated() {
            out += "check\(k):\n"
            out += "  %eq\(k) = icmp eq ptr %isa, @\"\(layout.mangled)N\"\n"
            out += "  br i1 %eq\(k), label %found\(k), label %check\(k + 1)\n"
        }
        out += "check\(classes.count):\n  br label %step\n"
        out += "step:\n  %superp = getelementptr inbounds i8, ptr %isa, i64 8\n  %next = load ptr, ptr %superp, align 8\n  br label %loop\n"
        for k in classes.indices { out += "found\(k):\n  ret i64 \(k)\n" }
        out += "none:\n  ret i64 -1\n}\n\n"

        /// A dispatcher: switch on classOf, one arm per class, runtime default.
        func dispatcher(_ name: String, signature: String, arguments: String, subject: String, arm: (ClassLayout) -> String, fallback: String) -> String {
            var text = "define \(signature) @\"obj.\(name)\"(\(arguments)) {\n"
            text += "  %k = call i64 @\"obj.classOf\"(ptr \(subject))\n"
            text += "  switch i64 %k, label %rt [ " + classes.enumerated().map { "i64 \($0.offset), label %c\($0.offset)" }.joined(separator: " ") + " ]\n"
            for (k, layout) in classes.enumerated() {
                text += "c\(k):\n" + arm(layout)
            }
            text += "rt:\n" + fallback + "}\n\n"
            return text
        }

        out += dispatcher("copy", signature: "ptr", arguments: "ptr %o", subject: "%o",
            arm: { "  %r\($0.ordinal) = call ptr @\"\($0.name).copy\"(ptr %o)\n  ret ptr %r\($0.ordinal)\n" },
            fallback: "  %r = call ptr @basic_rt_composite_copy(ptr %o)\n  ret ptr %r\n")
        out += dispatcher("assign", signature: "void", arguments: "ptr %dst, ptr %src", subject: "%dst",
            arm: { "  call void @\"\($0.name).assign\"(ptr %dst, ptr %src)\n  ret void\n" },
            fallback: "  call void @basic_rt_composite_assign(ptr %dst, ptr %src)\n  ret void\n")
        out += dispatcher("release", signature: "void", arguments: "ptr %o", subject: "%o",
            arm: { _ in "  call void @swift_release(ptr %o)\n  ret void\n" },
            fallback: "  call void @basic_rt_composite_release(ptr %o)\n  ret void\n")
        out += dispatcher("typeIndex", signature: "i64", arguments: "ptr %o", subject: "%o",
            arm: { "  ret i64 \($0.typeIndex)\n" },
            fallback: "  %r = call i64 @basic_rt_composite_type(ptr %o)\n  ret i64 %r\n")
        out += dispatcher("text", signature: "ptr", arguments: "ptr %o", subject: "%o",
            arm: { "  %t\($0.ordinal) = call ptr @\"\($0.name).toRuntime\"(ptr %o)\n  %s\($0.ordinal) = call ptr @basic_rt_composite_text(ptr %t\($0.ordinal))\n  call void @basic_rt_composite_release(ptr %t\($0.ordinal))\n  ret ptr %s\($0.ordinal)\n" },
            fallback: "  %r = call ptr @basic_rt_composite_text(ptr %o)\n  ret ptr %r\n")
        out += dispatcher("print", signature: "void", arguments: "ptr %o", subject: "%o",
            arm: { "  %t\($0.ordinal) = call ptr @\"\($0.name).toRuntime\"(ptr %o)\n  call void @basic_rt_print_composite(ptr %t\($0.ordinal))\n  call void @basic_rt_composite_release(ptr %t\($0.ordinal))\n  ret void\n" },
            fallback: "  call void @basic_rt_print_composite(ptr %o)\n  ret void\n")
        out += dispatcher("box", signature: "ptr", arguments: "ptr %o", subject: "%o",
            arm: { "  %t\($0.ordinal) = call ptr @\"\($0.name).toRuntime\"(ptr %o)\n  %b\($0.ordinal) = call ptr @basic_rt_value_from_composite(ptr %t\($0.ordinal))\n  call void @basic_rt_composite_release(ptr %t\($0.ordinal))\n  ret ptr %b\($0.ordinal)\n" },
            fallback: "  %r = call ptr @basic_rt_value_from_composite(ptr %o)\n  ret ptr %r\n")

        // Unboxing dispatches on the *requested* type index, which is a
        // constant at every call site: the runtime coerces and copies as it
        // always did, and the copy is converted when the type is ours.
        out += "define ptr @\"obj.unbox\"(ptr %box, i64 %index, ptr %name) {\n"
        out += "  %rt = call ptr @basic_rt_value_composite(ptr %box, i64 %index, ptr %name)\n"
        out += "  switch i64 %index, label %asis [ " + classes.map { "i64 \($0.typeIndex), label %u\($0.ordinal)" }.joined(separator: " ") + " ]\n"
        for layout in classes {
            out += "u\(layout.ordinal):\n"
            out += "  %o\(layout.ordinal) = call ptr @\"\(layout.name).fromRuntime\"(ptr %rt)\n"
            out += "  call void @basic_rt_composite_release(ptr %rt)\n"
            out += "  ret ptr %o\(layout.ordinal)\n"
        }
        out += "asis:\n  ret ptr %rt\n}\n"
        return out
    }
}
