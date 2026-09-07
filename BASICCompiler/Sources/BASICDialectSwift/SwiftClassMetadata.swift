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
/// ## What it does not do yet
///
/// New stored properties on a BASIC subclass. The proved shape inherits its
/// layout; placing a *new* field means deriving the field-offset-vector
/// position rather than inheriting a measured one, and that derivation is the
/// next slice. ``Layout`` therefore carries the superclass's measured
/// numbers instead of computing them, and ``render()`` refuses new fields
/// rather than emitting a layout it cannot stand behind.
public struct SwiftClassMetadata {
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
        /// Its vtable entry symbols, in metadata slot order.
        public let vtable: [String]
        /// Its field-offset entries, in metadata slot order.
        public let fieldOffsets: [Int]
        /// Where the field offset vector sits, in words, as the superclass's
        /// own descriptor records it.
        public let fieldOffsetVectorOffset: Int
        /// Instance size and alignment mask, inherited unchanged.
        public let instanceSize: Int
        /// The alignment mask (`7` for word-aligned).
        public let alignMask: Int

        /// Creates a superclass description.
        public init(
            module: String,
            name: String,
            vtable: [String],
            fieldOffsets: [Int],
            fieldOffsetVectorOffset: Int,
            instanceSize: Int,
            alignMask: Int = 7
        ) {
            self.module = module
            self.name = name
            self.vtable = vtable
            self.fieldOffsets = fieldOffsets
            self.fieldOffsetVectorOffset = fieldOffsetVectorOffset
            self.instanceSize = instanceSize
            self.alignMask = alignMask
        }

