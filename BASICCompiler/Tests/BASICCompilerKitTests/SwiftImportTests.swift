import BASICCompilerKit
@testable import BASICDialectSwift
import Foundation
import Testing

/// Reading a Swift module's public API out of its symbol graph (R4.1).
///
/// The fixture is written here rather than checked in as JSON: a recorded
/// graph goes stale the first time the toolchain changes its format and
/// nothing fails. This builds a real package with the real `swift package
/// dump-symbol-graph` and reads what comes out.
struct SwiftSymbolGraphTests {
    static let source = """
    open class Shape {
        public var name: String
        public let sides: Int
        public init(name: String) { self.name = name; self.sides = 0 }
        open func area() -> Double { 0 }
        public func describe() -> String { name }
        public func scale(by factor: Double) {}
        public func compare(_ other: Shape) -> Bool { false }
        public func corners() -> [Int] { [] }
    }
    public final class Circle: Shape {
        public var radius: Double
        public init(radius: Double) { self.radius = radius; super.init(name: "circle") }
        public override func area() -> Double { 3.0 * radius * radius }
    }
    public final class Panel {
        public enum Finish { case matte, gloss }
        public var finish: Finish = .matte
        public init() {}
        public func refinish(_ to: Finish) {}
    }
    public func totalArea(_ shapes: [Shape]) -> Double { 0 }
    public enum Unit { case metric, imperial }
    public enum Outcome { case hit(Double), miss }
    """

