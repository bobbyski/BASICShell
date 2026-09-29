@testable import BASICCompilerKit
import BASICDialectTraditional
import BASICSyntax
import Foundation
import Testing

/// Builds and runs programs through the whole pipeline, in a temp directory.
enum TestBuild {
    static let programsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Programs")

    /// The interpreter, when the sibling package has been built.
    ///
    /// `BASIC_INTERPRETER` names one explicitly. Without it the default build
    /// directory is used, which can hold an interpreter older than the
    /// language: a feature landed in the interpreter and the compiler at once
    /// then "fails parity" against a binary that predates it. The override
    /// lets a run name the interpreter it just built rather than whatever was
    /// last left in `.build`.
    static let interpreter: String? = {
        if let named = ProcessInfo.processInfo.environment["BASIC_INTERPRETER"],
           FileManager.default.isExecutableFile(atPath: named) {
            return named
        }
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BASICShell/.build/debug/BASICShell").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()

    struct Run {
        let stdout: String
        let exitCode: Int32
    }

    /// Runs `body` on a thread with a real stack. The lowering recurses
    /// through an expression's structure, and swift-testing runs a test on
    /// the cooperative pool, whose stacks are far smaller than the main
    /// thread `basicc` itself compiles on — a deeply nested expression
    /// overflows one.
    static func onDeepStack<T>(_ body: @escaping () throws -> T) throws -> T {
        var result: Result<T, Error>?
        let thread = Thread { result = Result { try body() } }
        thread.stackSize = 16 << 20
        thread.start()
        while !thread.isFinished { usleep(200) }
        return try result!.get()
    }

    /// Compiles the program at `path` and runs it.
    static func run(path: String) throws -> Run {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("basicc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let output = workDir.appendingPathComponent("program").path
        try onDeepStack { try Compilation(dialect: TraditionalDialect()).build(sourcePath: path, output: output) }
        let result = try ProcessRunner.run(output, [])
        return Run(stdout: result.stdout, exitCode: result.exitCode)
    }

    /// Compiles program text and runs it.
    static func run(source: String) throws -> Run {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("basicc-\(UUID().uuidString).bas").path
        try source.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        return try run(path: path)
    }

    /// Runs the interpreter on the program, when available.
    static func interpret(path: String) throws -> String? {
        guard let interpreter else { return nil }
        let result = try ProcessRunner.run(interpreter, [path])
        return result.stdout
    }

    /// Every `.bas` under Tests/Programs, sorted.
    static var programs: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: programsDirectory.path)) ?? [])
            .filter { $0.hasSuffix(".bas") }
            .sorted()
            .map { programsDirectory.appendingPathComponent($0).path }
    }
}

