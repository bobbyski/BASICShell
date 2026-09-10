import Foundation

/// Emits the LLVM IR that makes a BASIC `CLASS` a real Swift class.
///
/// ## What this is
///
/// Swift class metadata, written by a compiler that is not `swiftc`. Getting
/// it right is what buys the two things Rev 2 exists for, both measured
/// end to end by `SwiftClassMetadataTests`:
///
/// - **BASIC subclasses Swift.** A class emitted this way inherits a Swift
///   class's stored properties and accessors, overrides its methods, and is
///   dispatched to virtually through a base-class reference. `type(of:)`,
///   `is`/`as?`, reflection and ARC all see an ordinary Swift class.
/// - **Swift subclasses BASIC.** Compiled against the `.swiftinterface` the
///   dialect generates alongside, a Swift `class Ship: Sprite` links, and its
///   `super.describe()` reaches the body BASIC wrote.
///
/// ## The layout, and where the numbers come from
///
/// Metadata is one global. Its *address point* is not its start: three words
/// sit in front of it — a reserved word, the destructor at −16, and the
/// value-witness pointer at −8 — and the symbol the world knows
/// (`…CN`) aliases the address point. Every constant below was read out of
/// `swiftc -emit-ir` for the equivalent Swift declaration on the 6.3.1
/// toolchain and then re-verified by running the linked program; none is
/// guessed, and the round-trip test is what keeps them honest when a
/// toolchain moves.
///
/// ```text
///   −24  reserved                    ← allocation starts here
///   −16  destructor  (…CfD)
///    −8  value witness (…$sBoWV)
///   ┌──── address point — this is what `…CN` names ────
///     +0  isa → our metaclass
///     +8  superclass metadata
///    +16  ObjC cache, +24 reserved, +32 rodata|swift-bit
///    +40  class flags · instance address point · instance size · align mask
///    +56  class size · class address point
///    +64  nominal type descriptor, +72 ivar destroyer
///    +80  field offset vector, then the vtable slots
/// ```
///
/// ## Where a subclass's own fields go
///
/// Derived from `swiftc`'s own output for classes with 0, 1, 2 and 3 stored
/// properties over the same base, then checked by running the result:
///
/// ```text
///   fieldOffsetVectorOffset = the superclass's positive size, in words
///   numImmediateMembers     = own field-offset words + own vtable entries
///   positiveSizeInWords     = superclass's positive size + immediate members
///   classSize               = 24 + positiveSizeInWords * 8
///   instanceSize            = superclass's instance size + own field sizes
/// ```
///
/// The subclass's own field-offset vector begins exactly where the inherited
/// metadata ends, which is why the superclass's size is the offset.
public struct SwiftClassMetadata: Sendable {
    /// The Swift class a BASIC class inherits — everything the emitter needs
    /// to name and lay out against it.
    ///
    /// "Non-resilient" means built without library evolution, which is what
    /// SwiftPM produces by default, and therefore what a local `IMPORT` of
    /// TUIKit or VectorTerminalSDK gets. A resilient superclass needs the
    /// metadata *pattern* plus `swift_initClassMetadata2` at run time; that is
    /// a separate, known shape and a separate slice.
    public struct Superclass: Sendable {
        /// The module the superclass is declared in, e.g. `"BASICRTSwift"`.
        public let module: String
        /// The class's name, e.g. `"BASICObject"`.
        public let name: String
        /// Its metadata slots past the header, in the order its own metadata
        /// has them. A class's field offsets and vtable entries are **not**
        /// two separate runs across the whole hierarchy: each class in the
        /// chain contributes its own fields followed by its own methods, and
        /// the next class's block starts after that. Modelling this as one
        /// ordered list is what keeps a two-level hierarchy laid out the way
        /// `swiftc` lays it out.
        public let immediateMembers: [MetadataSlot]
        /// This class's own metadata size past the address point, in words.
        /// It is also where a subclass's own block begins.
        public var positiveSizeInWords: Int {
            SwiftClassMetadata.headerSizeInWords + immediateMembers.count
        }
        /// Instance size, inherited unchanged by a subclass.
        public let instanceSize: Int
        /// The alignment mask (`7` for word-aligned).
        public let alignMask: Int

