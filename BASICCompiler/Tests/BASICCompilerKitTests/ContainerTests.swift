@testable import BASICCompilerKit
import BASICDialectTraditional
import Foundation
import Testing

// `.basproj` and `.baslib` — the shapes a project arrives in.
//
// BASPROJ_AND_BASLIB.md §5 asks for one path that handles a zipped project,
// a project directory, a zipped library, and a loose file. These check the
// two the compiler grew: the zip, and libraries by name and by path.

@Suite("Projects and libraries")
struct ContainerTests {
    /// Writes a project and a library beside each other, and returns the
    /// directory holding them.
    private func scratch() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("basicc-container-test-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Zips `directory` into `<name>.basproj` or `.baslib` beside it.
    private func zip(_ directory: String, as name: String) throws -> String {
        let parent = (directory as NSString).deletingLastPathComponent
        let archive = (parent as NSString).appendingPathComponent(name)
        let result = try ProcessRunner.run("/usr/bin/zip", ["-qr", archive, (directory as NSString).lastPathComponent], workingDirectory: parent)
        #expect(result.exitCode == 0, Comment(rawValue: result.stderr))
        return archive
    }

    private func build(_ path: String, into output: String) throws -> String {
        try TestBuild.onDeepStack { try Compilation(dialect: TraditionalDialect()).build(sourcePath: path, output: output) }
        return try ProcessRunner.run(output, []).stdout
    }

    @Test func aZippedProjectBuildsLikeItsDirectory() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let project = (root as NSString).appendingPathComponent("Demo")
        try write(#"{ "schemaVersion": 1, "kind": "project", "name": "Demo", "entry": "Sources/main.bas" }"#,
                  to: (project as NSString).appendingPathComponent("project.json"))
        try write("IMPORT \"Sources/helper.bas\"\nPRINT \"Demo says \"; Greeting$()\n",
                  to: (project as NSString).appendingPathComponent("Sources/main.bas"))
        try write("FUNCTION Greeting$() AS STRING\nRETURN \"hello\"\nEND FUNCTION\n",
                  to: (project as NSString).appendingPathComponent("Sources/helper.bas"))

        let fromDirectory = try build(project, into: (root as NSString).appendingPathComponent("fromDirectory"))
        let archive = try zip(project, as: "Demo.basproj")
        let fromZip = try build(archive, into: (root as NSString).appendingPathComponent("fromZip"))
        #expect(fromDirectory == "Demo says hello\n")
        #expect(fromZip == fromDirectory)
    }

    @Test func aLibraryIsImportedByNameOrByPath() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let library = (root as NSString).appendingPathComponent("charts")
        try write(#"{ "schemaVersion": 1, "kind": "library", "name": "charts", "exports": ["Charts"] }"#,
                  to: (library as NSString).appendingPathComponent("library.json"))
        try write("FUNCTION Bar$(n AS INTEGER) AS STRING\nRETURN STRING$(n, \"#\")\nEND FUNCTION\n",
                  to: (library as NSString).appendingPathComponent("Sources/charts.bas"))
        let archive = try zip(library, as: "charts.baslib")

        let project = (root as NSString).appendingPathComponent("App")
        try write(#"{ "schemaVersion": 1, "kind": "project", "name": "App", "entry": "Sources/main.bas" }"#,
                  to: (project as NSString).appendingPathComponent("project.json"))
        try FileManager.default.createDirectory(atPath: (project as NSString).appendingPathComponent("Libraries"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: archive, toPath: (project as NSString).appendingPathComponent("Libraries/charts.baslib"))

        for spelling in ["charts", "Libraries/charts.baslib"] {
            try write("IMPORT \"\(spelling)\"\nPRINT \"chart: \"; Bar$(4)\n",
                      to: (project as NSString).appendingPathComponent("Sources/main.bas"))
            let output = try build(project, into: (root as NSString).appendingPathComponent("app-\(UUID().uuidString)"))
            #expect(output == "chart: ####\n", Comment(rawValue: "IMPORT \"\(spelling)\""))
        }
    }

    @Test func twoLibrariesOfferingTheSameModuleAreRefused() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let project = (root as NSString).appendingPathComponent("App")
        try write(#"{ "schemaVersion": 1, "kind": "project", "name": "App", "entry": "Sources/main.bas" }"#,
                  to: (project as NSString).appendingPathComponent("project.json"))
        try write("PRINT \"hi\"\n", to: (project as NSString).appendingPathComponent("Sources/main.bas"))
        for name in ["charts", "plots"] {
            let library = (project as NSString).appendingPathComponent("Libraries/\(name)")
            try write("{ \"schemaVersion\": 1, \"kind\": \"library\", \"name\": \"\(name)\", \"exports\": [\"Charts\"] }",
                      to: (library as NSString).appendingPathComponent("library.json"))
            try write("FUNCTION \(name.capitalized)$() AS STRING\nRETURN \"x\"\nEND FUNCTION\n",
                      to: (library as NSString).appendingPathComponent("Sources/\(name).bas"))
        }
        // Declaration order decides which library a *name* reaches; a module
        // offered by two of them cannot be decided that way, so it is
        // refused, naming both.
        #expect(throws: (any Error).self) {
            try TestBuild.onDeepStack {
                try Compilation(dialect: TraditionalDialect()).build(
                    sourcePath: project, output: (root as NSString).appendingPathComponent("app")
                )
            }
        }
    }
}

/// The protocol the IDEs reach a compiler through (BASIC_COMPILER.md 7.6).
@Suite("The IDE-facing compiler protocol")
struct LanguageCompilerTests {
    private func compiler() -> any LanguageCompiler { Compilation(dialect: TraditionalDialect()) }

    @Test func itNamesTheLanguageAndWhatItBuilds() {
        #expect(Compilation.languageIdentifier == "basic")
        #expect(Compilation.sourceExtensions == ["bas"])
        #expect(Compilation.containerExtensions == ["basproj", "baslib"])
    }

    @Test func itKnowsWhatItCanBuild() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("basicc-protocol-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let source = (root as NSString).appendingPathComponent("hello.bas")
        try "PRINT \"hi\"\n".write(toFile: source, atomically: true, encoding: .utf8)

        let compiler = compiler()
        #expect(compiler.canBuild(path: source))
        #expect(compiler.canBuild(path: "/somewhere/app.basproj"))
        #expect(!compiler.canBuild(path: (root as NSString).appendingPathComponent("notes.txt")))
    }

    @Test func itBuildsAndReportsWhatIsWrong() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("basicc-protocol-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let good = (root as NSString).appendingPathComponent("good.bas")
        try "PRINT \"hi\"\n".write(toFile: good, atomically: true, encoding: .utf8)
        let compiler = compiler()
        #expect(compiler.diagnostics(for: good).isEmpty)
        let built = try TestBuild.onDeepStack {
            compiler.build(path: good, output: (root as NSString).appendingPathComponent("good"))
        }
        #expect(built.succeeded)
        #expect(built.artifact != nil)
        #expect(built.diagnostics.isEmpty)

        // A build that cannot happen comes back as diagnostics, not as an
        // error: an IDE shows them the same way either way.
        let bad = (root as NSString).appendingPathComponent("bad.bas")
        try "PRINT 1 +\n".write(toFile: bad, atomically: true, encoding: .utf8)
        let failed = try TestBuild.onDeepStack {
            compiler.build(path: bad, output: (root as NSString).appendingPathComponent("bad"))
        }
        #expect(!failed.succeeded)
        #expect(failed.artifact == nil)
        #expect(!failed.diagnostics.isEmpty)
        #expect(!compiler.diagnostics(for: bad).isEmpty)
    }
}