    /// Builds a package and returns its symbol graph, once per run.
    static let graph: SwiftAPI? = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graph-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources/Shapes")
        try? FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let manifest = """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Shapes", products: [.library(name: "Shapes", targets: ["Shapes"])], targets: [.target(name: "Shapes")])
        """
        try? manifest.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try? source.write(to: sources.appendingPathComponent("Shapes.swift"), atomically: true, encoding: .utf8)
        let dump = try? ProcessRunner.run("/usr/bin/xcrun",
            ["swift", "package", "dump-symbol-graph", "--minimum-access-level", "public"],
            workingDirectory: root.path)
        guard dump?.exitCode == 0,
              let file = SwiftPackageResolver.find(named: "Shapes.symbols.json", under: root.appendingPathComponent(".build").path)
        else { return nil }
        return try? SwiftAPI.read(fileAt: file)
    }()

    @Test func readsClassesTheirMembersAndTheirInheritance() throws {
        let api = try #require(Self.graph, "could not build the fixture package")
        #expect(api.module == "Shapes")
        let shape = try #require(api.classes.first { $0.name == "Shape" })
        let circle = try #require(api.classes.first { $0.name == "Circle" })
        #expect(shape.isOpen)
        #expect(circle.isFinal)
        #expect(circle.superclassPrecise == shape.precise)
        #expect(api.class(precise: circle.superclassPrecise!)?.name == "Shape")
    }

    /// The point of reading the graph at all: nothing imported is mangled by
    /// basicc — the toolchain's own name is the one linked.
    @Test func carriesTheCanonicalMangledSymbols() throws {
        let api = try #require(Self.graph)
        let shape = try #require(api.classes.first { $0.name == "Shape" })
        let area = try #require(shape.methods.first { $0.name == "area" })
        #expect(area.symbol == "$s6Shapes5ShapeC4areaSdyF")
        #expect(area.isOverridable, "area is declared open")
        let scale = try #require(shape.methods.first { $0.name == "scale" })
        #expect(scale.symbol == "$s6Shapes5ShapeC5scale2byySd_tF")
        #expect(scale.parameters.map(\.name) == ["factor"])
        #expect(scale.parameters.map(\.label) == ["by"])
        #expect(scale.returns == .void)
        // An initializer's graph symbol is the initializing half; a caller
        // wants the allocating one.
        let initializer = try #require(shape.initializers.first)
        #expect(initializer.symbol.hasSuffix("cfc"))
        #expect(initializer.allocatingSymbol == "$s6Shapes5ShapeC4nameACSS_tcfC")
    }

    @Test func propertiesCarryTheirAccessorsAndMutability() throws {
        let api = try #require(Self.graph)
        let shape = try #require(api.classes.first { $0.name == "Shape" })
        let name = try #require(shape.properties.first { $0.name == "name" })
        #expect(name.type == .string)
        #expect(name.isSettable)
        #expect(name.getterSymbol == "$s6Shapes5ShapeC4nameSSvg")
        #expect(name.setterSymbol == "$s6Shapes5ShapeC4nameSSvs")
        let sides = try #require(shape.properties.first { $0.name == "sides" })
        #expect(sides.type == .int)
        #expect(!sides.isSettable, "a `let` is not settable")
    }

    /// The rule R4.8 sets: a member BASIC cannot spell is *listed*, never
    /// dropped. A binding layer that quietly loses half a framework rots
    /// without anyone noticing.
    @Test func unsupportedMembersAreSkippedWithAReason() throws {
        let api = try #require(Self.graph)
        let shape = try #require(api.classes.first { $0.name == "Shape" })
        // `[Int]` gained a BASIC spelling in R4.7: an array of numbers
        // crosses as a BASIC array in a VARIANT. `[Shape]` did not, and the
        // reason is not "not yet" — a BASIC array holds the runtime's own
        // records, and an imported object is the framework's.
        #expect(shape.methods.contains { $0.name == "corners" }, "[Int] crosses as a BASIC array")
        #expect(api.skipped.contains { $0.member.hasSuffix("totalArea(_:)") }, "[Shape] parameter")
        // A plain enum imports now (E2); one with a payload waits for E3/E4,
        // and is skipped with a reason rather than dropped.
        #expect(api.skipped.contains { $0.member.contains("Outcome") }, "payload enums arrive with E3/E4")
        for skip in api.skipped {
            #expect(!skip.reason.isEmpty, "\(skip.member) was skipped with no reason")
        }
    }

    /// A class parameter and return are supported — that is the whole point
    /// of importing a framework of objects.
    /// An array of scalars, both ways (R4.7).
    ///
    /// `[T]` is not a new BASIC type: it is the array a BASIC function
    /// already hands back, carried in a VARIANT, so `LEN(v)` and `v(i)` walk
    /// it and nothing in the language had to change.
    @Test func arraysOfScalarsCrossAsBASICArrays() throws {
        let api = try #require(Self.graph)
        let shape = try #require(api.classes.first { $0.name == "Shape" })
        let corners = try #require(shape.methods.first { $0.name == "corners" })
        #expect(corners.returns == .array(element: .int))
        #expect(SwiftInterfaceUnit.basicType(corners.returns, in: api) == "VARIANT")
        // The shape emitted IR cannot call directly, so it goes through a
        // generated shim — the same route an async or handler method takes.
        #expect(SwiftObjectModel.needsShim(corners))
    }

    /// A plain Swift enum imports as the BASIC ENUM it already is (E2).
    ///
    /// Members count from 0 in case order — the order the shim converts by —
    /// and an enum with a payload is reported, not imported.
    @Test func plainEnumsImportAsBASICEnums() throws {
        let api = try #require(Self.graph)
        let unit = try #require(api.enumerations.values.first { $0.name == "Unit" })
        #expect(unit.cases == ["metric", "imperial"], "case order is declaration order")
        #expect(!api.skipped.contains { $0.member == "Unit" })
        #expect(!api.enumerations.values.contains { $0.name == "Outcome" }, "a payload enum is not plain")
        let rendered = SwiftInterfaceUnit(api: api).render()
        #expect(rendered.contains("ENUM Unit\n  metric\n  imperial\nEND ENUM"), "got:\n\(rendered)")
    }

    /// A nested type, referenced by its qualified path (E2).
    ///
    /// The graph spells `Panel.Finish` as two identifiers with a dot between.
    /// Reading the first one took it for `Panel` itself — a property typed as
    /// its own class — and a *parameter* of that shape was unsupported
    /// outright, which is how TUIKit's `Button.Role` never imported.
    @Test func nestedTypesResolveByTheirWholePath() throws {
        let api = try #require(Self.graph)
        let finish = try #require(api.enumerations.values.first { $0.swiftName == "Panel.Finish" })
        #expect(finish.name == "Panel_Finish", "a BASIC type name has no dot")
        let panel = try #require(api.classes.first { $0.name == "Panel" })
        #expect(panel.properties.first { $0.name == "finish" }?.type == .enumeration(precise: finish.precise))
        #expect(panel.methods.first { $0.name == "refinish" }?.parameters.first?.type == .enumeration(precise: finish.precise))
    }

    @Test func classTypesAreCarriedByPreciseIdentifier() throws {
        let api = try #require(Self.graph)
        let shape = try #require(api.classes.first { $0.name == "Shape" })
        let compare = try #require(shape.methods.first { $0.name == "compare" })
        #expect(compare.parameters.first?.type == .object(precise: shape.precise))
        #expect(compare.parameters.first?.label == nil, "an `_` label")
        #expect(compare.returns == .bool)
    }
}

