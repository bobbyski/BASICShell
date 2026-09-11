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
        /// Byte offset of the pointer to this object's runtime record, when
        /// the class has container fields — inherited from the base when the
        /// base already has one, so a hierarchy shares a single record.
        public let sideOffset: Int?

        var name: String { composite.name }
        var instanceSize: Int { metadata.instanceSize }
        var typeIndex: Int { composite.index }
    }

    public let module: BIRModule
    /// Classes laid out as Swift objects, bases before subclasses.
    public let classes: [ClassLayout]
    /// Why each declined class was declined.
    public let notes: [String]
    /// Programs the Swift dialect will not compile, and why.
    ///
    /// These are not preferences. Each one is a shape that used to build and
    /// then crash: an imported object is the framework's, and the runtime's
    /// containers hold the runtime's own records, so a slot that is declared
    /// to hold one and actually holds the other is read as the wrong kind of
    /// thing on the first touch. Refusing at compile time is the difference
    /// between a message and a segfault.
    public let refusals: [Diagnostic]
    /// The program's name as a Swift module name.
    ///
    /// A `.bas` file may be called `class-containers.bas`, and a Swift module
    /// may not contain a hyphen — so the characters Swift refuses become
    /// underscores rather than the whole program losing its classes. Only the
    /// *symbol* names change; nothing a BASIC programmer types does.
    public static func swiftModuleName(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            out.unicodeScalars.append(CharacterSet.alphanumerics.contains(scalar) || scalar == "_" ? scalar : "_")
        }
        // A leading digit is legal in a file name and not in an identifier.
        if let first = out.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) { out = "m" + out }
        return out.isEmpty ? "program" : out
    }

    /// Imported frameworks, by module name (R4).
    public let imports: [String: SwiftAPI]

    private let byName: [String: ClassLayout]
    /// Imported classes, by normalized BASIC name.
    private let importedByName: [String: (module: String, api: SwiftAPI, klass: SwiftAPI.Class, type: BIRCompositeType)]

    /// Symbols `swiftc` says this module's classes have (R0.5). Empty when
    /// the probe could not run, which declines every class rather than
    /// emitting a name that might not link.
    public let probed: SwiftManglingProbe.Symbols

    /// Analyses `module` and lays out every class that qualifies.
    public init(module: BIRModule, imports: [String: SwiftAPI] = [:], probed: SwiftManglingProbe.Symbols = .init()) {
        self.probed = probed
        self.module = module
        self.imports = imports
        // An imported class is a Swift object by definition — it *is* the
        // framework's — and its layout is the framework's, not ours.
        var imported: [String: (module: String, api: SwiftAPI, klass: SwiftAPI.Class, type: BIRCompositeType)] = [:]
        for type in module.types {
            guard let moduleName = type.externalModule, let api = imports[moduleName],
                  let klass = api.classes.first(where: { $0.name.uppercased() == type.name })
            else { continue }
            imported[type.name] = (moduleName, api, klass, type)
        }
        self.importedByName = imported
        self.refusals = Self.refusals(module, imported: Set(imported.keys))
        var (accepted, notes) = Self.analyse(module)
        // A class whose symbols the probe did not report cannot be emitted:
        // its name would be a guess, and a guessed symbol either fails to
        // link or resolves to the wrong thing.
        for name in accepted where probed.classes[module.types.first { $0.name == name }?.displayName ?? name] == nil {
            accepted.remove(name)
            notes.append("CLASS \(module.types.first { $0.name == name }?.displayName ?? name) stays a runtime object: swiftc did not report a symbol for it")
        }
        self.notes = notes
        var layouts: [ClassLayout] = []
        var byName: [String: ClassLayout] = [:]
        // Bases first: a subclass's layout starts where its base's ends.
        for composite in Self.dependencyOrder(accepted, in: module) where composite.externalModule == nil {
            let layout = Self.layout(composite, in: module, bases: byName, ordinal: layouts.count, probed: probed)
            layouts.append(layout)
            byName[composite.name] = layout
        }
        self.classes = layouts
        self.byName = byName
    }

    /// Where an imported Swift object would be stored in a runtime slot.
    ///
    /// The runtime's arrays, records and object fields hold `RTComposite`s.
    /// An imported class is a real Swift object laid out by the framework,
    /// and there is no conversion between the two — so a declaration that
    /// puts one where the other is expected is refused by name rather than
    /// compiled into a program that dies on the first access.
    static func refusals(_ module: BIRModule, imported: Set<String>) -> [Diagnostic] {
        guard !imported.isEmpty else { return [] }
        var out: [Diagnostic] = []
        func display(_ name: String) -> String {
            module.types.first { $0.name == name }?.displayName ?? name
        }
        func refuse(_ what: String, _ held: String) {
            out.append(Diagnostic(
                severity: .error, file: nil, line: nil,
                message: "\(what) cannot hold an imported \(display(held)): a \(display(held)) is \(module.types.first { $0.name == held }?.externalModule ?? "the framework")'s own object, and BASIC's arrays and records hold BASIC's records. Hold it in a plain variable, or pass it straight to the call that wants it"
            ))
        }
        func check(_ type: BIRType, rank: Int?, _ what: String) {
            if rank != nil, case .composite(let held) = type, imported.contains(held) { refuse(what, held) }
            if case .array(let element, _) = type, case .composite(let held) = element, imported.contains(held) { refuse(what, held) }
        }
        for variable in module.globals {
            check(variable.type, rank: variable.rank, "the array \(variable.name)")
        }
        for function in [module.main] + module.functions {
            for variable in function.locals + function.parameters {
                check(variable.type, rank: variable.rank, "the array \(variable.name)")
            }
        }
        for type in module.types where type.externalModule == nil {
            for field in type.fields {
                check(field.type, rank: field.dimensions.isEmpty ? nil : field.dimensions.count,
                      "the array \(type.displayName).\(field.displayName)")
                if field.dimensions.isEmpty, case .composite(let held) = field.type, imported.contains(held) {
                    refuse("the field \(type.displayName).\(field.displayName)", held)
                }
            }
        }
        return out
    }

    /// Asks `swiftc` for the symbols this module's classes will have.
    ///
    /// The shapes declared to the probe are the shapes about to be emitted:
    /// the same classes, the same bases, the same stored properties and the
    /// same method signatures. Anything the analysis would decline is left
    /// out, so a program pays only for the classes it gets.
    public static func probe(_ module: BIRModule) throws -> SwiftManglingProbe.Symbols {
        let (accepted, _) = analyse(module)
        let byIndex = Dictionary(uniqueKeysWithValues: module.types.map { ($0.index, $0) })
        var declarations: [SwiftManglingProbe.Declaration] = []
        for composite in dependencyOrder(accepted, in: module) where composite.externalModule == nil {
            let base = composite.base.flatMap { byIndex[$0] }
            // **No properties.** A stored property changes a class's layout,
            // which is ours to compute, and changes no symbol's *name* —
            // and BASIC allows names Swift does not (`Tag$`), which made the
            // probe fail to compile and take every class down with it.
            let prefix = composite.name + "."
            var methods: [(name: String, parameters: [String], returns: String?)] = []
            for function in module.functions where function.name.hasPrefix(prefix) {
                let basicName = String(function.name.dropFirst(prefix.count))
                guard basicName != "NEW", isIdentifier(basicName) else { continue }
                let parameters = function.parameters.dropFirst().compactMap { swiftSpelling($0.type, in: module) }
                guard parameters.count == function.parameters.count - 1 else { continue }
                guard function.returnType == .void || swiftSpelling(function.returnType, in: module) != nil else { continue }
                methods.append((basicName, parameters, function.returnType == .void ? nil : swiftSpelling(function.returnType, in: module)))
            }
            declarations.append(.init(
                name: composite.displayName,
                base: base.flatMap { accepted.contains($0.name) ? $0.displayName : nil },
                methods: methods
            ))
        }
        return try SwiftManglingProbe(module: swiftModuleName(module.name), declarations: declarations).run()
    }

    /// How a BASIC type is spelled in the probe, or nil when it has no Swift
    /// spelling and the member is left out.
    static func swiftSpelling(_ type: BIRType, in module: BIRModule) -> String? {
        switch type {
        case .number: return "Swift.Double"
        case .boolean: return "Swift.Bool"
        // R2.1: a BASIC string crosses as a `Swift.String`, converted at the
        // boundary. It is *not* `Swift.String` at rest, and that is a finding
        // rather than an omission — a BASIC string is bytes (`CHR$(0)` and
        // high bytes survive, which `strings-bytes.bas` pins), and
        // `Swift.String` cannot hold an arbitrary byte sequence losslessly.
        // Storing one at rest would either lose those programs or need a
        // second string type in the language; converting on access keeps the
        // oracle and still hands Swift a native string.
        case .string: return "Swift.String"
        case .composite(let name):
            guard let composite = module.types.first(where: { $0.name == name }), composite.isClass else { return nil }
            return composite.displayName
        default: return nil
        }
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
        // An imported class is the framework's object, laid out by the
        // framework; it never takes our layout, and a program class that
        // holds or inherits one is declined for now (R4.x).
        let external = Set(module.types.filter { $0.externalModule != nil }.map(\.name))

        var reasons: [String: String] = [:]
        for type in module.types where type.isClass && !external.contains(type.name) {
            if !Self.isIdentifier(type.displayName) {
                reasons[type.name] = "'\(type.displayName)' is not a Swift identifier"
            } else if (try? SwiftMangling.mangleClass(module: swiftModuleName(module.name), name: type.displayName)) == nil {
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
                        if isSwift, external.contains(held) {
                            accepted.remove(type.name)
                            reasons[type.name] = "its field \(field.displayName) holds an imported \(held), which the framework lays out (R4.x)"
                            changed = true
                        } else if isSwift, !accepted.contains(held) {
                            accepted.remove(type.name)
                            reasons[type.name] = "its field \(field.displayName) is a \(module.types.first { $0.name == held }?.displayName ?? held), which is not a Swift object"
                            changed = true
                        } else if !isSwift, accepted.contains(held) {
                            accepted.remove(held)
                            reasons[held] = "\(type.displayName).\(field.displayName) holds one, and \(type.displayName) is a runtime record"
                            changed = true
                        }
                    case .array, .dictionary, .variant:
                        // Kept by the runtime, not laid out here (R2.2, R2.3).
                        // The class holds a record and these fields live in
                        // it; see `sideOffset`.
                        continue
                    default:
                        if isSwift {
                            accepted.remove(type.name)
                            reasons[type.name] = "its field \(field.displayName) is \(field.type.name), which has no place in a Swift object yet"
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
        for type in module.types where type.isClass && !accepted.contains(type.name) && !external.contains(type.name) {
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

    /// Whether a field lives in the object's runtime record rather than in
    /// the object.
    ///
    /// Arrays, dictionaries and VARIANTs have ownership rules the runtime
    /// already implements exactly — an array field hands back the array
    /// *borrowed* so `a.items(1) = 2` mutates in place, while a VARIANT hands
    /// back an owned copy. Re-deriving that by hand is where a silent
    /// difference from the interpreter would come from, so these fields stay
    /// where their semantics already live and the object holds the record.
    static func livesInRuntimeRecord(_ type: BIRType) -> Bool {
        switch type {
        case .array, .dictionary, .variant, .system, .closure: return true
        default: return false
        }
    }

    static func layout(_ composite: BIRCompositeType, in module: BIRModule, bases: [String: ClassLayout], ordinal: Int, probed: SwiftManglingProbe.Symbols) -> ClassLayout {
        let mangled = probed.classes[composite.displayName]!
        let baseLayout = composite.base.flatMap { index in
            module.types.first { $0.index == index }.flatMap { bases[$0.name] }
        }
        let superclass: SwiftClassMetadata.Superclass
        if let baseLayout {
            superclass = SwiftClassMetadata.Superclass(
                module: swiftModuleName(module.name), name: baseLayout.composite.displayName,
                immediateMembers: (try? baseLayout.metadata.slots()) ?? [],
                instanceSize: baseLayout.instanceSize
            )
        } else {
            superclass = SwiftObjectLowering.basicObject
        }
        let inheritedCount = baseLayout?.composite.fields.count ?? 0
        let ownFields = Array(composite.fields.dropFirst(inheritedCount))
        // Only the fields the object actually holds get storage; the rest
        // live in the runtime record and are reached by BIR field index.
        let stored = ownFields.filter { !livesInRuntimeRecord($0.type) }.map { field -> SwiftClassMetadata.StoredProperty in
            let (size, alignment) = storage(of: field.type)
            return .init(name: field.displayName, size: size, alignment: alignment)
        }

        // Swift-visible methods: a Swift identifier, a signature whose
        // mangling is verified, and not the constructor.
        let prefix = composite.name + "."
        var visible: [(name: String, symbol: String, function: BIRFunction)] = []
        var overrides: [SwiftClassMetadata.Override] = [
            .init(baseMethodDescriptor: SwiftObjectLowering.basicObjectInitDescriptor,
                  implementation: probed.member("init", of: composite.displayName) ?? (mangled + "ACycfC"),
                  slot: 0),
        ]
        var newMethods: [SwiftClassMetadata.Method] = []
        for function in module.functions where function.name.hasPrefix(prefix) {
            let basicName = String(function.name.dropFirst(prefix.count))
            guard basicName != "NEW", isIdentifier(basicName) else { continue }
            // Any signature swiftc could spell, because swiftc spelled it:
            // the probe declared these shapes and reported the names.
            guard let symbol = probed.member(basicName, of: composite.displayName) else { continue }
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
        var metadata = SwiftClassMetadata(
            module: swiftModuleName(module.name), name: composite.displayName, superclass: superclass,
            overrides: overrides, storedProperties: stored, methods: newMethods
        )
        // One record per hierarchy: a subclass inherits the base's pointer
        // rather than allocating a second one, so an inherited container
        // field and an added one land in the same place.
        let needsRecord = composite.fields.contains { livesInRuntimeRecord($0.type) }
        let sideOffset: Int?
        if let inherited = baseLayout?.sideOffset {
            sideOffset = inherited
        } else if needsRecord {
            metadata.hiddenTrailingBytes = 8
            sideOffset = metadata.hiddenTrailingOffset
        } else {
            sideOffset = nil
        }
        // Slot bookkeeping: inherited slots keep their numbers; new methods
        // follow the own field offsets.
        var slots = baseLayout?.methodSlots ?? [:]
        var next = superclass.positiveSizeInWords - SwiftClassMetadata.headerSizeInWords + stored.count
        for method in newMethods {
            slots[method.name] = next
            next += 1
        }
        // One entry per BIR field, in BIR's order, so `fieldOffsets[i]`
        // answers for field `i`. A field kept by the runtime has no offset
        // in the object and holds -1.
        var ownOffsets: [Int] = []
        var placed = metadata.ownFieldOffsets.makeIterator()
        for field in ownFields {
            ownOffsets.append(livesInRuntimeRecord(field.type) ? -1 : (placed.next() ?? -1))
        }
        let offsets = (baseLayout?.fieldOffsets ?? []) + ownOffsets
        return ClassLayout(
            composite: composite, mangled: mangled, base: baseLayout?.name,
            fieldOffsets: offsets, metadata: metadata,
            visibleMethods: visible, methodSlots: slots, ordinal: ordinal,
            sideOffset: sideOffset
        )
    }

    // MARK: - ObjectModel

    public func isSwiftObject(_ typeName: String) -> Bool {
        byName[typeName] != nil || importedByName[typeName] != nil
    }

    /// Whether anything in this program is a Swift object at all.
    var hasSwiftObjects: Bool { !classes.isEmpty || !importedByName.isEmpty }

    public var symbols: ObjectSymbols {
        guard hasSwiftObjects else { return .runtime }
        return ObjectSymbols(
            copy: "\"obj.copy\"", assign: "\"obj.assign\"", release: "\"obj.release\"",
            typeIndex: "\"obj.typeIndex\"", text: "\"obj.text\"", print: "\"obj.print\"",
            box: "\"obj.box\"", unbox: "\"obj.unbox\""
        )
    }

    public func newSymbol(for typeName: String) -> String? {
        if byName[typeName] != nil { return "\(typeName).new" }
        // An imported class with a no-argument initializer.
        if let entry = importedByName[typeName], entry.klass.initializers.contains(where: { $0.parameters.isEmpty }) {
            return "\(typeName).new"
        }
        return nil
    }

    public func constructSymbol(for typeName: String, arguments: [BIRType]) -> String? {
        // Matched on the arity BASIC *passes*, not on Swift's parameter
        // count: a struct arrives flattened and a defaulted parameter is not
        // passed at all, so `Window.init(frame: Rect)` is four arguments here
        // and one there.
        guard let entry = importedByName[typeName],
              entry.klass.initializers.contains(where: {
                  Self.basicArity($0, in: entry.api) == arguments.count
              })
        else { return nil }
        return "\(typeName).new.\(arguments.count)"
    }

    public func runtimeRecordSymbol(for typeName: String) -> String? {
        guard let layout = byName[typeName], layout.sideOffset != nil else { return nil }
        return "\(layout.name).record"
    }

    public func fieldLivesInRuntimeRecord(_ typeName: String, field index: Int) -> Bool {
        guard let layout = byName[typeName], layout.composite.fields.indices.contains(index) else { return false }
        return Self.livesInRuntimeRecord(layout.composite.fields[index].type)
    }

    public func fieldGetSymbol(for typeName: String, field index: Int) -> String? {
        if let layout = byName[typeName], layout.fieldOffsets.indices.contains(index),
           layout.fieldOffsets[index] >= 0 { return "\(layout.name).get.\(index)" }
        // An imported class's storage is the framework's: reached through its
        // property accessors, never by an offset we computed.
        if let entry = importedByName[typeName], entry.type.fields.indices.contains(index) { return "\(typeName).get.\(index)" }
        return nil
    }

    public func fieldSetSymbol(for typeName: String, field index: Int) -> String? {
        if let layout = byName[typeName], layout.fieldOffsets.indices.contains(index),
           layout.fieldOffsets[index] >= 0 { return "\(layout.name).set.\(index)" }
        if let entry = importedByName[typeName], entry.type.fields.indices.contains(index),
           Self.property(named: entry.type.fields[index].name, of: entry.klass, in: entry.api)?.isSettable == true {
            return "\(typeName).set.\(index)"
        }
        return nil
    }

    /// The `declare`s for the value bridge — strings in and out, and the
    /// error raiser. Emitted once for the module: LLVM refuses a second
    /// declaration of the same name, and both the class path and the import
    /// path need these.
    static let bridgeDeclarations = """
    declare swiftcc { i64, ptr } @basic_rt_swift_string_in(ptr)
    declare swiftcc ptr @basic_rt_swift_string_out(i64, ptr)
    declare swiftcc ptr @basic_rt_swift_error_current()
    declare swiftcc void @basic_rt_swift_error_raise(ptr)
    declare void @basic_rt_closure_invoke_void(ptr)

    """

    public var declarations: String {
        // The bridge belongs to whichever path is present; when both are, it
        // is emitted here and the import path leaves it alone.
        guard hasSwiftObjects || !importedByName.isEmpty else { return "" }
        guard hasSwiftObjects else { return Self.bridgeDeclarations }
        let root = SwiftObjectLowering.basicObject
        let rootMangled = (try? SwiftMangling.mangleClass(module: root.module, name: root.name)) ?? ""
        var out = SwiftClassMetadata.preamble
        out += "declare void @swift_retain(ptr)\n"
        out += "declare void @swift_release(ptr)\n"
        // Values crossing to and from Swift (R2.1, R4.6).
        out += Self.bridgeDeclarations
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
        guard hasSwiftObjects else { return "" }
        var out = "; ---- Rev 2: classes as Swift objects ----\n"
        var shared = Set<String>()
        var used: [String] = []
        for layout in classes {
            out += (try? layout.metadata.render(shared: &shared, emitUsed: false)) ?? ""
            used += (try? layout.metadata.usedSymbols) ?? []
            out += perClass(layout)
        }
        out += SwiftClassMetadata.usedDirective(used)
        out += importedDeclarations()
        for name in importedByName.keys.sorted() { out += perImportedClass(importedByName[name]!) }
        for key in imports.keys.sorted() { out += perImportedEnumMembers(imports[key]!) }
        out += helpers()
        return out
    }

    // MARK: - Imported classes (R4)

    /// `declare`s for every framework symbol this module calls.
    func importedDeclarations() -> String {
        guard !importedByName.isEmpty else { return "" }
        // The bridge itself is declared by `declarations`, which runs for a
        // module with imports whether or not it also has classes of its own.
        var out = "; ---- imported Swift frameworks ----\n"
        var seen = Set<String>()
        for (_, entry) in importedByName.sorted(by: { $0.key < $1.key }) {
            out += "@\"\(entry.klass.symbol)N\" = external global %swift.type, align 8\n"
            for initializer in entry.klass.initializers where seen.insert(initializer.allocatingSymbol).inserted {
                let parameters = initializer.passed.map { Self.abiType($0.type) } + ["ptr swiftself"]
                out += "declare swiftcc ptr @\"\(initializer.allocatingSymbol)\"(\(parameters.joined(separator: ", ")))\n"
            }
            for initializer in entry.klass.initializers
            where Self.needsInitializerShim(initializer)
                && seen.insert("newshim.\(entry.klass.name).\(Self.basicArity(initializer, in: entry.api))").inserted {
                let parameters = initializer.passed.flatMap { parameter -> [String] in
                    if case .structure = parameter.type {
                        return (entry.api.leaves(of: parameter.type) ?? []).map { Self.shimAbiType($0) }
                    }
                    return [Self.shimAbiType(parameter.type)]
                }
                out += "declare ptr @basic_new_\(entry.klass.name)_\(Self.basicArity(initializer, in: entry.api))(\(parameters.joined(separator: ", ")))\n"
            }
            for method in entry.klass.methods where Self.needsShim(method) && seen.insert("shim." + method.symbol).inserted {
                // The shim's C entry point, not the async symbol: an async
                // function cannot be called directly from here (R3.3).
                let shim = Self.shimSymbol(method, of: entry.klass.name)
                // A struct crosses as its scalars, so it contributes several
                // parameters rather than one.
                let parameters = ["ptr"] + method.passed.flatMap { parameter -> [String] in
                    if case .structure = parameter.type {
                        return (entry.api.leaves(of: parameter.type) ?? []).map { Self.shimAbiType($0) }
                    }
                    return [Self.shimAbiType(parameter.type)]
                }
                out += "declare \(Self.shimAbiReturn(method.returns)) @\(shim)(\((parameters + (Self.returnsPayload(method) ? ["i64"] : [])).joined(separator: ", ")))\n"
            }
            for method in entry.klass.methods where !Self.needsShim(method) && seen.insert(method.symbol).inserted {
                // A `throws` method takes a hidden `swifterror` pointer; the
                // callee stores the thrown error through it and returns
                // normally, so a caller that omits it hands the callee a
                // register full of whatever was there.
                let parameters = method.passed.map { Self.abiType($0.type) } + ["ptr swiftself"]
                    + (method.isThrowing ? ["ptr swifterror"] : [])
                out += "declare swiftcc \(Self.abiReturn(method.returns)) @\"\(method.symbol)\"(\(parameters.joined(separator: ", ")))\n"
            }
            for property in entry.klass.properties {
                // Through the shim, not Swift's accessor (E2): the accessor
                // hands back the enum in Swift's own layout.
                if case .payloadEnumeration = property.type {
                    // A record each way (E4); the getter also takes the
                    // record's type index, for the same reason a result does.
                    let getter = "basic_get_\(entry.klass.name)_\(property.name)"
                    if seen.insert(getter).inserted { out += "declare ptr @\"\(getter)\"(ptr, i64)\n" }
                    let setter = "basic_set_\(entry.klass.name)_\(property.name)"
                    if property.isSettable, seen.insert(setter).inserted { out += "declare void @\"\(setter)\"(ptr, ptr)\n" }
                    continue
                }
                if case .enumeration = property.type {
                    let getter = "basic_get_\(entry.klass.name)_\(property.name)"
                    if seen.insert(getter).inserted { out += "declare i64 @\"\(getter)\"(ptr)\n" }
                    let setter = "basic_set_\(entry.klass.name)_\(property.name)"
                    if property.isSettable, seen.insert(setter).inserted { out += "declare void @\"\(setter)\"(ptr, i64)\n" }
                    continue
                }
                if seen.insert(property.getterSymbol).inserted {
                    out += "declare swiftcc \(Self.abiReturn(property.type)) @\"\(property.getterSymbol)\"(ptr swiftself)\n"
                }
                if property.isSettable, seen.insert(property.setterSymbol).inserted {
                    out += "declare swiftcc void @\"\(property.setterSymbol)\"(\(Self.abiType(property.type)), ptr swiftself)\n"
                }
            }
        }
        return out
    }

    /// How many arguments BASIC passes to a member: one per scalar, and one
    /// per leaf of any struct.
    static func basicArity(_ function: SwiftAPI.Function, in api: SwiftAPI) -> Int {
        function.passed.reduce(0) { total, parameter in
            if case .structure = parameter.type { return total + (api.leaves(of: parameter.type)?.count ?? 1) }
            return total + 1
        }
    }

    /// Whether a method is reached through a generated Swift shim rather
    /// than by a plain call: awaited methods (R3.3) and methods taking a
    /// handler (R4.5) are the two shapes emitted IR cannot call directly.
    /// Whether a constructor is reached through a generated shim.
    /// How many trailing parameters are defaulted objects or protocols, for
    /// which BASIC may pass NULL to mean "use Swift's default" (R5.1):
    /// `NEW App(D, NULL)` takes the real clock `App` would have chosen.
    static func defaultedPointerSuffix(_ function: SwiftAPI.Function) -> Int {
        var count = 0
        for parameter in function.passed.reversed() {
            guard parameter.hasDefault else { break }
            switch parameter.type {
            case .object, .protocolType: count += 1
            default: return count
            }
        }
        return count
    }

    static func needsInitializerShim(_ initializer: SwiftAPI.Function) -> Bool {
        defaultedPointerSuffix(initializer) > 0 || initializer.passed.count != initializer.parameters.count || initializer.passed.contains {
            switch $0.type {
            case .structure, .protocolType, .voidClosure, .array, .enumeration, .payloadEnumeration, .duration: return true
            default: return false
            }
        }
    }

    static func needsShim(_ method: SwiftAPI.Function) -> Bool {
        // Anything emitted IR cannot call directly, or whose argument list
        // differs from what Swift declared because a defaulted parameter is
        // being left out.
        if case .array = method.returns { return true }
        if case .enumeration = method.returns { return true }
        if case .payloadEnumeration = method.returns { return true }
        if method.returns == .duration { return true }
        return method.isAsync || method.passed.count != method.parameters.count || method.passed.contains {
            switch $0.type {
            case .structure, .protocolType, .voidClosure, .array, .enumeration, .payloadEnumeration, .duration: return true
            default: return false
            }
        }
    }

    /// Whether a method hands back an enum whose cases carry values. Its
    /// shim takes the BASIC record's type index as a trailing argument (E4):
    /// the shim is compiled before any program, so it cannot know the index.
    static func returnsPayload(_ method: SwiftAPI.Function) -> Bool {
        if case .payloadEnumeration = method.returns { return true }
        return false
    }

    static func shimSymbol(_ method: SwiftAPI.Function, of className: String) -> String {
        (method.isAsync ? "basic_await_" : "basic_handler_") + "\(className)_\(method.name)"
    }

    /// A Swift value's ABI form at a call boundary. A `String` is two words.
    static func abiType(_ type: SwiftAPI.ValueType) -> String {
        switch type {
        case .double: return "double"
        case .int: return "i64"
        case .bool: return "i1"
        // An ordinal; the shim turns it into the case (E2).
        case .enumeration: return "i64"
        // The runtime's record; the shim reads it case by case (E4).
        case .payloadEnumeration: return "ptr"
        // Milliseconds as a number; the shim makes the Duration (R5.1).
        case .duration: return "double"
        case .string: return "i64, ptr"
        case .voidClosure: return "ptr, ptr"
        // Never reached: a struct parameter is expanded into its scalars
        // before anything asks for its ABI, because how many words it takes
        // is a property of the struct rather than of the case.
        case .structure, .protocolType: return "ptr"
        // The runtime's boxed value, holding the array. Always through a
        // shim, which walks it through the bridge.
        case .array: return "ptr"
        case .object, .void, .unsupported: return "ptr"
        }
    }

    /// A value's form in a *shim's* C signature: Swift's form, except that a
    /// String is the runtime's own pointer. `@_cdecl` bridges `Swift.String`
    /// to one `NSString*`, and passing Swift's two words to that — or reading
    /// two back — is what crashed the first shim that returned a String.
    static func shimAbiType(_ type: SwiftAPI.ValueType) -> String {
        type == .string ? "ptr" : abiType(type)
    }

    static func shimAbiReturn(_ type: SwiftAPI.ValueType) -> String {
        type == .string ? "ptr" : abiReturn(type)
    }

    static func abiReturn(_ type: SwiftAPI.ValueType) -> String {
        switch type {
        case .double: return "double"
        case .int: return "i64"
        case .bool: return "i1"
        case .enumeration: return "i64"
        case .payloadEnumeration: return "ptr"
        case .duration: return "double"
        case .string: return "{ i64, ptr }"
        case .void: return "void"
        // Never a result: a method *returning* a closure is skipped by the
        // reader, so reaching here would be a bug rather than a shape.
        case .object, .voidClosure, .structure, .protocolType, .array, .unsupported: return "ptr"
        }
    }

    /// A property of an imported class or of any class above it.
    ///
    /// BIR gives a class *all* its fields, inherited first, so field 0 of a
    /// subclass is usually the base's — and the accessor for it lives on the
    /// base. Looking only at the class's own properties left the emitter
    /// calling an accessor nothing defined.
    static func property(named name: String, of klass: SwiftAPI.Class, in api: SwiftAPI) -> SwiftAPI.Property? {
        var current: SwiftAPI.Class? = klass
        while let here = current {
            if let match = here.properties.first(where: { $0.name.uppercased() == name }) { return match }
            current = here.superclassPrecise.flatMap { api.class(precise: $0) }
        }
        return nil
    }

    /// A method of an imported class or of any class above it.
    /// The class that declares a property — a subclass inherits it, but the
    /// shim for an enum-typed one is generated once, for its declarer.
    static func propertyOwner(named name: String, of klass: SwiftAPI.Class, in api: SwiftAPI) -> SwiftAPI.Class? {
        var current: SwiftAPI.Class? = klass
        while let here = current {
            if here.properties.contains(where: { $0.name.uppercased() == name.uppercased() }) { return here }
            current = here.superclassPrecise.flatMap { api.class(precise: $0) }
        }
        return nil
    }

    static func method(named name: String, of klass: SwiftAPI.Class, in api: SwiftAPI) -> SwiftAPI.Function? {
        var current: SwiftAPI.Class? = klass
        while let here = current {
            if let match = here.methods.first(where: { $0.name.uppercased() == name }) { return match }
            current = here.superclassPrecise.flatMap { api.class(precise: $0) }
        }
        return nil
    }

    /// Thunks over an imported class: BASIC's calling convention on the
    /// outside, Swift's on the inside, with values converted where they cross
    /// (ruling R2.0).
    /// A BIR type's LLVM form in a thunk's signature.
    static func llvmBasicType(_ type: BIRType) -> String {
        switch type {
        case .number: return "double"
        case .boolean: return "i1"
        case .void: return "void"
        default: return "ptr"
        }
    }

    /// Thunks for members declared on imported enums (E5): BASIC's call to
    /// the free function the interface declared for `B.inner`, onto the shim
    /// that turns the receiver into the Swift enum and calls the member. A
    /// VB-style value arrives as its ordinal, one with payloads as its record,
    /// and a static has no receiver at all.
    func perImportedEnumMembers(_ api: SwiftAPI) -> String {
        var out = ""
        for enumeration in api.enumerations.values.sorted(by: { $0.name < $1.name }) {
            let stem = enumeration.swiftName.replacingOccurrences(of: ".", with: "_")
            for (member, isStatic, _) in SwiftInterfaceUnit.members(of: enumeration) {
                let functionName = SwiftInterfaceUnit.enumMemberFunction(enum: enumeration.name, member: member.name).uppercased()
                guard let function = module.functions.first(where: { $0.name == functionName }) else { continue }
                var counter = 0
                func temp() -> String { counter += 1; return "%t\(counter)" }
                var body = ""
                let declared = function.parameters.enumerated().map { "\(Self.llvmBasicType($0.element.type)) %a\($0.offset)" }
                var passed: [String] = []
                var shimTypes: [String] = []
                var offset = 0
                if !isStatic {
                    if enumeration.isPayload {
                        passed.append("ptr %a0"); shimTypes.append("ptr")
                    } else {
                        let ordinal = temp()
                        body += "  \(ordinal) = fptosi double %a0 to i64\n"
                        passed.append("i64 \(ordinal)"); shimTypes.append("i64")
                    }
                    offset = 1
                }
                for (index, parameter) in member.passed.enumerated() {
                    let value = "%a\(index + offset)"
                    switch parameter.type {
                    case .int, .enumeration:
                        let whole = temp()
                        body += "  \(whole) = fptosi double \(value) to i64\n"
                        passed.append("i64 \(whole)"); shimTypes.append("i64")
                    case .double:
                        passed.append("double \(value)"); shimTypes.append("double")
                    case .bool:
                        passed.append("i1 \(value)"); shimTypes.append("i1")
                    default:
                        // A string stays the runtime's pointer, which the shim
                        // reads; an object or a record is a pointer anyway.
                        passed.append("ptr \(value)"); shimTypes.append("ptr")
                    }
                }
                if case .payloadEnumeration(let precise) = member.returns {
                    let index = module.types.first { $0.name == (api.enumerations[precise]?.name ?? "").uppercased() }?.index ?? -1
                    passed.append("i64 \(index)"); shimTypes.append("i64")
                }
                let shimReturn: String
                switch member.returns {
                case .void: shimReturn = "void"
                case .double: shimReturn = "double"
                case .bool: shimReturn = "i1"
                case .int, .enumeration: shimReturn = "i64"
                default: shimReturn = "ptr"
                }
                let shim = "basic_handler_\(stem)_\(member.name)"
                out += "declare \(shimReturn) @\"\(shim)\"(\(shimTypes.joined(separator: ", ")))\n"
                let call = "call \(shimReturn) @\"\(shim)\"(\(passed.joined(separator: ", ")))"
                let returnType = Self.llvmBasicType(function.returnType)
                if shimReturn == "void" {
                    out += "define void @\"F.\(functionName)\"(\(declared.joined(separator: ", "))) {\n\(body)  \(call)\n  ret void\n}\n"
                } else {
                    let raw = temp()
                    body += "  \(raw) = \(call)\n"
                    var value = raw
                    if shimReturn == "i64" {
                        let number = temp()
                        body += "  \(number) = sitofp i64 \(raw) to double\n"
                        value = number
                    }
                    out += "define \(returnType) @\"F.\(functionName)\"(\(declared.joined(separator: ", "))) {\n\(body)  ret \(returnType) \(value)\n}\n"
                }
            }
        }
        return out
    }

    func perImportedClass(_ entry: (module: String, api: SwiftAPI, klass: SwiftAPI.Class, type: BIRCompositeType)) -> String {
        let name = entry.type.name
        var out = "; \(entry.module).\(entry.klass.name), imported\n"
        var counter = 0
        func temp() -> String { counter += 1; return "%t\(counter)" }

        /// Converts a BASIC value to Swift's ABI form; returns the argument text.
        func toSwift(_ value: String, _ type: SwiftAPI.ValueType, into body: inout String) -> String {
            switch type {
            // An object pointer, handed straight through; the shim casts
            // it to the protocol.
            case .protocolType: return "ptr \(value)"
            case .structure: return "double \(value)"
            case .double, .duration: return "double \(value)"
            case .bool: return "i1 \(value)"
            case .int, .enumeration:
                let r = temp(); body += "  \(r) = fptosi double \(value) to i64\n"; return "i64 \(r)"
            case .string:
                let r = temp(); body += "  \(r) = call swiftcc { i64, ptr } @basic_rt_swift_string_in(ptr \(value))\n"
                let a = temp(); body += "  \(a) = extractvalue { i64, ptr } \(r), 0\n"
                let b = temp(); body += "  \(b) = extractvalue { i64, ptr } \(r), 1\n"
                return "i64 \(a), ptr \(b)"
            case .voidClosure:
                // The pair a Swift closure is made from here: a stable C
                // trampoline, and the BASIC closure it should invoke. The
                // closure is retained because the framework keeps it past
                // this call — an event handler outlives the statement that
                // installed it.
                body += "  call void @basic_rt_closure_retain(ptr \(value))\n"
                return "ptr @basic_rt_closure_invoke_void, ptr \(value)"
            case .array, .payloadEnumeration, .object, .void, .unsupported: return "ptr \(value)"
            }
        }
        /// Converts a Swift result back to BASIC's form.
        func fromSwift(_ value: String, _ type: SwiftAPI.ValueType, into body: inout String) -> String {
            switch type {
            case .double, .bool, .object, .void, .voidClosure, .structure, .protocolType, .array, .payloadEnumeration, .duration, .unsupported: return value
            case .int, .enumeration:
                let r = temp(); body += "  \(r) = sitofp i64 \(value) to double\n"; return r
            case .string:
                let a = temp(); body += "  \(a) = extractvalue { i64, ptr } \(value), 0\n"
                let b = temp(); body += "  \(b) = extractvalue { i64, ptr } \(value), 1\n"
                let r = temp(); body += "  \(r) = call swiftcc ptr @basic_rt_swift_string_out(i64 \(a), ptr \(b))\n"
                return r
            }
        }
        /// The runtime type index of a payload enum's BASIC record (E4), which
        /// the shim needs to build one and cannot know itself.
        func payloadTypeIndex(_ precise: String) -> Int {
            let name = (entry.api.enumerations[precise]?.name ?? "").uppercased()
            return module.types.first { $0.name == name }?.index ?? -1
        }
        /// A value for a call: Swift's form, or — when the call goes through
        /// a shim — the same except that a String stays the runtime's
        /// pointer, which the shim reads itself.
        func convert(_ value: String, _ type: SwiftAPI.ValueType, _ viaShim: Bool, into body: inout String) -> String {
            if viaShim, type == .string { return "ptr \(value)" }
            return toSwift(value, type, into: &body)
        }
        /// A member's parameter list as BASIC declares it, and the argument
        /// each one contributes.
        ///
        /// A struct is several BASIC numbers, not one value, so it expands
        /// here — declaring it as a single pointer is what made the emitted
        /// IR disagree with itself.
        func basicParameters(_ passed: [SwiftAPI.Parameter]) -> (declared: [String], slots: [[(String, SwiftAPI.ValueType)]]) {
            var declared: [String] = []
            var slots: [[(String, SwiftAPI.ValueType)]] = []
            for parameter in passed {
                // A leaf carries its own type: `Size` is two numbers but
                // `HeadlessDriver`'s flattened arguments include a boolean,
                // and assuming every leaf was a number produced IR that
                // disagreed with itself.
                if case .structure = parameter.type, let leaves = entry.api.leaves(of: parameter.type) {
                    var names: [(String, SwiftAPI.ValueType)] = []
                    for leaf in leaves {
                        let name = "%a\(declared.count)"
                        declared.append("\(basicType(leaf)) \(name)")
                        names.append((name, leaf))
                    }
                    slots.append(names)
                } else {
                    let name = "%a\(declared.count)"
                    declared.append("\(basicType(parameter.type)) \(name)")
                    slots.append([(name, parameter.type)])
                }
            }
            return (declared, slots)
        }

        func basicType(_ type: SwiftAPI.ValueType) -> String {
            switch type {
            case .double, .int, .enumeration, .duration: return "double"
            case .bool: return "i1"
            case .string, .object, .voidClosure, .structure, .protocolType, .array, .payloadEnumeration, .void, .unsupported: return "ptr"
            }
        }

        // Constructors. Only one shape per arity: BASIC has a single NEW per
        // class, the unit declares one, and two Swift initializers can
        // collapse onto the same one once defaulted parameters are dropped —
        // `ImageView` has two that both take one argument from BASIC.
        var emittedNew = Set<String>()
        for initializer in entry.klass.initializers
        where emittedNew.insert("\(name).new.\(Self.basicArity(initializer, in: entry.api))").inserted {
            counter = 0
            var body = ""
            var arguments: [String] = []
            let (parameters, slots) = basicParameters(initializer.passed)
            let viaShim = Self.needsInitializerShim(initializer)
            for (index, parameter) in initializer.passed.enumerated() {
                if case .structure = parameter.type {
                    // Each leaf goes across on its own; the shim rebuilds.
                    arguments += slots[index].map { convert($0.0, $0.1, viaShim, into: &body) }
                } else {
                    arguments.append(convert(slots[index][0].0, parameter.type, viaShim, into: &body))
                }
            }
            let arity0 = Self.basicArity(initializer, in: entry.api)
            let result = temp()
            if Self.needsInitializerShim(initializer) {
                // Through the shim, for the same reasons a method goes
                // through one: a protocol argument is an existential rather
                // than a pointer, and a struct arrives in pieces.
                body += "  \(result) = call ptr @basic_new_\(entry.klass.name)_\(arity0)(\(arguments.joined(separator: ", ")))\n"
            } else {
                arguments.append("ptr swiftself @\"\(entry.klass.symbol)N\"")
                body += "  \(result) = call swiftcc ptr @\"\(initializer.allocatingSymbol)\"(\(arguments.joined(separator: ", ")))\n"
            }
            // Keyed on the arity BASIC sees, which is the *flattened* one:
            // a `Size` parameter is two numbers there, and naming the symbol
            // after Swift's count made the call site ask for one that was
            // never defined.
            // Always `.new.<arity>`, including zero — the call site names it
            // from the argument count it has, and a special case for none
            // meant a no-argument NEW asked for a symbol nothing defined.
            let arity = Self.basicArity(initializer, in: entry.api)
            let symbol = "\(name).new.\(arity)"
            out += "define ptr @\"\(symbol)\"(\(parameters.joined(separator: ", "))) {\n\(body)  ret ptr \(result)\n}\n"
            // `NEW C` and `NEW C()` reach the emitter by different routes and
            // name the symbol differently; a no-argument constructor answers
            // to both.
            if arity == 0 {
                out += "define ptr @\"\(name).new\"() {\n  %r = call ptr @\"\(symbol)\"()\n  ret ptr %r\n}\n"
            }
        }

        // Property accessors, by BIR field index.
        for (index, field) in entry.type.fields.enumerated() {
            guard let property = Self.property(named: field.name, of: entry.klass, in: entry.api) else { continue }
            if case .payloadEnumeration(let precise) = property.type {
                let owner = Self.propertyOwner(named: field.name, of: entry.klass, in: entry.api)?.name ?? entry.klass.name
                out += "define ptr @\"\(name).get.\(index)\"(ptr %o) {\n"
                out += "  %r = call ptr @\"basic_get_\(owner)_\(property.name)\"(ptr %o, i64 \(payloadTypeIndex(precise)))\n  ret ptr %r\n}\n"
                if property.isSettable {
                    out += "define void @\"\(name).set.\(index)\"(ptr %o, ptr %v) {\n"
                    out += "  call void @\"basic_set_\(owner)_\(property.name)\"(ptr %o, ptr %v)\n  ret void\n}\n"
                }
                continue
            }
            if case .enumeration = property.type {
                // Named after the class that *declares* it, which is the one
                // the shim was generated for; a subclass reaches the same one.
                let owner = Self.propertyOwner(named: field.name, of: entry.klass, in: entry.api)?.name ?? entry.klass.name
                out += "define double @\"\(name).get.\(index)\"(ptr %o) {\n"
                out += "  %n = call i64 @\"basic_get_\(owner)_\(property.name)\"(ptr %o)\n"
                out += "  %d = sitofp i64 %n to double\n  ret double %d\n}\n"
                if property.isSettable {
                    out += "define void @\"\(name).set.\(index)\"(ptr %o, double %v) {\n"
                    out += "  %n = fptosi double %v to i64\n"
                    out += "  call void @\"basic_set_\(owner)_\(property.name)\"(ptr %o, i64 %n)\n  ret void\n}\n"
                }
                continue
            }
            counter = 0
            var body = ""
            let raw = temp()
            body += "  \(raw) = call swiftcc \(Self.abiReturn(property.type)) @\"\(property.getterSymbol)\"(ptr swiftself %o)\n"
            let value = fromSwift(raw, property.type, into: &body)
            out += "define \(basicType(property.type)) @\"\(name).get.\(index)\"(ptr %o) {\n\(body)  ret \(basicType(property.type)) \(value)\n}\n"
            if property.isSettable {
                counter = 0
                var setBody = ""
                let argument = toSwift("%v", property.type, into: &setBody)
                setBody += "  call swiftcc void @\"\(property.setterSymbol)\"(\(argument), ptr swiftself %o)\n"
                out += "define void @\"\(name).set.\(index)\"(ptr %o, \(basicType(property.type)) %v) {\n\(setBody)  ret void\n}\n"
            }
        }

        // A runtime record of its readable properties — what PRINT, JSON and
        // VARIANT boxing use, so an imported object renders in the runtime's
        // own words rather than a second formatter's.
        out += "define ptr @\"\(name).toRuntime\"(ptr %o) {\n"
        out += "  %rt = call ptr @basic_rt_composite_new(i64 \(entry.type.index))\n"
        counter = 100
        for (index, field) in entry.type.fields.enumerated() {
            guard Self.property(named: field.name, of: entry.klass, in: entry.api) != nil else { continue }
            let value = temp()
            switch field.type {
            case .number:
                out += "  \(value) = call double @\"\(name).get.\(index)\"(ptr %o)\n"
                out += "  call void @basic_rt_composite_set_number(ptr %rt, i64 \(index), double \(value))\n"
            case .boolean:
                out += "  \(value) = call i1 @\"\(name).get.\(index)\"(ptr %o)\n"
                out += "  call void @basic_rt_composite_set_boolean(ptr %rt, i64 \(index), i1 \(value))\n"
            case .string:
                out += "  \(value) = call ptr @\"\(name).get.\(index)\"(ptr %o)\n"
                out += "  call void @basic_rt_composite_set_string(ptr %rt, i64 \(index), ptr \(value))\n"
                out += "  call void @basic_rt_string_release(ptr \(value))\n"
            default:
                break
            }
        }
        out += "  ret ptr %rt\n}\n"

        // Method thunks, named as the traditional lowering names a method.
        // Every method the class answers to, its own and its bases', because
        // BIR names a method on the class it was called on.
        var methods: [SwiftAPI.Function] = []
        var walk: SwiftAPI.Class? = entry.klass
        while let here = walk {
            for method in here.methods where !methods.contains(where: { $0.name == method.name }) { methods.append(method) }
            walk = here.superclassPrecise.flatMap { entry.api.class(precise: $0) }
        }
        for method in methods {
            guard let function = module.functions.first(where: { $0.name == "\(name).\(method.name.uppercased())" }) else { continue }
            counter = 0
            var body = ""
            var arguments: [String] = []
            let (declared, slots) = basicParameters(method.passed)
            var parameters = ["ptr %me"] + declared
            let viaShim = Self.needsShim(method)
            for (index, parameter) in method.passed.enumerated() {
                if case .structure = parameter.type {
                    // Each leaf goes across on its own; the shim rebuilds.
                    arguments += slots[index].map { convert($0.0, $0.1, viaShim, into: &body) }
                } else {
                    arguments.append(convert(slots[index][0].0, parameter.type, viaShim, into: &body))
                }
            }
            // An async method goes through its shim, which takes the
            // receiver as an ordinary first argument and no swiftself.
            if Self.needsShim(method) {
                let shim = Self.shimSymbol(method, of: entry.klass.name)
                if case .payloadEnumeration(let precise) = method.returns { arguments.append("i64 \(payloadTypeIndex(precise))") }
                let call = "call \(Self.shimAbiReturn(method.returns)) @\(shim)(ptr %me\(arguments.isEmpty ? "" : ", " + arguments.joined(separator: ", ")))"
                if method.returns == .void {
                    body += "  \(call)\n"
                    out += "define void @\"F.\(function.name)\"(\(parameters.joined(separator: ", "))) {\n\(body)  ret void\n}\n"
                } else {
                    let raw = temp()
                    body += "  \(raw) = \(call)\n"
                    // A String comes back from a shim as an owned runtime
                    // string already — exactly what fromSwift would make.
                    let value = method.returns == .string ? raw : fromSwift(raw, method.returns, into: &body)
                    out += "define \(basicType(method.returns)) @\"F.\(function.name)\"(\(parameters.joined(separator: ", "))) {\n\(body)  ret \(basicType(method.returns)) \(value)\n}\n"
                }
                continue
            }
            arguments.append("ptr swiftself %me")
            let returnType = Self.abiReturn(method.returns)
            // R4.6 — a thrown Swift error becomes a BASIC error.
            //
            // Swift's throwing convention is branch-on-return, not unwinding:
            // the callee writes the error through a `swifterror` slot and
            // returns as usual, so the caller reads the slot and takes one of
            // two paths. That is why this needs no landing pads and works the
            // same on any target.
            var errorSlot = ""
            if method.isThrowing {
                errorSlot = "%err"
                body = "  %err = alloca swifterror ptr, align 8\n  store ptr null, ptr %err, align 8\n" + body
                arguments.append("ptr swifterror %err")
            }
            func raiseIfThrown(_ body: inout String) {
                guard method.isThrowing else { return }
                let thrown = temp()
                body += "  \(thrown) = load ptr, ptr \(errorSlot), align 8\n"
                let failed = temp()
                body += "  \(failed) = icmp ne ptr \(thrown), null\n"
                let raise = "raise\(counter)", carry = "carry\(counter)"
                body += "  br i1 \(failed), label %\(raise), label %\(carry)\n"
                body += "\(raise):\n"
                // Does not return: the runtime longjmps to whatever ON ERROR
                // installed, exactly as it does for a runtime error of its own.
                body += "  call swiftcc void @basic_rt_swift_error_raise(ptr \(thrown))\n"
                body += "  unreachable\n"
                body += "\(carry):\n"
            }
            if method.returns == .void {
                body += "  call swiftcc void @\"\(method.symbol)\"(\(arguments.joined(separator: ", ")))\n"
                raiseIfThrown(&body)
                out += "define void @\"F.\(function.name)\"(\(parameters.joined(separator: ", "))) {\n\(body)  ret void\n}\n"
            } else {
                let raw = temp()
                body += "  \(raw) = call swiftcc \(returnType) @\"\(method.symbol)\"(\(arguments.joined(separator: ", ")))\n"
                raiseIfThrown(&body)
                let value = fromSwift(raw, method.returns, into: &body)
                out += "define \(basicType(method.returns)) @\"F.\(function.name)\"(\(parameters.joined(separator: ", "))) {\n\(body)  ret \(basicType(method.returns)) \(value)\n}\n"
            }
        }
        return out
    }

    // MARK: - Per-class IR

    func perClass(_ layout: ClassLayout) -> String {
        let name = layout.name
        let fields = layout.composite.fields
        var out = ""

        // The record this object carries, for the fields the runtime keeps.
        if let sideOffset = layout.sideOffset {
            out += """
            define ptr @"\(name).record"(ptr %o) {
              %p = getelementptr inbounds i8, ptr %o, i64 \(sideOffset)
              %v = load ptr, ptr %p, align 8
              ret ptr %v
            }

            """
        }

        // Field accessors, for the fields the object lays out itself.
        for (index, field) in fields.enumerated() where layout.fieldOffsets[index] >= 0 {
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
        if let sideOffset = layout.sideOffset {
            // The record *is* the runtime's copy of this object: taking it
            // whole is what gives every container field the runtime's own
            // copy semantics, with nothing here to get wrong.
            out += "  %side = call ptr @basic_rt_composite_copy(ptr %rt)\n"
            out += "  %sidep = getelementptr inbounds i8, ptr %o, i64 \(sideOffset)\n"
            out += "  %sideold = load ptr, ptr %sidep, align 8\n"
            out += "  store ptr %side, ptr %sidep, align 8\n"
            out += "  call void @basic_rt_composite_release(ptr %sideold)\n"
        }
        for (index, field) in fields.enumerated() where layout.fieldOffsets[index] >= 0 {
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
        if layout.sideOffset != nil {
            // Start from a copy of the record, which already holds every
            // container field, then write the object's own fields over it.
            out += "  %side = call ptr @\"\(name).record\"(ptr %o)\n"
            out += "  %rt = call ptr @basic_rt_composite_copy(ptr %side)\n"
        } else {
            out += "  %rt = call ptr @basic_rt_composite_new(i64 \(layout.typeIndex))\n"
        }
        for (index, field) in fields.enumerated() where layout.fieldOffsets[index] >= 0 {
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
        // A freshly cleared object has a null record, and `assign` copies
        // *into* one — so anything that allocates and then assigns has to
        // give it a record first.
        let makeRecord = layout.sideOffset.map { offset in
            """
              %newrec = call ptr @basic_rt_composite_new(i64 \(layout.typeIndex))
              %newrecp = getelementptr inbounds i8, ptr %o, i64 \(offset)
              store ptr %newrec, ptr %newrecp, align 8
            """
        } ?? ""
        // The allocating initializer is what the probe reports; its
        // initializing twin ends in a lowercase `c`, and the destructors are
        // the class prefix plus `fd`/`fD` — neither of which involves a
        // signature, so neither needs probing.
        let allocating = probed.member("init", of: layout.composite.displayName) ?? (layout.mangled + "ACycfC")
        let initializing = String(allocating.dropLast()) + "c"
        let destroying = layout.mangled + "fd"
        let deallocating = layout.mangled + "fD"

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
        \(makeRecord)
          call void @"\(name).assign"(ptr %o, ptr %src)
          ret ptr %o
        none:
          ret ptr null
        }
        define void @"\(name).assign"(ptr %dst, ptr %src) {

        """
        if layout.sideOffset != nil {
            // Value semantics reach inside: `C = A` gives C its own record,
            // so mutating C's array leaves A's alone.
            out += "  %srcside = call ptr @\"\(name).record\"(ptr %src)\n"
            out += "  %dstside = call ptr @\"\(name).record\"(ptr %dst)\n"
            out += "  call void @basic_rt_composite_assign(ptr %dstside, ptr %srcside)\n"
        }
        for (index, field) in fields.enumerated() where layout.fieldOffsets[index] >= 0 {
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
        if let sideOffset = layout.sideOffset {
            out += "  %sidep = getelementptr inbounds i8, ptr %self, i64 \(sideOffset)\n"
            out += "  %side = load ptr, ptr %sidep, align 8\n"
            out += "  call void @basic_rt_composite_release(ptr %side)\n"
        }
        for (index, field) in fields.enumerated() where layout.fieldOffsets[index] >= 0 {
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
        //
        // Values are converted where they cross (R2.1). A BASIC string is
        // the runtime's exact-byte object and a Swift string is a
        // `Swift.String`; neither can hold the other's full range, so the
        // conversion is at the boundary and the illusion is built on access,
        // exactly as the slice describes. The shapes come from the probe, so
        // any signature swiftc can spell arrives here.
        for method in layout.visibleMethods {
            let function = "F.\(method.function.name)"
            var body = ""
            var counter = 0
            func temp() -> String { counter += 1; return "%s\(counter)" }

            // Parameters: Swift's ABI in, BASIC's out.
            var parameters: [String] = []
            var arguments: [String] = ["ptr %self"]
            for (index, parameter) in method.function.parameters.dropFirst().enumerated() {
                switch parameter.type {
                case .string:
                    // A `Swift.String` is two words at a call boundary.
                    parameters.append("i64 %a\(index)w0, ptr %a\(index)w1")
                    let converted = temp()
                    body += "  \(converted) = call swiftcc ptr @basic_rt_swift_string_out(i64 %a\(index)w0, ptr %a\(index)w1)\n"
                    arguments.append("ptr \(converted)")
                case .boolean:
                    parameters.append("i1 %a\(index)")
                    arguments.append("i1 %a\(index)")
                case .composite:
                    parameters.append("ptr %a\(index)")
                    arguments.append("ptr %a\(index)")
                default:
                    parameters.append("double %a\(index)")
                    arguments.append("double %a\(index)")
                }
            }
            parameters.append("ptr swiftself %self")
            // R4.6 — a BASIC error that reaches Swift arrives as a thrown one.
            // Every method Swift can call is `throws`, as any VB.NET method
            // may raise without declaring it. The entry pushes an error
            // boundary, so a raise inside the BASIC body longjmps back here
            // rather than past Swift's frames — which killed the process —
            // and returns with the error in Swift's `swifterror` register.
            parameters.append("ptr swifterror %err")
            let prologue = "  %jmpbuf = alloca [64 x i64]\n"
                + "  call void @basic_rt_task_boundary_push(ptr %jmpbuf)\n"
                + "  %landed = call i32 @setjmp(ptr %jmpbuf)\n"
                + "  %failed = icmp ne i32 %landed, 0\n"
                + "  br i1 %failed, label %fail, label %run\nrun:\n"
            let pop = "  call void @basic_rt_task_boundary_pop()\n"
            func failure(_ exit: String) -> String {
                "fail:\n" + pop
                    + "  %thrown = call swiftcc ptr @basic_rt_swift_error_current()\n"
                    + "  store ptr %thrown, ptr %err\n"
                    + "  \(exit)\n"
            }

            let call = "call \(Self.birABI(method.function.returnType)) @\"\(function)\"(\(arguments.joined(separator: ", ")))"
            switch method.function.returnType {
            case .void:
                body += "  \(call)\n" + pop
                out += "define swiftcc void @\"\(method.symbol)\"(\(parameters.joined(separator: ", "))) {\n\(prologue)\(body)  ret void\n\(failure("ret void"))}\n"
            case .string:
                let raw = temp()
                body += "  \(raw) = \(call)\n"
                let text = temp()
                body += "  \(text) = call swiftcc { i64, ptr } @basic_rt_swift_string_in(ptr \(raw))\n"
                // The BASIC result was owned by this frame; the Swift string
                // carries its own storage now.
                body += "  call void @basic_rt_string_release(ptr \(raw))\n" + pop
                out += "define swiftcc { i64, ptr } @\"\(method.symbol)\"(\(parameters.joined(separator: ", "))) {\n\(prologue)\(body)  ret { i64, ptr } \(text)\n\(failure("ret { i64, ptr } zeroinitializer"))}\n"
            default:
                let raw = temp()
                body += "  \(raw) = \(call)\n" + pop
                let abi = Self.birABI(method.function.returnType)
                let zero = abi == "double" ? "0.0" : abi == "i1" ? "false" : abi == "ptr" ? "null" : "zeroinitializer"
                out += "define swiftcc \(abi) @\"\(method.symbol)\"(\(parameters.joined(separator: ", "))) {\n\(prologue)\(body)  ret \(abi) \(raw)\n\(failure("ret \(abi) \(zero)"))}\n"
            }
            out += "\n"
        }
        return out
    }

    /// A BIR type's LLVM form in Rev 1's own calling convention.
    static func birABI(_ type: BIRType) -> String {
        switch type {
        case .void: return "void"
        case .boolean: return "i1"
        case .number: return "double"
        default: return "ptr"
        }
    }

    // MARK: - Module helpers

    /// The whole-object operations that decide representation at run time.
    func helpers() -> String {
        // Imported classes join the run-time switch, but with reference
        // semantics: an imported Swift object is the framework's, and there
        // is no copy constructor to call. Ruling D15 — `A = B` on an
        // imported object aliases it, as it would in Swift.
        let imported = importedByName.values.sorted { $0.type.name < $1.type.name }
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
        var probes: [(label: Int, metadata: String)] = classes.map { ($0.ordinal, "\($0.mangled)N") }
        probes += imported.enumerated().map { (classes.count + $0.offset, "\($0.element.klass.symbol)N") }
        for (k, metadata) in probes {
            out += "check\(k):\n"
            out += "  %eq\(k) = icmp eq ptr %isa, @\"\(metadata)\"\n"
            out += "  br i1 %eq\(k), label %found\(k), label %check\(k + 1)\n"
        }
        out += "check\(probes.count):\n  br label %step\n"
        out += "step:\n  %superp = getelementptr inbounds i8, ptr %isa, i64 8\n  %next = load ptr, ptr %superp, align 8\n  br label %loop\n"
        for (k, _) in probes { out += "found\(k):\n  ret i64 \(k)\n" }
        out += "none:\n  ret i64 -1\n}\n\n"

        /// A dispatcher: switch on classOf, one arm per class, runtime default.
        func dispatcher(_ name: String, signature: String, arguments: String, subject: String,
                        arm: (ClassLayout) -> String, importedArm: (Int) -> String, fallback: String) -> String {
            var text = "define \(signature) @\"obj.\(name)\"(\(arguments)) {\n"
            text += "  %k = call i64 @\"obj.classOf\"(ptr \(subject))\n"
            text += "  switch i64 %k, label %rt [ " + probes.map { "i64 \($0.label), label %c\($0.label)" }.joined(separator: " ") + " ]\n"
            for layout in classes { text += "c\(layout.ordinal):\n" + arm(layout) }
            for k in classes.count..<probes.count { text += "c\(k):\n" + importedArm(k) }
            text += "rt:\n" + fallback + "}\n\n"
            return text
        }

        out += dispatcher("copy", signature: "ptr", arguments: "ptr %o", subject: "%o",
            arm: { "  %r\($0.ordinal) = call ptr @\"\($0.name).copy\"(ptr %o)\n  ret ptr %r\($0.ordinal)\n" },
            // D15: an imported object is the framework's, and there is no
            // copy constructor to call — it is retained, not duplicated.
            importedArm: { _ in "  call void @swift_retain(ptr %o)\n  ret ptr %o\n" },
            fallback: "  %r = call ptr @basic_rt_composite_copy(ptr %o)\n  ret ptr %r\n")
        out += dispatcher("assign", signature: "void", arguments: "ptr %dst, ptr %src", subject: "%dst",
            arm: { "  call void @\"\($0.name).assign\"(ptr %dst, ptr %src)\n  ret void\n" },
            // Nothing to write back: the receiver a method mutated *is* the
            // object the caller holds.
            importedArm: { _ in "  ret void\n" },
            fallback: "  call void @basic_rt_composite_assign(ptr %dst, ptr %src)\n  ret void\n")
        out += dispatcher("release", signature: "void", arguments: "ptr %o", subject: "%o",
            arm: { _ in "  call void @swift_release(ptr %o)\n  ret void\n" },
            importedArm: { _ in "  call void @swift_release(ptr %o)\n  ret void\n" },
            fallback: "  call void @basic_rt_composite_release(ptr %o)\n  ret void\n")
        out += dispatcher("typeIndex", signature: "i64", arguments: "ptr %o", subject: "%o",
            arm: { "  ret i64 \($0.typeIndex)\n" },
            importedArm: { k in "  ret i64 \(imported[k - classes.count].type.index)\n" },
            fallback: "  %r = call i64 @basic_rt_composite_type(ptr %o)\n  ret i64 %r\n")
        out += dispatcher("text", signature: "ptr", arguments: "ptr %o", subject: "%o",
            arm: { "  %t\($0.ordinal) = call ptr @\"\($0.name).toRuntime\"(ptr %o)\n  %s\($0.ordinal) = call ptr @basic_rt_composite_text(ptr %t\($0.ordinal))\n  call void @basic_rt_composite_release(ptr %t\($0.ordinal))\n  ret ptr %s\($0.ordinal)\n" },
            importedArm: { k in "  %ti\(k) = call ptr @\"\(imported[k - classes.count].type.name).toRuntime\"(ptr %o)\n  %si\(k) = call ptr @basic_rt_composite_text(ptr %ti\(k))\n  call void @basic_rt_composite_release(ptr %ti\(k))\n  ret ptr %si\(k)\n" },
            fallback: "  %r = call ptr @basic_rt_composite_text(ptr %o)\n  ret ptr %r\n")
        out += dispatcher("print", signature: "void", arguments: "ptr %o", subject: "%o",
            arm: { "  %t\($0.ordinal) = call ptr @\"\($0.name).toRuntime\"(ptr %o)\n  call void @basic_rt_print_composite(ptr %t\($0.ordinal))\n  call void @basic_rt_composite_release(ptr %t\($0.ordinal))\n  ret void\n" },
            importedArm: { k in "  %ti\(k) = call ptr @\"\(imported[k - classes.count].type.name).toRuntime\"(ptr %o)\n  call void @basic_rt_print_composite(ptr %ti\(k))\n  call void @basic_rt_composite_release(ptr %ti\(k))\n  ret void\n" },
            fallback: "  call void @basic_rt_print_composite(ptr %o)\n  ret void\n")
        out += dispatcher("box", signature: "ptr", arguments: "ptr %o", subject: "%o",
            arm: { "  %t\($0.ordinal) = call ptr @\"\($0.name).toRuntime\"(ptr %o)\n  %b\($0.ordinal) = call ptr @basic_rt_value_from_composite(ptr %t\($0.ordinal))\n  call void @basic_rt_composite_release(ptr %t\($0.ordinal))\n  ret ptr %b\($0.ordinal)\n" },
            importedArm: { k in "  %ti\(k) = call ptr @\"\(imported[k - classes.count].type.name).toRuntime\"(ptr %o)\n  %bi\(k) = call ptr @basic_rt_value_from_composite(ptr %ti\(k))\n  call void @basic_rt_composite_release(ptr %ti\(k))\n  ret ptr %bi\(k)\n" },
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