/// Golden BIR: the shape of what the front end produces, readable.
struct BIRGoldenTests {
    @Test func printAndAssign() throws {
        let module = try Compilation(dialect: TraditionalDialect()).bir(source: """
            A$ = "hi"
            PRINT A$; 1 + 2
            """, name: "golden")
        #expect(BIRPrinter().render(module) == """
            module golden
            global A$ : string
            function main() : void
              entry:
                store A$ <- "hi"
                print A$ (1 + 2) newline
                end

            """)
    }

    @Test func forLoopShape() throws {
        let module = try Compilation(dialect: TraditionalDialect()).bir(source: """
            FOR I = 1 TO 3
            NEXT
            """, name: "golden")
        let text = BIRPrinter().render(module)
        #expect(text.contains("local $for.end.1 : number"))
        #expect(text.contains("for.body:"))
        #expect(text.contains("store I <- (I + $for.step.2)"))
    }

    @Test func unreachableCodeIsDropped() throws {
        let module = try Compilation(dialect: TraditionalDialect()).bir(source: """
            10 GOTO 30
            20 PRINT "never"
            30 PRINT "end"
            """, name: "golden")
        #expect(!BIRPrinter().render(module).contains("never"))
    }
}

/// The compiler must not invent builtins the interpreter lacks.
struct IntrinsicTableTests {
    @Test func everyIntrinsicIsOneTheInterpreterHas() {
        // LEN and CHR$ are parsed as their own expression nodes, not looked up.
        let parsedSpecially: Set<String> = ["LEN", "CHR$", "ERR", "ERL"]
        for intrinsic in BIRIntrinsic.allCases where !parsedSpecially.contains(intrinsic.rawValue) {
            #expect(BASICKeywords.intrinsicFunctionNames.contains(intrinsic.rawValue), "\(intrinsic.rawValue)")
        }
    }
}

/// Diagnostics: what basicc refuses, and how it says so.
struct DiagnosticTests {
    @Test func orderingStringsInExpressionsIsRefusedLikeTheInterpreter() {
        // The interpreter's `<` on strings raises "Expected a number"; the
        // compiler says so at compile time rather than compiling something else.
        #expect(throws: CompileError.self) {
            try Compilation(dialect: TraditionalDialect()).bir(source: "PRINT \"a\" < \"b\"", name: "bad")
        }
    }

    /// `CHAIN` and `RUN f$` hand off to another program, which a compiled one
    /// cannot do yet (BBC_ADINS.md, decision B6). Refused by name at compile
    /// time, never built into something that behaves differently; `COMMON`
    /// alone is declarative and compiles.
    @Test func chainingToAnotherProgramIsRefusedByName() throws {
        for source in ["CHAIN \"next.bas\"", "RUN \"next.bas\"", "RUN \"next.bas\", R", "LOAD \"next.bas\", R"] {
            do {
                _ = try Compilation(dialect: TraditionalDialect()).bir(source: source, name: "chain")
                Issue.record("\(source) compiled")
            } catch let error as CompileError {
                #expect(String(describing: error).contains("cannot do yet"), "\(source): \(error)")
            }
        }
        _ = try Compilation(dialect: TraditionalDialect()).bir(source: "COMMON A, B$\nPRINT 1", name: "common")
    }

    /// A program's own ActiveUI windows (ACTIVEUI_TRANSITION.md P6) are made
    /// by BASICStudio's interpreter through its host, which a compiled program
    /// does not have. Refused by name, in each spelling a program can use,
    /// rather than reported as an array subscript or an unknown type.
    @Test func activeUIWindowsAreRefusedByName() throws {
        let sources = [
            "LET W = AUIWindow(\"x\")",
            "LET B = NEW AUIButton(\"Go\")",
            "DIM L AS AUIList",
            "FUNCTION Picked(E AS BASICAUIEvent)\nEND FUNCTION",
        ]
        for source in sources {
            do {
                _ = try Compilation(dialect: TraditionalDialect()).bir(source: source, name: "aui")
                Issue.record("\(source) compiled")
            } catch let error as CompileError {
                #expect(String(describing: error).contains("BASICStudio's interpreter"), "\(source): \(error)")
            }
        }
    }

    @Test func mixedTypesAreAnError() {
        #expect(throws: CompileError.self) {
            try Compilation(dialect: TraditionalDialect()).bir(source: "A = 1\nA = \"x\"", name: "bad")
        }
    }

    @Test func missingLineFailsWhenReachedLikeTheInterpreter() throws {
        let run = try TestBuild.run(source: "10 PRINT \"A\"\n20 GOTO 99\n30 PRINT \"B\"")
        #expect(run.stdout == "A\nMissing line 99\n")
        #expect(run.exitCode == 1)
    }

    /// A `GOTO` that leaves its routine, refused before anything runs.
    ///
    /// The rule earns its keep by removing a divergence rather than adding a
    /// restriction: the interpreter used to end the function silently and
    /// hand back the default value, while the compiler failed at run time
    /// with `Missing label`. Neither is what the program said. The check
    /// lives in `BranchScope`, which both engines call.
    @Test func aGotoMayNotLeaveItsRoutine() {
        let outward = "FUNCTION Escape() AS DOUBLE\n  GOTO Landing\n  RETURN 1\nEND FUNCTION\n"
            + "PRINT Escape()\nEND\nLanding:\nPRINT \"outside\""
        do {
            _ = try Compilation(dialect: TraditionalDialect()).bir(source: outward, name: "bad")
            Issue.record("expected a compile error")
        } catch let error as CompileError {
            #expect(error.description.contains("GOTO Landing leaves FUNCTION Escape"))
        } catch {
            Issue.record("unexpected \(error)")
        }

        // And the other way in: jumping *into* a function body used to run
        // that body with no frame under it.
        let inward = "GOTO Inside\nEND\nFUNCTION Host() AS DOUBLE\nInside:\n  RETURN 5\nEND FUNCTION"
        do {
            _ = try Compilation(dialect: TraditionalDialect()).bir(source: inward, name: "bad")
            Issue.record("expected a compile error")
        } catch let error as CompileError {
            #expect(error.description.contains("Inside is in FUNCTION Host"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    /// The rule is narrow on purpose. A label that exists *nowhere* is still
    /// BASIC's own business — legal to write, a failure only when reached —
    /// and `GOSUB` to a main-body subroutine from inside a function is a
    /// supported affordance the compiler outlines.
    @Test func onlyCrossRoutineJumpsAreRefused() throws {
        _ = try Compilation(dialect: TraditionalDialect())
            .bir(source: "FUNCTION F() AS DOUBLE\n  GOTO Nowhere\n  RETURN 1\nEND FUNCTION\nPRINT F()", name: "ok")
        _ = try Compilation(dialect: TraditionalDialect())
            .bir(source: "FUNCTION F() AS DOUBLE\n  GOSUB Helper\n  RETURN 1\nEND FUNCTION\nPRINT F()\nEND\nHelper:\nRETURN", name: "ok")
    }

    @Test func unsupportedFeaturesSaySo() {
        do {
            _ = try Compilation(dialect: TraditionalDialect()).bir(source: "CLASS C\nASYNC FUNCTION F() AS DOUBLE\nEND FUNCTION\nEND CLASS", name: "bad")
            Issue.record("expected a compile error")
        } catch let error as CompileError {
            #expect(error.description.contains("not supported by basicc yet"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

/// Programs compiled, run, and checked against expected output — and
/// against the interpreter, which is the oracle, whenever it is built.
struct EndToEndTests {
    @Test func runtimeErrorsLookLikeTheInterpreters() throws {
        let run = try TestBuild.run(path: TestBuild.programsDirectory.appendingPathComponent("divzero.bas").path)
        #expect(run.stdout == "BEFORE\nRuntime error: Division by zero\n")
        #expect(run.exitCode == 1)
    }

    @Test func returnWithoutGosubFails() throws {
        let run = try TestBuild.run(source: "PRINT \"A\"\nRETURN\nPRINT \"B\"")
        #expect(run.stdout == "A\nRuntime error: RETURN without GOSUB\n")
        #expect(run.exitCode == 1)
    }

    @Test(arguments: TestBuild.programs)
    func programMatchesExpectedOutput(path: String) throws {
        let expectedPath = (path as NSString).deletingPathExtension + ".out"
        let expected = try String(contentsOfFile: expectedPath, encoding: .utf8)
        let run = try TestBuild.run(path: path)
        #expect(run.stdout == expected, "compiled output of \((path as NSString).lastPathComponent)")
    }

    @Test(arguments: TestBuild.programs)
    func programMatchesTheInterpreter(path: String) throws {
        guard let interpreted = try TestBuild.interpret(path: path) else { return }
        let run = try TestBuild.run(path: path)
        #expect(run.stdout == interpreted, "interpreter parity for \((path as NSString).lastPathComponent)")
    }
}


/// `SOUND`, `PLAY` and `BEEP` in both engines, compared by what they played
/// (BBC_ADINS.md A8, A9). `BASIC_SOUND_TRACE` makes each engine write every
/// event to a file on a virtual clock, so nothing sounds, nothing waits, and
/// the two files must match byte for byte.
struct SoundParityTests {
    static let program = """
        SOUND 440, 18.2
        SOUND 32767, 9.1
        BEEP
        PLAY "T120 L4 O2 A MS C8 ML D. MN E-"
        PLAY "MB O3 CDE"
        PRINT "queued"; PLAY(0)
        N = 37: T$ = "L16 CDEF"
        PLAY "N=N; X T$;"
        M$ = "O1 L=N; G"
        PLAY M$ + " X T$;"
        FUNCTION Tune(L AS DOUBLE) AS DOUBLE
          PLAY "L=L; B"
          RETURN 0
        END FUNCTION
        X = Tune(2)
        SOUND 1, -15, 53, 20
        SOUND 17, -7, 89, 10
        SOUND 0, -10, 4, 5
        PRINT "done"
        """

    @Test func bothEnginesPlayTheSameNotes() throws {
        guard let interpreter = TestBuild.interpreter else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("basicc-sound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("sound.bas").path
        try Self.program.write(toFile: source, atomically: true, encoding: .utf8)
        let binary = directory.appendingPathComponent("sound").path
        try TestBuild.onDeepStack { try Compilation(dialect: TraditionalDialect()).build(sourcePath: source, output: binary) }

        func traced(_ executable: String, _ arguments: [String], into name: String) throws -> (stdout: String, trace: String) {
            let trace = directory.appendingPathComponent(name).path
            var environment = ProcessInfo.processInfo.environment
            environment["BASIC_SOUND_TRACE"] = trace
            let result = try ProcessRunner.run(executable, arguments, environment: environment)
            return (result.stdout, try String(contentsOfFile: trace, encoding: .utf8))
        }
        let compiled = try traced(binary, [], into: "compiled.trace")
        let interpreted = try traced(interpreter, [source], into: "interpreted.trace")
        #expect(compiled.stdout == "queued3\ndone\n")
        #expect(compiled.stdout == interpreted.stdout)
        #expect(compiled.trace.split(separator: "\n").count == 42)
        #expect(compiled.trace == interpreted.trace)
    }

    /// `ENVELOPE`, a release cut short by the next note, and `PLAY MIDI`,
    /// played from the program's own directory by both engines.
    @Test func envelopesAndSongsMatch() throws {
        guard let interpreter = TestBuild.interpreter else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("basicc-envelope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Format 0, one track at 120 BPM: a quarter note, half a second.
        let song: [UInt8] = [
            0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0, 96,
            0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, 12,
            0x00, 0x90, 0x3C, 0x40, 0x60, 0x80, 0x3C, 0x00, 0x00, 0xFF, 0x2F, 0x00,
        ]
        try Data(song).write(to: directory.appendingPathComponent("tune.mid"))
        let source = directory.appendingPathComponent("envelope.bas").path
        try """
            ENVELOPE 1, 2, 0, 0, 0, 0, 0, 0, 63, -4, 0, -8, 126, 80
            SOUND 1, 1, 53, 10
            SOUND 1, 1, 69, 10
            ENVELOPE 2, 1, 1, -1, 1, 2, 4, 2, 126, 0, 0, -126, 126, 126
            SOUND 2, 2, 81, 20
            PLAY MIDI "tune.mid"
            PRINT "done"
            """.write(toFile: source, atomically: true, encoding: .utf8)
        let binary = directory.appendingPathComponent("envelope").path
        try TestBuild.onDeepStack { try Compilation(dialect: TraditionalDialect()).build(sourcePath: source, output: binary) }

        func traced(_ executable: String, _ arguments: [String], into name: String) throws -> (stdout: String, trace: String) {
            let trace = directory.appendingPathComponent(name).path
            var environment = ProcessInfo.processInfo.environment
            environment["BASIC_SOUND_TRACE"] = trace
            let result = try ProcessRunner.run(executable, arguments, environment: environment, workingDirectory: directory.path)
            return (result.stdout, try String(contentsOfFile: trace, encoding: .utf8))
        }
        let compiled = try traced(binary, [], into: "compiled.trace")
        let interpreted = try traced(interpreter, [source], into: "interpreted.trace")
        #expect(compiled.stdout == "done\n")
        #expect(compiled.stdout == interpreted.stdout)
        #expect(compiled.trace.contains("voice 1: cut at 0.5000"))
        #expect(compiled.trace.contains("voice 16 at 0.0000: MIDI tune.mid (34 bytes) for 0.5000 s"))
        #expect(compiled.trace == interpreted.trace)
    }
}

/// `swift build` compiles BASIC through BASICBuildPlugin — held by building
/// the example package for real.
struct SwiftPMPluginTests {
    @Test func examplePackageBuildsAndRuns() throws {
        let example = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/SwiftPMHello")
        // Its own scratch and cache: this runs inside `swift test`, which is
        // holding the lock on the package the example depends on by path,
        // and two SwiftPM builds sharing a build directory contend for it.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("basicc-example-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let build = try ProcessRunner.run("/usr/bin/xcrun", [
            "swift", "build", "--package-path", example.path,
            "--scratch-path", scratch.path,
            "--cache-path", scratch.appendingPathComponent("cache").path,
        ])
        #expect(build.exitCode == 0, Comment(rawValue: build.stderr))
        let run = try ProcessRunner.run(scratch.appendingPathComponent("debug/Hello").path, [])
        #expect(run.stdout == "Hello from a SwiftPM package!\n  count1\n  count2\n  count3\n")
    }
}


/// A directory-form `.basproj`: manifest, entry, root-relative IMPORT, and
/// the project's own STRING-SUB default.
struct ProjectTests {
    @Test func projectDirectoryBuildsWithItsManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("basicc-proj-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Lib"), withIntermediateDirectories: true)
        try """
            { "schemaVersion": 1, "kind": "project", "name": "Demo", "entry": "Sources/main.bas", "options": { "stringSub": false } }
            """.write(to: root.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        try "FUNCTION Shout$(T AS STRING) AS STRING\n  RETURN T + \"!\"\nEND FUNCTION\n"
            .write(to: root.appendingPathComponent("Sources/Lib/util.bas"), atomically: true, encoding: .utf8)
        try "IMPORT \"Sources/Lib/util.bas\"\nPRINT Shout$(\"project\")\nPRINT \"no ${sub} here\"\n"
            .write(to: root.appendingPathComponent("Sources/main.bas"), atomically: true, encoding: .utf8)

        let output = root.appendingPathComponent("Build/Demo").path
        try Compilation(dialect: TraditionalDialect()).build(sourcePath: root.path, output: output)
        let run = try ProcessRunner.run(output, [])
        #expect(run.stdout == "project!\nno ${sub} here\n")
    }

    @Test func newerManifestsAreRefusedByVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("basicc-proj-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "{ \"schemaVersion\": 2, \"kind\": \"project\", \"name\": \"X\" }"
            .write(to: root.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        #expect(throws: CompileError.self) {
            try Compilation(dialect: TraditionalDialect()).bir(sourcePath: root.path)
        }
    }
}

/// The starters `basicc new` writes must compile and, where the interpreter
/// is built, match it — otherwise the wizards hand people a broken project.
struct StarterTests {
    @Test(arguments: ProjectScaffold.Kind.allCases)
    func starterBuildsAndMatchesTheInterpreter(kind: ProjectScaffold.Kind) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("basicc-starter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = try ProjectScaffold.generate(named: "Starter", into: root.path, kind: kind)
        let source = (project as NSString).appendingPathComponent("src/main.bas")
        let output = (project as NSString).appendingPathComponent("Build/Starter")
        try FileManager.default.createDirectory(atPath: (output as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Compilation(dialect: TraditionalDialect()).build(sourcePath: source, output: output)

        // The console starter reads a name; feed both engines the same one.
        let stdin = "Bobby\n"
        let compiled = try runWithInput(output, stdin)
        // The TUI starter needs a terminal, and says so where the
        // interpreter says so. Everything else runs to the end.
        #expect(compiled.exitCode == (kind == .tui ? 1 : 0))
        if let interpreter = TestBuild.interpreter {
            let interpreted = try runWithInput(interpreter, stdin, arguments: [source])
            #expect(compiled.stdout == interpreted.stdout, "starter \(kind.rawValue)")
        }
    }

    @Test func aProgramCanBeWrappedInAnAppBundle() throws {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("basicc-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let source = workDir.appendingPathComponent("Greeter.bas").path
        try "PRINT \"hi\"\n".write(toFile: source, atomically: true, encoding: .utf8)
        let program = workDir.appendingPathComponent("Greeter").path
        try TestBuild.onDeepStack { try Compilation(dialect: TraditionalDialect()).build(sourcePath: source, output: program) }

        let bundle = try AppBundle.wrap(program: program)
        #expect((bundle as NSString).lastPathComponent == "Greeter.app")
        let contents = (bundle as NSString).appendingPathComponent("Contents")
        let inner = (contents as NSString).appendingPathComponent("MacOS/Greeter")
        let launcher = (contents as NSString).appendingPathComponent("MacOS/Greeter-launch")
        let plist = (contents as NSString).appendingPathComponent("Info.plist")
        for path in [inner, launcher, plist] {
            #expect(FileManager.default.fileExists(atPath: path), Comment(rawValue: "missing \(path)"))
        }
        #expect(FileManager.default.isExecutableFile(atPath: launcher))
        // The plist names the launcher, and the launcher names the program.
        let plistText = try String(contentsOfFile: plist, encoding: .utf8)
        #expect(plistText.contains("<string>Greeter-launch</string>"))
        #expect(try String(contentsOfFile: launcher, encoding: .utf8).contains("/Greeter\""))
        // The program inside it is the program.
        let run = try ProcessRunner.run(inner, [])
        #expect(run.stdout == "hi\n")
    }

    private func runWithInput(_ executable: String, _ input: String, arguments: [String] = []) throws -> (stdout: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let inPipe = Pipe(), outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = outPipe
        try process.run()
        inPipe.fileHandleForWriting.write(Data(input.utf8))
        try inPipe.fileHandleForWriting.close()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }
}

/// The logical operators bind in BASIC's order, and the compiler agrees with
/// the interpreter about it.
@Suite("Logical operators")
struct LogicalOperatorTests {
    /// Each of these is a program and the parenthesised form it must equal.
    static let precedence: [(String, String)] = [
        ("NOT a = b", "NOT (a = b)"),
        ("NOT f AND t", "(NOT f) AND t"),
        ("t OR f XOR t", "(t OR f) XOR t"),
        ("t XOR t EQV f", "(t XOR t) EQV f"),
        ("f EQV f IMP f", "(f EQV f) IMP f"),
        ("NOT t OR t", "(NOT t) OR t"),
    ]

    @Test(arguments: LogicalOperatorTests.precedence)
    func anExpressionMeansItsParenthesisedForm(pair: (String, String)) throws {
        let source = """
        DIM t AS INTEGER
        DIM f AS INTEGER
        DIM a AS INTEGER
        DIM b AS INTEGER
        t = 1
        f = 0
        a = 1
        b = 2
        PRINT \(pair.0)
        PRINT \(pair.1)
        """
        let run = try TestBuild.run(source: source)
        let lines = run.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 2, Comment(rawValue: run.stdout))
        #expect(lines.first == lines.last, Comment(rawValue: "\(pair.0) is not \(pair.1): \(run.stdout)"))
    }
}