/// `IMPORT "Shapes"` in a BASIC program, end to end (R4).
///
/// Builds a Swift package, writes a BASIC program that imports it, compiles
/// with `--dialect swift`, runs it, and checks what it printed. Nothing here
/// is mocked: the framework is really built by SwiftPM, its API really read
/// from its symbol graph, and its methods really called by mangled symbol.
struct SwiftImportEndToEndTests {
    static let framework = """
    open class Shape {
        public var name: String
        public init(name: String) { self.name = name }
        open func area() -> Double { 0 }
        public func describe() -> String { "\\(name) area \\(area())" }
        public func rename(_ to: String) { name = to }
        public func sides() -> Int { 0 }
        public func labels(_ names: [String]) -> [String] { names.map { "\\($0)!" } }
    }
    public final class Rect: Shape {
        public var width: Double
        public var height: Double
        public init(width: Double, height: Double) {
            self.width = width; self.height = height
            super.init(name: "rect")
        }
        public override func area() -> Double { width * height }
    }
    """

    static let program = """
    IMPORT "Shapes"

    DIM R AS Rect
    R = NEW Rect(3, 4)
    PRINT R.area()
    PRINT R.width; R.height
    R.width = 5
    PRINT R.area()
    PRINT R.describe()
    R.rename("box")
    PRINT R.name
    PRINT R.sides()
    DIM S AS Shape
    S = NEW Shape("plain")
    PRINT S.describe()
    DIM N(1) AS STRING
    N(0) = "a"
    N(1) = "b"
    DIM L AS VARIANT
    L = S.labels(N)
    PRINT L(0); L(1); LEN(L)
    """

    /// A program the Swift dialect must refuse: a BASIC array cannot hold an
    /// imported object. It used to compile and then die on the first read.
    static let refused = """
    IMPORT "Shapes"
    DIM Boxes(2) AS Rect
    PRINT "unreachable"
    """

    /// What the program must print.
    ///
    /// `34` is BASIC's `;` putting two numbers together with nothing between
    /// them, which is the interpreter's rule and so this compiler's.
    /// `describe()` is the interesting line: it is Swift's, it interpolates a
    /// Swift String, and the `area()` it calls is Rect's override —
    /// dispatched inside Swift, from a call BASIC made.
    static let expected = """
    12
    34
    20
    rect area 20.0
    box
    0
    plain area 0.0
    a!b!2

    """

    @Test func aBASICProgramImportsAndDrivesASwiftFramework() throws {
        let toolchain = try #require(FileManager.default.fileExists(atPath: Self.compiler) ? true : nil,
                                     "basicc must be built at \(Self.compiler)")
        _ = toolchain
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // The framework, as an ordinary SwiftPM package.
        let package = root.appendingPathComponent("Shapes")
        let sources = package.appendingPathComponent("Sources/Shapes")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Shapes", products: [.library(name: "Shapes", targets: ["Shapes"])], targets: [.target(name: "Shapes")])
        """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.framework.write(to: sources.appendingPathComponent("Shapes.swift"), atomically: true, encoding: .utf8)

        // The program, whose own manifest names the framework — SwiftPM does
        // the dependency management, basicc only asks it where things are.
        let program = root.appendingPathComponent("Program")
        try FileManager.default.createDirectory(at: program, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Program", dependencies: [.package(path: "../Shapes")], targets: [])
        """.write(to: program.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let source = program.appendingPathComponent("main.bas")
        try Self.program.write(to: source, atomically: true, encoding: .utf8)

        let binary = root.appendingPathComponent("run-program").path
        let build = try ProcessRunner.run(Self.compiler, ["build", source.path, "--dialect", "swift", "-o", binary])
        #expect(build.exitCode == 0, "compile failed: \(build.stderr)\(build.stdout)")

        let run = try ProcessRunner.run(binary, [])
        #expect(run.exitCode == 0, "run failed: \(run.stderr)")
        #expect(run.stdout == Self.expected, "got:\n\(run.stdout)")

        // The same framework, and a program that must not build. A refusal
        // is only worth having if it fires, and this is the shape that used
        // to produce a binary that segfaulted on the first element read.
        let bad = program.appendingPathComponent("refused.bas")
        try Self.refused.write(to: bad, atomically: true, encoding: .utf8)
        let refused = try ProcessRunner.run(Self.compiler,
            ["build", bad.path, "--dialect", "swift", "-o", root.appendingPathComponent("never").path])
        #expect(refused.exitCode != 0, "an array of imported objects must be refused")
        #expect((refused.stderr + refused.stdout).contains("cannot hold an imported Rect"),
                "got: \(refused.stderr)\(refused.stdout)")

        // R4.8's tripwire. Not "does the program run" — that only exercises
        // the members this program happens to call. The probe compiles every
        // generated shim, type-checks every generated interface, emits every
        // thunk, and prints how much of the framework arrived. A binding
        // layer that quietly loses half a framework fails here.
        let probe = try ProcessRunner.run(Self.compiler, ["import-probe", source.path])
        #expect(probe.exitCode == 0, "probe failed: \(probe.stderr)\(probe.stdout)")
        #expect(probe.stdout.contains("shims compiled, interfaces type-check, thunks emit"))
        let coverage = try #require(probe.stdout.split(separator: "\n")
            .first { $0.contains("members imported") }.map(String.init))
        // The count itself, so a regression that halves the surface is a
        // failure rather than a smaller number nobody reads.
        #expect(coverage.contains("11 of 11 members imported (100%)"), "got: \(coverage)")
    }

    /// The compiler under test, built into this package's scratch path.
    static var compiler: String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for scratch in [".build-claude", ".build"] {
            let candidate = root.appendingPathComponent("\(scratch)/debug/basicc").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return root.appendingPathComponent(".build/debug/basicc").path
    }
}