        /// Creates a superclass description.
        public init(
            module: String,
            name: String,
            immediateMembers: [MetadataSlot],
            instanceSize: Int,
            alignMask: Int = 7
        ) {
            self.module = module
            self.name = name
            self.immediateMembers = immediateMembers
            self.instanceSize = instanceSize
            self.alignMask = alignMask
        }

        /// The mangled prefix every symbol of this class shares.
        var mangled: String { get throws { try SwiftMangling.mangleClass(module: module, name: name) } }
    }

    /// One word of a class's metadata past the fixed header.
    public enum MetadataSlot: Sendable, Equatable {
        /// A stored property's byte offset within the instance.
        case fieldOffset(Int)
        /// A vtable entry: the symbol dispatched to.
        case method(String)
    }

    /// One `OVERRIDES` in a BASIC class: which inherited method, and the body.
    public struct Override: Sendable {
        /// The superclass method descriptor symbol (`…Tq`) being replaced.
        public let baseMethodDescriptor: String
        /// The symbol of the function that replaces it.
        public let implementation: String
        /// Which of the superclass's ``MetadataSlot``s it replaces.
        public let slot: Int

        /// Creates an override.
        public init(baseMethodDescriptor: String, implementation: String, slot: Int) {
            self.baseMethodDescriptor = baseMethodDescriptor
            self.implementation = implementation
            self.slot = slot
        }
    }

    /// One stored property a BASIC class adds: `PUBLIC X AS DOUBLE`.
    public struct StoredProperty: Sendable {
        /// The field's name, as BASIC wrote it.
        public let name: String
        /// Its size in bytes: 8 for a number (`Double`) or a reference, 1
        /// for a boolean.
        public let size: Int
        /// Its alignment. Swift lays stored properties out at natural
        /// alignment — measured: `{Double, Bool}` is 25 bytes, the `Bool` at
        /// 24 — so a `Bool` after a `Double` takes one byte, and a `Double`
        /// after a `Bool` starts on the next multiple of eight.
        public let alignment: Int

        /// Creates a stored property.
        public init(name: String, size: Int = 8, alignment: Int? = nil) {
            self.name = name
            self.size = size
            self.alignment = alignment ?? size
        }
    }

    /// A method the class adds rather than overrides — a new vtable slot.
    public struct Method: Sendable {
        /// The BASIC name.
        public let name: String
        /// The symbol implementing it.
        public let implementation: String

        /// Creates a method.
        public init(name: String, implementation: String) {
            self.name = name
            self.implementation = implementation
        }
    }

    /// A layout the emitter refuses to guess at.
    public struct UnsupportedLayout: Error, CustomStringConvertible {
        /// What was asked for.
        public let reason: String
        public var description: String { "the swift dialect cannot lay this class out yet: \(reason)" }
    }

    /// The module name — the BASIC program's name.
    public let module: String
    /// The BASIC class's name.
    public let name: String
    /// The Swift class it inherits.
    public let superclass: Superclass
    /// Its overrides.
    public let overrides: [Override]
    /// Bytes at the end of the instance that the metadata sizes but does not
    /// describe as a property.
    ///
    /// A class with container fields keeps them in a runtime record and holds
    /// a pointer to it here. It must not appear in the field-offset vector:
    /// Swift's view of the class comes from the generated interface, and a
    /// stored property there and not here (or the reverse) shifts every
    /// method slot after it — the bug R1.3 found. Sizing the allocation for
    /// it while leaving it undescribed is exactly what tail-allocated storage
    /// does.
    public var hiddenTrailingBytes: Int = 0

    /// Stored properties this class adds.
    public let storedProperties: [StoredProperty]
    /// Methods this class adds (as opposed to overrides).
    public let methods: [Method]

    /// Creates a class metadata emitter.
    public init(
        module: String,
        name: String,
        superclass: Superclass,
        overrides: [Override],
        storedProperties: [StoredProperty] = [],
        methods: [Method] = []
    ) {
        self.module = module
        self.name = name
        self.superclass = superclass
        self.overrides = overrides
        self.storedProperties = storedProperties
        self.methods = methods
    }

