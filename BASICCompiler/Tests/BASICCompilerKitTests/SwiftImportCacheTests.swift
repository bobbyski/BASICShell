import BASICCompilerKit
@testable import BASICDialectSwift
import Foundation
import Testing

/// Build, gather, remove (`Documents/BASICC_IMPORTS_WITHOUT_BUILDS.md`): an import's
/// build folder is gone as soon as the compile has what it needs, the import cache
/// entry that replaces it is reused until the package changes, and an interrupted
/// basicc leaves neither a folder nor a build behind.
///
/// ActiveUI's `.build-basicc` reached 45 GB on 2026-11-08 under a retry loop; these
/// use a small package of their own, and a cache in their own folder.
@Suite(.serialized)
struct SwiftImportCacheTests {
    /// A package `Shapes`, a program importing it, and a cache, in one new folder.
    private func scene() throws -> (root: URL, package: URL, program: URL, cache: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-cache-\(UUID().uuidString)")
        let package = root.appendingPathComponent("Shapes")
        let sources = package.appendingPathComponent("Sources/Shapes")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Shapes", products: [.library(name: "Shapes", targets: ["Shapes"])], targets: [.target(name: "Shapes")])
        """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try SwiftImportEndToEndTests.framework.write(to: sources.appendingPathComponent("Shapes.swift"), atomically: true, encoding: .utf8)
        let program = root.appendingPathComponent("Program")
        try FileManager.default.createDirectory(at: program, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Program", dependencies: [.package(path: "../Shapes")], targets: [])
        """.write(to: program.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try SwiftImportEndToEndTests.program.write(to: program.appendingPathComponent("main.bas"), atomically: true, encoding: .utf8)
        return (root, package, program, root.appendingPathComponent("cache"))
    }

    private func environment(cache: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["BASICC_IMPORT_CACHE"] = cache.path
        return environment
    }

    private func compile(_ program: URL, cache: URL, into binary: URL) throws -> ProcessRunner.Result {
        try ProcessRunner.run(SwiftImportEndToEndTests.compiler,
                              ["build", program.appendingPathComponent("main.bas").path, "--dialect", "swift", "-o", binary.path],
                              environment: environment(cache: cache))
    }

    @Test("The build folder is gone after the compile; the entry is recorded, reused, and replaced when the package changes")
    func buildGatherRemove() throws {
        try #require(FileManager.default.fileExists(atPath: SwiftImportEndToEndTests.compiler), "basicc must be built")
        let (root, package, program, cache) = try scene()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("shapes-run")
        let scratch = package.appendingPathComponent(".build-basicc")

        // The first compile builds Shapes once, keeps what it needs, removes the folder.
        let first = try compile(program, cache: cache, into: binary)
        #expect(first.exitCode == 0, "compile failed: \(first.stderr)\(first.stdout)")
        #expect(first.stderr.contains("basicc: Shapes: built once; kept "), "got: \(first.stderr)")
        #expect(!FileManager.default.fileExists(atPath: scratch.path), "the build folder is removed")
        let run = try ProcessRunner.run(binary.path, [], environment: TestBuild.programEnvironment)
        #expect(run.stdout == SwiftImportEndToEndTests.expected, "got:\n\(run.stdout)")

        // What was kept, and how big it is.
        let entries = SwiftImportCache(root: cache.path).entries()
        let shapes = try #require(entries.first { $0.module == "Shapes" })
        #expect(entries.count == 1)
        #expect(shapes.sizes.total > 0 && shapes.sizes.objects > 0 && shapes.sizes.graph > 0)
        #expect(shapes.sizes.buildFolder > shapes.sizes.total, "kept less than the build folder held")
        #expect(shapes.sizes.total == SwiftImportCache.size(of: cache.appendingPathComponent("Shapes").path))

        // The second compile reuses it: no build, no folder.
        let second = try compile(program, cache: cache, into: binary)
        #expect(second.exitCode == 0, "compile failed: \(second.stderr)\(second.stdout)")
        #expect(!second.stderr.contains("built once"), "reused, not rebuilt: \(second.stderr)")
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        #expect(try ProcessRunner.run(binary.path, [], environment: TestBuild.programEnvironment).stdout == SwiftImportEndToEndTests.expected)

        // A changed package builds once more; its entry replaces the old one.
        let source = package.appendingPathComponent("Sources/Shapes/Shapes.swift")
        try (SwiftImportEndToEndTests.framework + "\npublic func shapesVersion() -> Int { 2 }\n")
            .write(to: source, atomically: true, encoding: .utf8)
        let third = try compile(program, cache: cache, into: binary)
        #expect(third.exitCode == 0, "compile failed: \(third.stderr)\(third.stdout)")
        #expect(third.stderr.contains("basicc: Shapes: built once"), "rebuilt for the change: \(third.stderr)")
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { !$0.hasSuffix(".lock") }
        #expect(kept == ["Shapes"], "one entry per module: \(kept)")
    }

    @Test("Two compiles at once build the package once: the second waits, then reuses the entry")
    func oneBuildAtATime() throws {
        try #require(FileManager.default.fileExists(atPath: SwiftImportEndToEndTests.compiler), "basicc must be built")
        let (root, package, program, cache) = try scene()
        defer { try? FileManager.default.removeItem(at: root) }
        func start(_ name: String) throws -> (Process, URL) {
            let log = root.appendingPathComponent("\(name).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let basicc = Process()
            basicc.executableURL = URL(fileURLWithPath: SwiftImportEndToEndTests.compiler)
            basicc.arguments = ["build", program.appendingPathComponent("main.bas").path, "--dialect", "swift",
                                "-o", root.appendingPathComponent("\(name)-run").path]
            basicc.environment = environment(cache: cache)
            basicc.standardOutput = FileHandle.nullDevice
            basicc.standardError = try FileHandle(forWritingTo: log)
            try basicc.run()
            return (basicc, log)
        }
        let (first, firstLog) = try start("first")
        let (second, secondLog) = try start("second")
        first.waitUntilExit()
        second.waitUntilExit()
        let logs = try [firstLog, secondLog].map { try String(contentsOf: $0, encoding: .utf8) }
        #expect(first.terminationStatus == 0 && second.terminationStatus == 0, "\(logs)")
        #expect(logs.filter { $0.contains("basicc: Shapes: built once") }.count == 1, "built exactly once: \(logs)")
        #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent(".build-basicc").path))
    }

    @Test("An entry over its budget is warned about, naming its biggest part")
    func budget() {
        var sizes = SwiftImportCache.Sizes()
        sizes.objects = 30_000_000
        sizes.modules = 6_000_000
        sizes.graph = 4_000_000
        sizes.total = 40_000_000
        #expect(SwiftImportCache.budgetWarning(module: "ActiveUI", sizes: sizes) == nil)
        sizes.objects = 130_000_000
        sizes.total = 140_000_000
        let warning = SwiftImportCache.budgetWarning(module: "ActiveUI", sizes: sizes)
        #expect(warning == "basicc: warning: ActiveUI's import cache entry is 140 MB, over its 100 MB budget; the biggest part is objects (130 MB)")
    }

    @Test("An interrupted basicc stops its build and removes the build folder")
    func interruptedBuildCleansUp() throws {
        try #require(FileManager.default.fileExists(atPath: SwiftImportEndToEndTests.compiler), "basicc must be built")
        let (root, package, program, cache) = try scene()
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = package.appendingPathComponent(".build-basicc")

        let basicc = Process()
        basicc.executableURL = URL(fileURLWithPath: SwiftImportEndToEndTests.compiler)
        basicc.arguments = ["build", program.appendingPathComponent("main.bas").path, "--dialect", "swift",
                            "-o", root.appendingPathComponent("never").path]
        basicc.environment = environment(cache: cache)
        basicc.standardOutput = FileHandle.nullDevice
        basicc.standardError = FileHandle.nullDevice
        try basicc.run()

        // As soon as the build has started, stop basicc the way `timeout` does.
        let start = Date()
        while !FileManager.default.fileExists(atPath: scratch.path), basicc.isRunning, Date().timeIntervalSince(start) < 120 {
            Thread.sleep(forTimeInterval: 0.02)
        }
        try #require(basicc.isRunning, "the build ended before it could be interrupted")
        Thread.sleep(forTimeInterval: 1)
        basicc.terminate()
        basicc.waitUntilExit()

        #expect(basicc.terminationStatus == 128 + SIGTERM)
        #expect(!FileManager.default.fileExists(atPath: scratch.path), "the build folder is removed")
        // Nothing still building in the package's folder.
        let left = try ProcessRunner.run("/bin/ps", ["-axo", "command"]).stdout
            .split(separator: "\n").filter { $0.contains(package.path) && !$0.contains("/bin/ps") }
        #expect(left.isEmpty, "still running: \(left)")
        #expect(SwiftImportCache(root: cache.path).entries().isEmpty, "nothing half-made is kept")
    }
}