        /// The mangled prefix every symbol of this class shares.
        var mangled: String { get throws { try SwiftMangling.mangleClass(module: module, name: name) } }
    }

    /// One `OVERRIDES` in a BASIC class: which inherited method, and the body.
    public struct Override: Sendable {
        /// The superclass method descriptor symbol (`…Tq`) being replaced.
        public let baseMethodDescriptor: String
        /// The symbol of the function that replaces it.
        public let implementation: String
        /// Which slot of the superclass vtable it occupies.
        public let vtableSlot: Int

        /// Creates an override.
        public init(baseMethodDescriptor: String, implementation: String, vtableSlot: Int) {
            self.baseMethodDescriptor = baseMethodDescriptor
            self.implementation = implementation
            self.vtableSlot = vtableSlot
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
    /// New stored properties, which are not supported yet.
    public let newStoredProperties: [String]

    /// Creates a class metadata emitter.
    public init(
        module: String,
        name: String,
        superclass: Superclass,
        overrides: [Override],
        newStoredProperties: [String] = []
    ) {
        self.module = module
        self.name = name
        self.superclass = superclass
        self.overrides = overrides
        self.newStoredProperties = newStoredProperties
    }

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
        guard newStoredProperties.isEmpty else {
            throw UnsupportedLayout(reason: "the class adds stored properties (\(newStoredProperties.joined(separator: ", "))), and the field offset vector for new fields is not derived yet")
        }
        let mangled = try SwiftMangling.mangleClass(module: module, name: name)
        let superMangled = try superclass.mangled
        let vtable = try resolvedVTable()
        let positiveSizeInWords = Self.headerSizeInWords + superclass.fieldOffsets.count + vtable.count
        let classSize = Self.classAddressPoint + positiveSizeInWords * 8
        let objcName = "_TtC\(module.utf8.count)\(module)\(name.utf8.count)\(name)"

        var out = ""
        out += "; \(module).\(name) — a BASIC CLASS, emitted as a Swift class.\n"
        out += "; superclass \(superclass.module).\(superclass.name); \(overrides.count) override(s).\n"
        out += names(mangled: mangled, superMangled: superMangled, objcName: objcName)
        out += objcRodata(objcName: objcName)
        out += "@\"\(mangled)Mm\" = global %objc_class { ptr @\"OBJC_METACLASS_$__TtCs12_SwiftObject\", "
        out += "ptr @\"\(superMangled)Mm\", ptr @_objc_empty_cache, ptr null, "
        out += "i64 ptrtoint (ptr @\"_METACLASS_DATA_\(objcName)\" to i64) }, align 8\n"
        out += fieldDescriptor(mangled: mangled, superMangled: superMangled)
        out += nominalTypeDescriptor(mangled: mangled, superMangled: superMangled)
        out += metadata(
            mangled: mangled,
            superMangled: superMangled,
            objcName: objcName,
            vtable: vtable,
            classSize: classSize
        )
        out += "@\"\(mangled)N\" = alias %swift.type, getelementptr inbounds (\(metadataType(vtable: vtable)), ptr @\"\(mangled)Mf\", i32 0, i32 3)\n"
        out += typeRecord(mangled: mangled)
        out += metadataAccessor(mangled: mangled)
        return out
    }

    /// A relative pointer: LLVM has no such type, so every one is written as
    /// the 32-bit difference between the target and the field holding it.
    static func relative(to target: String, fromField path: String) -> String {
        "i32 trunc (i64 sub (i64 ptrtoint (ptr \(target) to i64), i64 ptrtoint (\(path) to i64)) to i32)"
    }

    /// Name strings, the module context, and the symbolic mangled names the
    /// runtime reads type references out of.
    func names(mangled: String, superMangled: String, objcName: String) -> String {
        let moduleContext = "@\"$s\(module.utf8.count)\(module)MXM\""
        var out = ""
        out += "@\".str.module.\(module)\" = private constant [\(module.utf8.count + 1) x i8] c\"\(module)\\00\"\n"
        out += "@\".str.class.\(name)\" = private constant [\(name.utf8.count + 1) x i8] c\"\(name)\\00\"\n"
        out += "@\".str.objc.\(name)\" = private unnamed_addr constant [\(objcName.utf8.count + 1) x i8] c\"\(objcName)\\00\", section \"__TEXT,__objc_classname,cstring_literals\"\n"
        out += "\(moduleContext) = linkonce_odr hidden constant <{ i32, i32, i32 }> <{ i32 0, i32 0, "
        out += Self.relative(to: "@\".str.module.\(module)\"", fromField: "ptr getelementptr inbounds (<{ i32, i32, i32 }>, ptr \(moduleContext), i32 0, i32 2)")
        out += " }>, section \"__TEXT,__constg_swiftt\", align 4\n"
        // Kind 2: an indirect reference through the GOT to the superclass's
        // descriptor — the form used when the superclass is another module's.
        out += "@\"got.\(superMangled)Mn\" = private unnamed_addr constant ptr @\"\(superMangled)Mn\"\n"
        out += "@\"symbolic.\(superMangled)\" = linkonce_odr hidden constant <{ i8, i32, i8 }> <{ i8 2, "
        out += Self.relative(to: "@\"got.\(superMangled)Mn\"", fromField: "ptr getelementptr inbounds (<{ i8, i32, i8 }>, ptr @\"symbolic.\(superMangled)\", i32 0, i32 1)")
        out += ", i8 0 }>, align 2\n"
        // Kind 1: a direct reference to our own descriptor.
        out += "@\"symbolic.\(mangled)\" = linkonce_odr hidden constant <{ i8, i32, i8 }> <{ i8 1, "
        out += Self.relative(to: "@\"\(mangled)Mn\"", fromField: "ptr getelementptr inbounds (<{ i8, i32, i8 }>, ptr @\"symbolic.\(mangled)\", i32 0, i32 1)")
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
        out += "@\"_DATA_\(objcName)\" = internal constant \(fields) { i32 128, i32 \(superclass.instanceSize), i32 \(superclass.instanceSize), i32 0, ptr null, ptr @\".str.objc.\(name)\", ptr null, ptr null, ptr null, ptr null, ptr null }, section \"__DATA, __objc_const\", align 8\n"
        return out
    }

    /// The reflection record: no new stored properties, so it names only the
    /// superclass.
    func fieldDescriptor(mangled: String, superMangled: String) -> String {
        let type = "{ i32, i32, i16, i16, i32 }"
        var out = "@\"\(mangled)MF\" = internal constant \(type) { "
        out += Self.relative(to: "@\"symbolic.\(mangled)\"", fromField: "ptr @\"\(mangled)MF\"") + ", "
        out += Self.relative(to: "@\"symbolic.\(superMangled)\"", fromField: "ptr getelementptr inbounds (\(type), ptr @\"\(mangled)MF\", i32 0, i32 1)")
        out += ", i16 1, i16 12, i32 0 }, section \"__TEXT,__swift5_fieldmd, regular\", no_sanitize_address, align 4\n"
        return out
    }

    /// The nominal type descriptor: what the runtime reads to answer "what
    /// type is this", and what an override table hangs off.
    ///
    /// Flags `0x40000050` = class kind, unique, has an override table.
    func nominalTypeDescriptor(mangled: String, superMangled: String) -> String {
        let overrideFields = overrides.map { _ in "%swift.method_override_descriptor" }
        let type = "<{ " + (Array(repeating: "i32", count: 12) + overrideFields).joined(separator: ", ") + " }>"
        func field(_ indices: [Int]) -> String {
            "ptr getelementptr inbounds (\(type), ptr @\"\(mangled)Mn\", " + indices.map { "i32 \($0)" }.joined(separator: ", ") + ")"
        }
        let moduleContext = "@\"$s\(module.utf8.count)\(module)MXM\""
        var values: [String] = [
            "i32 1073741904",
            Self.relative(to: moduleContext, fromField: field([0, 1])),
            Self.relative(to: "@\".str.class.\(name)\"", fromField: field([0, 2])),
            Self.relative(to: "@\"\(mangled)Ma\"", fromField: field([0, 3])),
            Self.relative(to: "@\"\(mangled)MF\"", fromField: field([0, 4])),
            Self.relative(to: "@\"symbolic.\(superMangled)\"", fromField: field([0, 5])),
            "i32 \(Self.negativeSizeInWords)",
            "i32 \(Self.headerSizeInWords + superclass.fieldOffsets.count + superclass.vtable.count)",
            "i32 0",
            "i32 0",
            "i32 \(superclass.fieldOffsetVectorOffset)",
            "i32 \(overrides.count)",
        ]
        for (index, override) in overrides.enumerated() {
            let slot = 12 + index
            // The class and method are GOT-indirect, which the low bit marks.
            var descriptor = "%swift.method_override_descriptor { "
            descriptor += "i32 add (" + Self.relative(to: "@\"got.\(superMangled)Mn\"", fromField: field([0, slot, 0])) + ", i32 1), "
            descriptor += "i32 add (" + Self.relative(to: "@\"got.\(override.baseMethodDescriptor)\"", fromField: field([0, slot, 1])) + ", i32 1), "
            descriptor += Self.relative(to: "@\"\(override.implementation)\"", fromField: field([0, slot, 2]))
            descriptor += " }"
            values.append(descriptor)
        }
        var out = ""
        for override in overrides {
            out += "@\"got.\(override.baseMethodDescriptor)\" = private unnamed_addr constant ptr @\"\(override.baseMethodDescriptor)\"\n"
        }
        out += "@\"\(mangled)Mn\" = constant \(type) <{ \(values.joined(separator: ", ")) }>, section \"__TEXT,__constg_swiftt\", align 4\n"
        return out
    }

    /// The record that puts this type in `__swift5_types`, so the runtime can
    /// find it by name, and the ObjC class list entry.
    func typeRecord(mangled: String) -> String {
        var out = "@\"\(mangled)Hn\" = private constant %swift.type_metadata_record { "
        out += Self.relative(to: "@\"\(mangled)Mn\"", fromField: "ptr @\"\(mangled)Hn\"")
        out += " }, section \"__TEXT, __swift5_types, regular\", no_sanitize_address, align 4\n"
        out += "@\"objc_classes_\(mangled)N\" = internal global ptr @\"\(mangled)N\", section \"__DATA,__objc_classlist,regular,no_dead_strip\", no_sanitize_address, align 8\n"
        out += "@llvm.used = appending global [5 x ptr] [ptr @\"\(mangled)Mn\", ptr @\"\(mangled)Ma\", ptr @\"\(mangled)MF\", ptr @\"\(mangled)Hn\", ptr @\"objc_classes_\(mangled)N\"], section \"llvm.metadata\"\n"
        out += "@llvm.compiler.used = appending global [1 x ptr] [ptr @\"\(mangled)Mf\"], section \"llvm.metadata\"\n"
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

    /// The superclass's vtable with each override's slot replaced.
    func resolvedVTable() throws -> [String] {
        var vtable = superclass.vtable
        for override in overrides {
            guard vtable.indices.contains(override.vtableSlot) else {
                throw UnsupportedLayout(reason: "override of \(override.implementation) names vtable slot \(override.vtableSlot), and \(superclass.name) has \(vtable.count)")
            }
            vtable[override.vtableSlot] = override.implementation
        }
        return vtable
    }

    /// The LLVM struct type of the metadata global, which varies with the
    /// number of field-offset and vtable slots.
    func metadataType(vtable: [String]) -> String {
        let fixed = "ptr, ptr, ptr, i64, ptr, ptr, ptr, i64, i32, i32, i32, i16, i16, i32, i32, ptr, ptr"
        let offsets = superclass.fieldOffsets.map { _ in "i64" }
        let slots = vtable.map { _ in "ptr" }
        return "<{ " + ([fixed] + offsets + slots).joined(separator: ", ") + " }>"
    }

    func metadata(mangled: String, superMangled: String, objcName: String, vtable: [String], classSize: Int) -> String {
        let type = metadataType(vtable: vtable)
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
            "i32 \(superclass.instanceSize)",
            "i16 \(superclass.alignMask)",
            "i16 0",
            "i32 \(classSize)",
            "i32 \(Self.classAddressPoint)",
            "ptr @\"\(mangled)Mn\"",
            "ptr null",
        ]
        values += superclass.fieldOffsets.map { "i64 \($0)" }
        values += vtable.map { "ptr @\"\($0)\"" }
        return "@\"\(mangled)Mf\" = internal global \(type) <{ \(values.joined(separator: ", ")) }>, align 8\n"
    }
}