    /// Byte offsets of this class's own stored properties, laid out one after
    /// another past the superclass's instance data.
    public var ownFieldOffsets: [Int] {
        var offset = superclass.instanceSize
        return storedProperties.map { property in
            offset = (offset + property.alignment - 1) / property.alignment * property.alignment
            defer { offset += property.size }
            return offset
        }
    }

    /// This class's own metadata block: its field offsets, then its methods.
    ///
    /// **This has to agree, word for word, with what the generated interface
    /// declares.** Swift computes a method's vtable slot and a subclass's
    /// field placement from its own model of the layout, so the interface and
    /// the metadata are two statements of one fact. Both mismatches were
    /// measured, not imagined:
    ///
    /// - Offset words the interface does not declare shift the vtable out
    ///   from under the caller, and a method call jumps to a field offset.
    /// - Fields the interface does not declare make a Swift subclass place
    ///   *its* stored properties on top of BASIC's.
    ///
    /// So the fields are emitted here and declared there, as `final` stored
    /// properties — `final` because a non-resilient client then reads them
    /// straight from this vector instead of wanting accessor slots, and a
    /// `modify` coroutine is not something to hand-write yet.
    public var ownMembers: [MetadataSlot] {
        ownFieldOffsets.map { .fieldOffset($0) } + methods.map { .method($0.implementation) }
    }

    /// Every slot past the header: the superclass's block with any overrides
    /// applied in place, then this class's own block appended.
    public func slots() throws -> [MetadataSlot] {
        var inherited = superclass.immediateMembers
        for override in overrides {
            guard inherited.indices.contains(override.slot) else {
                throw UnsupportedLayout(reason: "override of \(override.implementation) names slot \(override.slot), and \(superclass.name) has \(inherited.count)")
            }
            guard case .method = inherited[override.slot] else {
                throw UnsupportedLayout(reason: "override of \(override.implementation) names slot \(override.slot) of \(superclass.name), which is a stored property, not a method")
            }
            inherited[override.slot] = .method(override.implementation)
        }
        return inherited + ownMembers
    }

    /// This instance's size: where the last own field ends — exact, not
    /// rounded, which is how `swiftc` reports it (`{Double, Bool}` is 25).
    public var instanceSize: Int {
        guard let last = storedProperties.last, let offset = ownFieldOffsets.last else {
            return superclass.instanceSize + hiddenTrailingBytes
        }
        return offset + last.size + hiddenTrailingBytes
    }

    /// Where the hidden trailing slot starts, when there is one.
    public var hiddenTrailingOffset: Int? {
        guard hiddenTrailingBytes > 0 else { return nil }
        return instanceSize - hiddenTrailingBytes
    }

    /// Metadata words this class adds past the inherited part.
    public var immediateMembers: Int { ownMembers.count }

    /// Words of metadata behind the address point: reserved, destructor,
    /// value witness.
    static let negativeSizeInWords = 3
    /// Words from the address point to the field offset vector.
    static let headerSizeInWords = 10
    /// Bytes from the allocation's start to the address point.
    static let classAddressPoint = 24

    /// The IR for this class: every global and the metadata itself.
    ///
    /// The bodies — methods, constructors, the destructor — are the code
    /// generator's business; this emits the structures that make them
    /// reachable as a Swift class, and names the symbols they must define.
    public func render() throws -> String {
        var shared = Set<String>()
        return try render(shared: &shared, emitUsed: true)
    }