/// Asking `swiftc` what a module's symbols are called, instead of computing
/// them (R0.5).
struct SwiftManglingProbeTests {
    static let root = "/Users/bobby/src/AIBasic/Code/BASICCompiler"

    /// Where BASICRTSwift's module lives, for the probe's `import`.
    static var searchPaths: [String] {
        [".build-claude/release/Modules", ".build-claude/debug/Modules",
         ".build/release/Modules", ".build/debug/Modules"]
            .map { (root as NSString).appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// The cases a hand-written mangler got wrong, and the one nobody could
    /// explain: `XYRoids` is shaped like `AbRoids` and mangles differently.
    @Test func namesSwiftCompressesComeBackRight() throws {
        let probe = SwiftManglingProbe(module: "Roids", declarations: [
            .init(name: "Sprite"), .init(name: "RoidsSprite"),
            .init(name: "AbRoids"), .init(name: "XYRoids"),
        ])
        let symbols = try probe.run(searchPaths: Self.searchPaths)
        #expect(symbols.classes["Sprite"] == "$s5Roids6SpriteC")
        #expect(symbols.classes["RoidsSprite"] == "$s5Roids0A6SpriteC")
        #expect(symbols.classes["AbRoids"] == "$s5Roids02AbA0C")
        #expect(symbols.classes["XYRoids"] == "$s5Roids7XYRoidsC")
    }

    /// Signatures the hand-written mangler refused, because Swift compresses
    /// a repeated type: `f(Double) -> Double` is `yS2dF`, not `SdSdF`.
    @Test func signaturesWithRepeatedTypesComeBackRight() throws {
        let probe = SwiftManglingProbe(module: "Shapes", declarations: [
            .init(name: "Box", methods: [
                (name: "area", parameters: [], returns: "Swift.Double"),
                (name: "setX", parameters: ["Swift.Double"], returns: nil),
                (name: "scaled", parameters: ["Swift.Double"], returns: "Swift.Double"),
                (name: "resize", parameters: ["Swift.Double", "Swift.Double"], returns: nil),
                (name: "label", parameters: [], returns: "Swift.String"),
            ]),
        ])
        let symbols = try probe.run(searchPaths: Self.searchPaths)
        #expect(symbols.member("area", of: "Box") == "$s6Shapes3BoxC4areaSdyF")
        #expect(symbols.member("setX", of: "Box") == "$s6Shapes3BoxC4setXyySdF")
        // The two the hand mangler refused outright.
        #expect(symbols.member("scaled", of: "Box") == "$s6Shapes3BoxC6scaledyS2dF")
        #expect(symbols.member("resize", of: "Box") == "$s6Shapes3BoxC6resizeyySd_SdtF")
        #expect(symbols.member("label", of: "Box") == "$s6Shapes3BoxC5labelSSyF")
    }

    @Test func propertiesAndInitializersComeBackToo() throws {
        let probe = SwiftManglingProbe(module: "Shapes", declarations: [
            .init(name: "Box", properties: [(name: "width", type: "Swift.Double")]),
        ])
        let symbols = try probe.run(searchPaths: Self.searchPaths)
        #expect(symbols.member("width.get", of: "Box") == "$s6Shapes3BoxC5widthSdvg")
        #expect(symbols.member("width.set", of: "Box") == "$s6Shapes3BoxC5widthSdvs")
        #expect(symbols.member("init", of: "Box") == "$s6Shapes3BoxCACycfC")
    }

    /// A subclass's symbols, so a hierarchy comes back whole.
    @Test func subclassesAreProbedWithTheirBases() throws {
        let probe = SwiftManglingProbe(module: "Shapes", declarations: [
            .init(name: "Shape", methods: [(name: "area", parameters: [], returns: "Swift.Double")]),
            .init(name: "Rect", base: "Shape", methods: [(name: "area", parameters: [], returns: "Swift.Double")]),
        ])
        let symbols = try probe.run(searchPaths: Self.searchPaths)
        #expect(symbols.metadata(of: "Shape") == "$s6Shapes5ShapeCN")
        #expect(symbols.metadata(of: "Rect") == "$s6Shapes4RectCN")
        #expect(symbols.member("area", of: "Rect") == "$s6Shapes4RectC4areaSdyF")
    }
}
