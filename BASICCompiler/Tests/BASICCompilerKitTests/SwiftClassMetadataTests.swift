@testable import BASICCompilerKit
@testable import BASICDialectSwift
import Foundation
import Testing

/// Rev 2's load-bearing claim, measured rather than asserted: a class whose
/// metadata `basicc` emitted is a real Swift class, in both directions.
///
/// The test compiles a Swift module (standing in for an imported framework),
/// emits a subclass of it with ``SwiftClassMetadata`` and nothing else, links
/// the two, and runs the result. It then compiles a *Swift* subclass of the
/// emitted class against the generated interface and runs that too.
///
/// It is slow — several `swiftc` invocations — and it is worth it. This is the
/// one thing in Rev 2 that cannot be proved by reading.
struct SwiftClassMetadataTests {
    /// One toolchain for every step. Mixing `xcrun`'s Swift with a
    /// `swiftly`-installed one fails at `import` with "compiled module was
    /// created by an older version of the compiler", which reads like a
    /// metadata bug and is not one.
    static let swiftc: String = {
        (try? ProcessRunner.run("/usr/bin/xcrun", ["--find", "swiftc"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "swiftc"
    }()

    /// The triple this toolchain compiles for by default.
    ///
    /// Not `TargetTriple.host`: that is the compiler's own deployment target
    /// (`macosx16.0`), and a generated `.swiftinterface` has to name the
    /// triple the *toolchain* uses or the module it produces is rejected as
    /// "no such module" — which reads like a missing file and is not one.
    static let hostSwiftTarget: String = {
        guard let info = try? ProcessRunner.run(swiftc, ["-print-target-info"]).stdout,
              let data = info.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let target = json["target"] as? [String: Any],
              let triple = target["triple"] as? String
        else { return TargetTriple.host.rawValue }
        return triple
    }()

    /// The SDK. `-frontend` bypasses the driver, and the driver is what
    /// normally supplies this — without it the frontend cannot find the
    /// standard library and says so in terms of the target instead.
    static let sdk: String = {
        (try? ProcessRunner.run("/usr/bin/xcrun", ["--show-sdk-path"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }()

    static let clang: String = {
        (try? ProcessRunner.run("/usr/bin/xcrun", ["--find", "clang"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "clang"
    }()

    /// The framework being imported, in the role TUIKit will play.
    static let baseSource = """
    open class BASICObject {
        public var tag: Int
        public init(tag: Int) { self.tag = tag }
        open func describe() -> Int { tag }
    }
    """

    /// `BASICObject`'s shape, as a binding generator would record it: the
    /// vtable in slot order, one stored property at offset 16.
    static let base = SwiftClassMetadata.Superclass(
        module: "Base",
        name: "BASICObject",
        vtable: [
            "$s4Base11BASICObjectC3tagSivg",
            "$s4Base11BASICObjectC3tagSivs",
            "$s4Base11BASICObjectC3tagSivM",
            "$s5Roids7BSpriteC3tagACSi_tcfC",
            "$s4Base11BASICObjectC8describeSiyF",
        ],
        fieldOffsets: [16],
        fieldOffsetVectorOffset: 16,
        instanceSize: 24
    )

    /// What the code generator will emit around the metadata: the imported
    /// symbols, and the bodies of the BASIC class's own members.
    ///
    /// ```basic
    ///   CLASS BSprite
    ///       INHERITS BASICObject
    ///       FUNCTION Describe() AS INTEGER OVERRIDES
    ///           RETURN Tag * 100
    ///       END FUNCTION
    ///   END CLASS
    /// ```
    static let bodies = """
    @"$s4Base11BASICObjectCN"  = external global %swift.type, align 8
    @"$s4Base11BASICObjectCMm" = external global %objc_class, align 8
    @"$s4Base11BASICObjectCMn" = external global %swift.type_descriptor, align 4
    @"$s4Base11BASICObjectC8describeSiyFTq" = external global %swift.method_descriptor, align 4
    @"$s4Base11BASICObjectC3tagACSi_tcfCTq" = external global %swift.method_descriptor, align 4
    declare swiftcc i64 @"$s4Base11BASICObjectC3tagSivg"(ptr swiftself)
    declare swiftcc void @"$s4Base11BASICObjectC3tagSivs"(i64, ptr swiftself)
    declare swiftcc { ptr, ptr } @"$s4Base11BASICObjectC3tagSivM"(ptr noalias dereferenceable(32), ptr swiftself)
    declare swiftcc i64 @"$s4Base11BASICObjectC8describeSiyF"(ptr swiftself)

    ; FUNCTION Describe() AS INTEGER OVERRIDES : RETURN Tag * 100
    define swiftcc i64 @"$s5Roids7BSpriteC8describeSiyF"(ptr swiftself %self) {
      %p = getelementptr inbounds i8, ptr %self, i64 16
      %tag = load i64, ptr %p, align 8
      %out = mul i64 %tag, 100
      ret i64 %out
    }

    ; the constructor, in Swift's two halves: initialise, and allocate-then-initialise
    define swiftcc ptr @"$s5Roids7BSpriteC3tagACSi_tcfc"(i64 %tag, ptr swiftself %self) {
      %p = getelementptr inbounds i8, ptr %self, i64 16
      store i64 %tag, ptr %p, align 8
      ret ptr %self
    }
    define swiftcc ptr @"$s5Roids7BSpriteC3tagACSi_tcfC"(i64 %tag, ptr swiftself %type) {
      %obj = call ptr @swift_allocObject(ptr %type, i64 24, i64 7)
      %r = call swiftcc ptr @"$s5Roids7BSpriteC3tagACSi_tcfc"(i64 %tag, ptr swiftself %obj)
      ret ptr %r
    }
    define swiftcc ptr @"$s5Roids7BSpriteCfd"(ptr swiftself %self) { ret ptr %self }

    ; what `LET s = NEW BSprite(7)` lowers to: our metadata, then the constructor
    define ptr @roids_new_bsprite(i64 %tag) {
      %r = call swiftcc ptr @"$s5Roids7BSpriteC3tagACSi_tcfC"(i64 %tag, ptr swiftself @"$s5Roids7BSpriteCN")
      ret ptr %r
    }
    define swiftcc void @"$s5Roids7BSpriteCfD"(ptr swiftself %self) {
      %o = call swiftcc ptr @"$s5Roids7BSpriteCfd"(ptr swiftself %self)
      call void @swift_deallocClassInstance(ptr %o, i64 24, i64 7)
      ret void
    }
    """

    /// The interface Rev 2 generates so Swift can see the class it emitted.
    static var generatedInterface: String { """
    // swift-interface-format-version: 1.0
    // swift-module-flags: -target \(hostSwiftTarget) -module-name Roids
    import Base
    import Swift
    open class BSprite : Base.BASICObject {
      override public init(tag: Swift.Int)
      override open func describe() -> Swift.Int
    }
    """ }

    /// The class under test: `BSprite`, overriding `describe` in vtable slot 4.
    static var sprite: SwiftClassMetadata {
        SwiftClassMetadata(
            module: "Roids",
            name: "BSprite",
            superclass: base,
            overrides: [
                SwiftClassMetadata.Override(
                    baseMethodDescriptor: "$s4Base11BASICObjectC8describeSiyFTq",
                    implementation: "$s5Roids7BSpriteC8describeSiyF",
                    vtableSlot: 4
                )
            ]
        )
    }

    /// Builds the base module and the emitted class into `directory`,
    /// returning the object file and the module search path.
    static func buildEmittedClass(in directory: URL) throws -> (object: String, modules: String) {
        let path = { (name: String) in directory.appendingPathComponent(name).path }
        try Self.baseSource.write(toFile: path("Base.swift"), atomically: true, encoding: .utf8)
        let modules = path("modules")
        try FileManager.default.createDirectory(atPath: modules, withIntermediateDirectories: true)
        let base = try ProcessRunner.run(swiftc, [
            "-emit-module", "-emit-library", "-module-name", "Base", path("Base.swift"),
            "-o", modules + "/libBase.dylib", "-emit-module-path", modules + "/Base.swiftmodule",
        ])
        #expect(base.exitCode == 0, "building the stand-in framework: \(base.stderr)")

        let ir = SwiftClassMetadata.preamble + Self.bodies + "\n" + (try sprite.render())
        try ir.write(toFile: path("roids.ll"), atomically: true, encoding: .utf8)
        let assembled = try ProcessRunner.run(clang, ["-c", path("roids.ll"), "-o", path("roids.o")])
        #expect(assembled.exitCode == 0, "assembling emitted metadata: \(assembled.stderr)")
        return (path("roids.o"), modules)
    }

    @Test func aBASICClassInheritsASwiftClassAndIsDispatchedToVirtually() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rev2-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = { (name: String) in directory.appendingPathComponent(name).path }

        let built = try Self.buildEmittedClass(in: directory)
        let harness = """
        import Base
        @_silgen_name("roids_new_bsprite")
        func makeSprite(_ tag: Int) -> BASICObject
        let sprite = makeSprite(7)
        print(sprite.describe())
        print(type(of: sprite))
        print(sprite is BASICObject)
        sprite.tag = 9
        print(sprite.describe())
        """
        try harness.write(toFile: path("harness.swift"), atomically: true, encoding: .utf8)
        let link = try ProcessRunner.run(Self.swiftc, [
            "-I", built.modules, "-L", built.modules, "-lBase",
            path("harness.swift"), built.object, "-o", path("run"),
            "-Xlinker", "-rpath", "-Xlinker", built.modules,
        ])
        #expect(link.exitCode == 0, "linking: \(link.stderr)")

        let run = try ProcessRunner.run(path("run"), [])
        // 700: the override ran, reached through the superclass's vtable slot.
        // BSprite: the runtime read our nominal type descriptor for the name.
        // 900: the inherited setter wrote the field our metadata laid out.
        #expect(run.stdout == "700\nBSprite\ntrue\n900\n", "got: \(run.stdout)\(run.stderr)")
    }

    @Test func aSwiftClassInheritsTheBASICClass() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rev2-subclass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = { (name: String) in directory.appendingPathComponent(name).path }

        let built = try Self.buildEmittedClass(in: directory)
        try Self.generatedInterface.write(toFile: path("Roids.swiftinterface"), atomically: true, encoding: .utf8)
        let module = try ProcessRunner.run(Self.swiftc, [
            "-frontend", "-compile-module-from-interface", path("Roids.swiftinterface"),
            "-o", built.modules + "/Roids.swiftmodule", "-I", built.modules,
            "-module-name", "Roids", "-target", Self.hostSwiftTarget, "-sdk", Self.sdk,
        ])
        #expect(module.exitCode == 0, "compiling the generated interface: \(module.stderr)")

        let client = """
        import Base
        import Roids
        final class SwiftShip: BSprite {
            var bonus = 5
            override func describe() -> Int { super.describe() + bonus }
        }
        let ship = SwiftShip(tag: 3)
        print(ship.describe())
        print((ship as BASICObject).describe())
        print(type(of: ship))
        """
        try client.write(toFile: path("client.swift"), atomically: true, encoding: .utf8)
        let link = try ProcessRunner.run(Self.swiftc, [
            "-I", built.modules, "-L", built.modules, "-lBase",
            "-target", Self.hostSwiftTarget,
            path("client.swift"), built.object, "-o", path("run"),
            "-Xlinker", "-rpath", "-Xlinker", built.modules,
        ])
        #expect(link.exitCode == 0, "linking a Swift subclass of a BASIC class: \(link.stderr)")

        let run = try ProcessRunner.run(path("run"), [])
        // 305 twice: super.describe() reached the body BASIC wrote (3 * 100),
        // and the Swift override is found through a base-class reference too.
        #expect(run.stdout == "305\n305\nSwiftShip\n", "got: \(run.stdout)\(run.stderr)")
    }

    @Test func newStoredPropertiesAreRefusedRatherThanLaidOutWrong() {
        let withField = SwiftClassMetadata(
            module: "Roids", name: "BSprite", superclass: Self.base,
            overrides: [], newStoredProperties: ["Bonus"]
        )
        #expect(throws: SwiftClassMetadata.UnsupportedLayout.self) { try withField.render() }
    }
}

/// The mangled names Rev 2 publishes have to be the ones `swiftc` would write.
struct SwiftManglingTests {
    @Test func plainNamesManglePositionally() throws {
        #expect(try SwiftMangling.mangleClass(module: "Roids", name: "Sprite") == "$s5Roids6SpriteC")
        #expect(try SwiftMangling.typeMetadata(module: "Base", name: "BASICObject") == "$s4Base11BASICObjectCN")
    }

    /// Measured against Swift 6.3.1: `RoidsSprite` in module `Roids` is
    /// `$s5Roids0A6SpriteC`, not `$s5Roids11RoidsSpriteC`. Emitting the plain
    /// form would produce a symbol no Swift client resolves, so it is refused.
    @Test func namesNeedingWordSubstitutionAreRefused() {
        #expect(throws: SwiftMangling.NeedsWordSubstitution.self) {
            try SwiftMangling.mangleClass(module: "Roids", name: "RoidsSprite")
        }
        #expect(throws: SwiftMangling.NeedsWordSubstitution.self) {
            try SwiftMangling.mangleClass(module: "Roids", name: "VectorSpriteVector")
        }
    }

    @Test func wordsSplitOnCapitals() {
        #expect(SwiftMangling.words(in: "VectorSpriteVector") == ["Vector", "Sprite", "Vector"])
        #expect(SwiftMangling.words(in: "Sprite") == ["Sprite"])
    }
}

/// The dialect is selectable, and says which one it chose.
struct SwiftDialectTests {
    @Test func theRegistryOffersBothDialectsAndKeepsTraditionalDefault() throws {
        let registry = DialectRegistry([TraditionalDialectStandIn(), SwiftDialect()])
        #expect(registry.identities.map(\.identifier) == ["traditional", "swift"])
        #expect(type(of: try registry.dialect(named: "swift")).identity.identifier == "swift")
    }

    @Test func aPackageManifestBesideTheProgramSelectsTheSwiftDialect() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rev2-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let program = directory.appendingPathComponent("main.bas").path
        try "PRINT 1\n".write(toFile: program, atomically: true, encoding: .utf8)

        #expect(SwiftDialect.inferredFromPackageManifest(at: program) == false)
        try "// swift-tools-version: 6.1\n".write(
            toFile: directory.appendingPathComponent("Package.swift").path,
            atomically: true, encoding: .utf8
        )
        #expect(SwiftDialect.inferredFromPackageManifest(at: program))
        // The directory itself answers the same way a file inside it does.
        #expect(SwiftDialect.inferredFromPackageManifest(at: directory.path))
    }

    @Test func loweringRefusesWithADiagnosticThatNamesTheWayOut() throws {
        let module = BIRModule(name: "demo")
        #expect(throws: CompileError.self) {
            try SwiftDialect().lower(module, options: CompileOptions())
        }
    }

    /// A stand-in default so this file does not depend on the traditional
    /// dialect's framework just to exercise registry ordering.
    struct TraditionalDialectStandIn: DialectCompiler {
        static let identity = DialectIdentity(
            identifier: "traditional", displayName: "Traditional",
            summary: "stand-in", isDefault: true
        )
        let semantics = SemanticProfile(strings: .exactBytes, importsSwiftFrameworks: false)
        func lower(_ module: BIRModule, options: CompileOptions) throws -> LoweredModule {
            LoweredModule(name: module.name, llvmIR: "")
        }
        func runtimeLibrary(for target: TargetTriple) -> RuntimeLibrary { RuntimeLibrary(name: "BASICRT") }
    }
}