    /// Renders with module-level singletons deduplicated across classes.
    ///
    /// The module context, a superclass's symbolic reference and the GOT
    /// slot for an overridden method are one per *module*, not one per
    /// class; two classes over the same base would otherwise define them
    /// twice, which LLVM rejects. `shared` remembers what has been emitted.
    /// `@llvm.used` is likewise one per module — pass `emitUsed: false` and
    /// collect ``usedSymbols`` yourself when emitting several classes.
    public func render(shared: inout Set<String>, emitUsed: Bool) throws -> String {
        let mangled = try SwiftMangling.mangleClass(module: module, name: name)
        let superMangled = try superclass.mangled
        let slots = try slots()
        let classSize = Self.classAddressPoint + (superclass.positiveSizeInWords + immediateMembers) * 8
        let objcName = "_TtC\(module.utf8.count)\(module)\(name.utf8.count)\(name)"

        var out = ""
        out += "; \(module).\(name) — a BASIC CLASS, emitted as a Swift class.\n"
        out += "; superclass \(superclass.module).\(superclass.name); \(overrides.count) override(s).\n"
        out += names(mangled: mangled, superMangled: superMangled, objcName: objcName, shared: &shared)
        out += objcRodata(objcName: objcName)
        out += "@\"\(mangled)Mm\" = global %objc_class { ptr @\"OBJC_METACLASS_$__TtCs12_SwiftObject\", "
        out += "ptr @\"\(superMangled)Mm\", ptr @_objc_empty_cache, ptr null, "
        out += "i64 ptrtoint (ptr @\"_METACLASS_DATA_\(objcName)\" to i64) }, align 8\n"
        out += fieldDescriptor(mangled: mangled, superMangled: superMangled)
        out += nominalTypeDescriptor(mangled: mangled, superMangled: superMangled, shared: &shared)
        out += metadata(
            mangled: mangled,
            superMangled: superMangled,
            objcName: objcName,
            slots: slots,
            classSize: classSize
        )
        out += "@\"\(mangled)N\" = alias %swift.type, getelementptr inbounds (\(metadataType(slots: slots)), ptr @\"\(mangled)Mf\", i32 0, i32 3)\n"
        out += typeRecord(mangled: mangled, emitUsed: emitUsed)
        out += metadataAccessor(mangled: mangled)
        return out
    }

    /// The symbols `@llvm.used` must keep alive for this class.
    public var usedSymbols: [String] {
        get throws {
            let mangled = try SwiftMangling.mangleClass(module: module, name: name)
            return ["\(mangled)Mn", "\(mangled)Ma", "\(mangled)MF", "\(mangled)Hn", "objc_classes_\(mangled)N", "\(mangled)Mf"]
        }
    }

    /// One `@llvm.used` for a module's worth of classes.
    public static func usedDirective(_ symbols: [String]) -> String {
        guard !symbols.isEmpty else { return "" }
        let list = symbols.map { "ptr @\"\($0)\"" }.joined(separator: ", ")
        return "@llvm.used = appending global [\(symbols.count) x ptr] [\(list)], section \"llvm.metadata\"\n"
    }

    /// A relative pointer: LLVM has no such type, so every one is written as
    /// the 32-bit difference between the target and the field holding it.
    static func relative(to target: String, fromField path: String) -> String {
        "i32 trunc (i64 sub (i64 ptrtoint (ptr \(target) to i64), i64 ptrtoint (\(path) to i64)) to i32)"
    }

    /// Name strings, the module context, and the symbolic mangled names the
    /// runtime reads type references out of.
    func names(mangled: String, superMangled: String, objcName: String, shared: inout Set<String>) -> String {
        let moduleContext = "@\"$s\(module.utf8.count)\(module)MXM\""
        var out = ""
        out += "@\".str.class.\(name)\" = private constant [\(name.utf8.count + 1) x i8] c\"\(name)\\00\"\n"
        out += "@\".str.objc.\(name)\" = private unnamed_addr constant [\(objcName.utf8.count + 1) x i8] c\"\(objcName)\\00\", section \"__TEXT,__objc_classname,cstring_literals\"\n"
        if shared.insert(moduleContext).inserted {
            out += "@\".str.module.\(module)\" = private constant [\(module.utf8.count + 1) x i8] c\"\(module)\\00\"\n"
            out += "\(moduleContext) = linkonce_odr hidden constant <{ i32, i32, i32 }> <{ i32 0, i32 0, "
            out += Self.relative(to: "@\".str.module.\(module)\"", fromField: "ptr getelementptr inbounds (<{ i32, i32, i32 }>, ptr \(moduleContext), i32 0, i32 2)")
            out += " }>, section \"__TEXT,__constg_swiftt\", align 4\n"
        }
        // Kind 2: an indirect reference through the GOT to the superclass's
        // descriptor — the form used when the superclass is another module's.
        // (Also correct for a superclass in this module: the GOT slot simply
        // resolves locally.)
        if shared.insert("symbolic.\(superMangled)").inserted {
            out += "@\"got.\(superMangled)Mn\" = private unnamed_addr constant ptr @\"\(superMangled)Mn\"\n"
            out += "@\"symbolic.\(superMangled)\" = linkonce_odr hidden constant <{ i8, i32, i8 }> <{ i8 2, "
            out += Self.relative(to: "@\"got.\(superMangled)Mn\"", fromField: "ptr getelementptr inbounds (<{ i8, i32, i8 }>, ptr @\"symbolic.\(superMangled)\", i32 0, i32 1)")
            out += ", i8 0 }>, align 2\n"
        }
        // Kind 1: a direct reference to our own descriptor. Named apart from
        // the kind-2 reference a *subclass* emits for this same class — two
        // globals, two contents, and LLVM would rightly refuse one name.
        out += "@\"symbolic.own.\(mangled)\" = linkonce_odr hidden constant <{ i8, i32, i8 }> <{ i8 1, "
        out += Self.relative(to: "@\"\(mangled)Mn\"", fromField: "ptr getelementptr inbounds (<{ i8, i32, i8 }>, ptr @\"symbolic.own.\(mangled)\", i32 0, i32 1)")
        out += ", i8 0 }>, align 2\n"
        return out
    }

    /// The ObjC-side class data. Darwin registers every Swift class with the
    /// ObjC runtime, so a class without this is not a class there — and
    /// `NSStringFromClass` and the debugger both notice.
    func objcRodata(objcName: String) -> String {
        let fields = "{ i32, i32, i32, i32, ptr, ptr, ptr, ptr, ptr, ptr, ptr }"
        var out = ""
        out += "@\"_METACLASS_DATA_\(objcName)\" = internal constant \(fields) { i32 129, i32 40, i32 40, i32 0, ptr null, ptr @\".str.objc.\(name)\", ptr null, ptr null, ptr null, ptr null, ptr null }, section \"__DATA, __objc_const\", align 8\n"
        out += "@\"_DATA_\(objcName)\" = internal constant \(fields) { i32 128, i32 \(instanceSize), i32 \(instanceSize), i32 0, ptr null, ptr @\".str.objc.\(name)\", ptr null, ptr null, ptr null, ptr null, ptr null }, section \"__DATA, __objc_const\", align 8\n"
        return out
    }

    /// The reflection record: no new stored properties, so it names only the
    /// superclass.
    func fieldDescriptor(mangled: String, superMangled: String) -> String {
        let type = "{ i32, i32, i16, i16, i32 }"
        var out = "@\"\(mangled)MF\" = internal constant \(type) { "
        out += Self.relative(to: "@\"symbolic.own.\(mangled)\"", fromField: "ptr @\"\(mangled)MF\"") + ", "
        out += Self.relative(to: "@\"symbolic.\(superMangled)\"", fromField: "ptr getelementptr inbounds (\(type), ptr @\"\(mangled)MF\", i32 0, i32 1)")
        out += ", i16 1, i16 12, i32 0 }, section \"__TEXT,__swift5_fieldmd, regular\", no_sanitize_address, align 4\n"
        return out
    }

    /// The nominal type descriptor: what the runtime reads to answer "what
    /// type is this", and what the vtable and override tables hang off.
    ///
    /// Flags, measured: `0x40000050` is class + unique + has-override-table,
    /// and `0x8000` adds has-vtable. A class that adds methods of its own
    /// needs both — the vtable so its methods have descriptors, and the
    /// override table because every BASIC class replaces the root's `init`.
    ///
    /// A method descriptor's flags are `16`: kind 0 (an ordinary method) with
    /// the instance bit set. Accessors are 18/19/20 and initializers 1, which
    /// is why the field accessors a Swift `public var` would generate are not
    /// emitted here — BASIC fields are reached through methods for now.
    func nominalTypeDescriptor(mangled: String, superMangled: String, shared: inout Set<String>) -> String {
        let moduleContext = "@\"$s\(module.utf8.count)\(module)MXM\""
        // Eleven fixed words, then the optional vtable pair, then the
        // override count and its entries.
        var types: [String] = Array(repeating: "i32", count: 11)
        if !methods.isEmpty { types += ["i32", "i32"] + methods.map { _ in "%swift.method_descriptor" } }
        types += ["i32"] + overrides.map { _ in "%swift.method_override_descriptor" }
        let type = "<{ " + types.joined(separator: ", ") + " }>"
        func field(_ indices: [Int]) -> String {
            "ptr getelementptr inbounds (\(type), ptr @\"\(mangled)Mn\", " + indices.map { "i32 \($0)" }.joined(separator: ", ") + ")"
        }

        var flags = 0x4000_0050
        if !methods.isEmpty { flags |= 0x8000 }
        var values: [String] = [
            "i32 \(Int32(bitPattern: UInt32(flags)))",
            Self.relative(to: moduleContext, fromField: field([0, 1])),
            Self.relative(to: "@\".str.class.\(name)\"", fromField: field([0, 2])),
            Self.relative(to: "@\"\(mangled)Ma\"", fromField: field([0, 3])),
            Self.relative(to: "@\"\(mangled)MF\"", fromField: field([0, 4])),
            Self.relative(to: "@\"symbolic.\(superMangled)\"", fromField: field([0, 5])),
            "i32 \(Self.negativeSizeInWords)",
            "i32 \(superclass.positiveSizeInWords + immediateMembers)",
            "i32 \(immediateMembers)",
            "i32 \(storedProperties.count)",
            "i32 \(superclass.positiveSizeInWords)",
        ]
        var index = 11
        if !methods.isEmpty {
            // After the inherited block and this class's own field offsets.
            values.append("i32 \(superclass.positiveSizeInWords + storedProperties.count)")
            values.append("i32 \(methods.count)")
            index += 2
            for method in methods {
                values.append("%swift.method_descriptor { i32 16, "
                    + Self.relative(to: "@\"\(method.implementation)\"", fromField: field([0, index, 1])) + " }")
                index += 1
            }
        }
        values.append("i32 \(overrides.count)")
        index += 1
        for override in overrides {
            var descriptor = "%swift.method_override_descriptor { "
            descriptor += "i32 add (" + Self.relative(to: "@\"got.\(superMangled)Mn\"", fromField: field([0, index, 0])) + ", i32 1), "
            descriptor += "i32 add (" + Self.relative(to: "@\"got.\(override.baseMethodDescriptor)\"", fromField: field([0, index, 1])) + ", i32 1), "
            descriptor += Self.relative(to: "@\"\(override.implementation)\"", fromField: field([0, index, 2]))
            values.append(descriptor + " }")
            index += 1
        }

        var out = ""
        for override in overrides where shared.insert("got.\(override.baseMethodDescriptor)").inserted {
            out += "@\"got.\(override.baseMethodDescriptor)\" = private unnamed_addr constant ptr @\"\(override.baseMethodDescriptor)\"\n"
        }
        out += "@\"\(mangled)Mn\" = constant \(type) <{ \(values.joined(separator: ", ")) }>, section \"__TEXT,__constg_swiftt\", align 4\n"
        // A Swift subclass overriding one of these looks the method up by its
        // descriptor, so each needs a symbol of its own aliasing into the table.
        var slot = 13
        for method in methods {
            out += "@\"\(method.implementation)Tq\" = alias %swift.method_descriptor, getelementptr inbounds (\(type), ptr @\"\(mangled)Mn\", i32 0, i32 \(slot))\n"
            slot += 1
        }
        return out
    }

    /// The record that puts this type in `__swift5_types`, so the runtime can
    /// find it by name, and the ObjC class list entry.
    func typeRecord(mangled: String, emitUsed: Bool) -> String {
        var out = "@\"\(mangled)Hn\" = private constant %swift.type_metadata_record { "
        out += Self.relative(to: "@\"\(mangled)Mn\"", fromField: "ptr @\"\(mangled)Hn\"")
        out += " }, section \"__TEXT, __swift5_types, regular\", no_sanitize_address, align 4\n"
        out += "@\"objc_classes_\(mangled)N\" = internal global ptr @\"\(mangled)N\", section \"__DATA,__objc_classlist,regular,no_dead_strip\", no_sanitize_address, align 8\n"
        if emitUsed {
            out += Self.usedDirective((try? usedSymbols) ?? [])
        }
        return out
    }

    /// The metadata accessor. A non-resilient superclass means the metadata is
    /// complete at link time, so this hands it back with a "complete" response
    /// and makes no runtime call at all.
    func metadataAccessor(mangled: String) -> String {
        """
        define swiftcc %swift.metadata_response @"\(mangled)Ma"(i64 %0) {
          %r0 = insertvalue %swift.metadata_response undef, ptr @"\(mangled)N", 0
          %r1 = insertvalue %swift.metadata_response %r0, i64 0, 1
          ret %swift.metadata_response %r1
        }

        """
    }

    /// The LLVM type definitions and external declarations the emitted
    /// metadata refers to — the preamble of any module carrying a class.
    public static let preamble = """
    %swift.type = type { i64 }
    %swift.type_descriptor = type { i32 }
    %swift.method_descriptor = type { i32, i32 }
    %swift.method_override_descriptor = type { i32, i32, i32 }
    %swift.metadata_response = type { ptr, i64 }
    %swift.type_metadata_record = type { i32 }
    %swift.opaque = type opaque
    %objc_class = type { ptr, ptr, ptr, ptr, i64 }

    @"$sBoWV" = external global ptr, align 8
    @_objc_empty_cache = external global %swift.opaque
    @"OBJC_METACLASS_$__TtCs12_SwiftObject" = external global %objc_class, align 8
    declare ptr @swift_allocObject(ptr, i64, i64)
    declare void @swift_deallocClassInstance(ptr, i64, i64)

    """

    /// The LLVM struct type of the metadata global, which varies with the
    /// number of field-offset and vtable slots.
    func metadataType(slots: [MetadataSlot]) -> String {
        let fixed = "ptr, ptr, ptr, i64, ptr, ptr, ptr, i64, i32, i32, i32, i16, i16, i32, i32, ptr, ptr"
        let words = slots.map { slot -> String in
            if case .fieldOffset = slot { return "i64" }
            return "ptr"
        }
        return "<{ " + ([fixed] + words).joined(separator: ", ") + " }>"
    }

    func metadata(mangled: String, superMangled: String, objcName: String, slots: [MetadataSlot], classSize: Int) -> String {
        let type = metadataType(slots: slots)
        var values: [String] = [
            "ptr null",
            "ptr @\"\(mangled)fD\"",
            "ptr @\"$sBoWV\"",
            "i64 ptrtoint (ptr @\"\(mangled)Mm\" to i64)",
            "ptr @\"\(superMangled)N\"",
            "ptr @_objc_empty_cache",
            "ptr null",
            "i64 add (i64 ptrtoint (ptr @\"_DATA_\(objcName)\" to i64), i64 2)",
            "i32 2",
            "i32 0",
            "i32 \(instanceSize)",
            "i16 \(superclass.alignMask)",
            "i16 0",
            "i32 \(classSize)",
            "i32 \(Self.classAddressPoint)",
            "ptr @\"\(mangled)Mn\"",
            "ptr null",
        ]
        values += slots.map { slot in
            switch slot {
            case .fieldOffset(let offset): return "i64 \(offset)"
            case .method(let symbol): return "ptr @\"\(symbol)\""
            }
        }
        return "@\"\(mangled)Mf\" = internal global \(type) <{ \(values.joined(separator: ", ")) }>, align 8\n"
    }
}
