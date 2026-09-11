import BASICCompilerKit
import BASICDialectSwift
import BASICDialectTraditional
import Foundation

// basicc — the CLI driver.
//
// Owns no language knowledge. Parses the command line, asks the registry for
// a dialect, and hands it the work.

let version = "0.1.0"
let registry = DialectRegistry([TraditionalDialect(), SwiftDialect()])

func printUsage() {
    print("""
    basicc \(version) — a BASIC compiler that builds LLVM modules and links Swift libraries

    usage:
      basicc build <file.bas|project/> [options]   compile to an executable
      basicc run <file.bas|project/> [options]     compile, then run it
      basicc new <Name> [--kind k] [-o dir]   create a starter project
      basicc swift-interface <file.bas>   print the Swift view of the program's
                                          classes, as a .swiftinterface
      basicc swift-class <file.bas> -o <dir>
                                          compile the program's classes into a
                                          Swift-callable object plus interface
      basicc import-report <file.bas>     what each IMPORTed Swift framework
                                          gave the program, and what it did not
      basicc import-probe <file.bas>      the same, and prove it: compile every
                                          generated shim and type-check the units
      basicc dialects                     list the dialects this build supports
      basicc --version

    options:
      -o <path>            output executable (default: the source's base name)
      --dialect <name>     traditional (default) or swift; a project with a
                           Package.swift builds as swift unless this says otherwise
      --emit-bir           print the compiler's IR instead of building
      --emit-llvm          print the LLVM IR instead of building
      --emit-asm           write assembly to -o instead of linking (SwiftPM plugin)
      -O, -O0..-O3         optimization level for the generated code (default -O0)
      --json-diagnostics   report errors as a JSON array (for IDEs)
      --bundle             also write <name>.app, a macOS launcher for the program
      --kind <kind>        for new: \(ProjectScaffold.Kind.allCases.map(\.rawValue).joined(separator: ", ")) (default: console)
    """)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("basicc: \(message)\n".utf8))
    exit(code)
}

struct Invocation {
    var command: String
    var source: String?
    var output: String?
    var dialect: String?
    var emitBIR = false
    var emitLLVM = false
    var jsonDiagnostics = false
    var emitAssembly = false
    var optimizationLevel = 0
    var kind: String?
    var bundle = false

    init(_ arguments: [String]) {
        command = arguments.first ?? "help"
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-o":
                index += 1
                guard index < arguments.count else { fail("-o needs a path") }
                output = arguments[index]
            case "--dialect":
                index += 1
                guard index < arguments.count else { fail("--dialect needs a name") }
                dialect = arguments[index]
            case "--emit-bir": emitBIR = true
            case "--emit-llvm": emitLLVM = true
            case "--emit-asm": emitAssembly = true
            case "-O": optimizationLevel = 2
            case "-O0", "-O1", "-O2", "-O3": optimizationLevel = Int(String(argument.dropFirst(2)))!
            case "--json-diagnostics": jsonDiagnostics = true
            case "--bundle": bundle = true
            case "--kind":
                index += 1
                guard index < arguments.count else { fail("--kind needs a name") }
                kind = arguments[index]
            default:
                if argument.hasPrefix("-") { fail("unknown option '\(argument)'", code: 2) }
                if source == nil { source = argument } else { fail("only one source file at a time", code: 2) }
            }
            index += 1
        }
    }
}

/// Which dialect compiles this invocation.
///
/// `--dialect` wins outright. Failing that, a `Package.swift` beside the
/// program selects the Swift dialect: a package manifest is a statement that
/// the program has Swift dependencies for SwiftPM to resolve, and resolving
/// them is that dialect's job. A program with no manifest links the runtime
/// libraries built into the compiler and fetches nothing.
///
/// An inferred choice is announced on stderr. Inference that is silent is
/// inference that gets blamed on the compiler months later.
func resolveDialect(_ invocation: Invocation) throws -> any DialectCompiler {
    if invocation.dialect != nil { return try registry.dialect(named: invocation.dialect) }
    // A project may name its dialect, which is how a scheme carries the
    // choice into the build (R5.3). Announced, like every inferred choice.
    if let source = invocation.source,
       let project = try? ProjectManifest.load(at: source),
       let named = project.options?.dialect {
        let dialect = try registry.dialect(named: named)
        FileHandle.standardError.write(Data(
            "basicc: \(project.name) asks for --dialect \(named)\n".utf8))
        return dialect
    }
    guard let source = invocation.source,
          SwiftDialect.inferredFromPackageManifest(at: source) else {
        return registry.defaultDialect
    }
    let dialect = try registry.dialect(named: SwiftDialect.identity.identifier)
    FileHandle.standardError.write(Data("basicc: Package.swift found — building with --dialect swift\n".utf8))
    return dialect
}

func compilation(for invocation: Invocation) -> Compilation {
    do {
        let dialect = try resolveDialect(invocation)
        var compilation = Compilation(
            dialect: dialect,
            options: CompileOptions(optimizationLevel: invocation.optimizationLevel)
        )
        // Only the Swift dialect can import a Swift framework. Reading the
        // source is where that is discovered, so reading is where it is
        // resolved — and the dialect that lowers is the one the reader
        // handed its findings to.
        guard dialect is SwiftDialect else { return compilation }
        compilation.readModule = { sourcePath, base in
            // A project names its entry file and its own libraries; a bare
            // `.bas` is its own entry. Reading the project here is what lets
            // `basicc build <project>` work under this dialect at all —
            // handing the directory to the source loader asked it to read a
            // folder as a program.
            let project = try ProjectManifest.load(at: sourcePath)
            let entry = project?.entryPath ?? sourcePath
            let directory = (entry as NSString).deletingLastPathComponent
            let loader = SwiftImportLoader(programDirectory: directory.isEmpty ? "." : directory)
            let libraries = try project.map { try LibraryIndex.build(root: $0.root, declared: $0.libraries ?? []) } ?? LibraryIndex()
            let result = try loader.load(path: entry, projectRoot: project?.root, libraries: libraries)
            // A project answers for itself; a bare `.bas` keeps the
            // builder's own default, which is on. Defaulting to `false` here
            // turned `${...}` substitution off for every program without a
            // project — caught by parity, which is what it is for.
            let module = try BIRBuilder(defaultStringSubstitution: project?.stringSubstitution ?? true,
                                        externalClasses: result.externalClasses,
                                        externalFunctions: result.externalFunctions, enumMembers: result.enumMembers)
                .build(result.lines, moduleName: Compilation.moduleName(for: sourcePath))
            var resolved = Compilation(
                dialect: SwiftDialect(imports: result.imports),
                options: base.options, toolchain: base.toolchain
            )
            resolved.extraObjects = result.objects
            for note in result.imports.values.flatMap(\.skipped)
            where ProcessInfo.processInfo.environment["BASICC_NOTES"] != nil {
                FileHandle.standardError.write(Data("basicc: note: skipped \(note.member) — \(note.reason)\n".utf8))
            }
            return (module, resolved)
        }
        return compilation
    } catch {
        fail("\(error)", code: 2)
    }
}

func buildCommand(_ invocation: Invocation, thenRun: Bool) {
    guard let source = invocation.source else { fail("a source file is required", code: 2) }
    let compilation = compilation(for: invocation)
    do {
        if invocation.emitBIR {
            print(BIRPrinter().render(try compilation.bir(sourcePath: source)), terminator: "")
            return
        }
        if invocation.emitLLVM {
            print(try compilation.llvmIR(sourcePath: source), terminator: "")
            return
        }
        // Without `-o`, output goes under Build/ rather than beside the
        // source — what every other compiler does, and what the Makefile in
        // a generated project already asks for. Building a program in place
        // used to leave the binary and a `<name>.build` directory of
        // intermediates sitting next to the .bas file it came from.
        let output = invocation.output ?? Compilation.defaultOutputPath(for: source)
        if invocation.emitAssembly {
            try compilation.buildAssembly(sourcePath: source, output: output)
            return
        }
        try compilation.build(sourcePath: source, output: output)
        if invocation.bundle {
            let path = try AppBundle.wrap(program: output)
            print("wrapped \((path as NSString).lastPathComponent)")
        }
        if thenRun {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: output).absoluteURL
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            try process.run()
            process.waitUntilExit()
            exit(process.terminationStatus)
        }
    } catch let error as CompileError {
        if invocation.jsonDiagnostics {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = (try? encoder.encode(error.diagnostics)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            print(json)
        } else {
            for diagnostic in error.diagnostics {
                FileHandle.standardError.write(Data((diagnostic.rendered + "\n").utf8))
            }
        }
        exit(1)
    } catch {
        fail("\(error)")
    }
}

let invocation = Invocation(Array(CommandLine.arguments.dropFirst()))
switch invocation.command {
case "--version", "-v":
    print("basicc \(version)")
case "import-probe":
    // R4.8's tripwire. `import-report` says what a framework gave; this also
    // proves the giving *works*: every generated shim is compiled by swiftc
    // as the loader resolves the import, and then the whole program goes
    // through the front end, which type-checks the generated interface units
    // along with it. A member the reader claims and the emitter cannot spell
    // fails here rather than the first time a program happens to call it.
    guard let source = invocation.source else { fail("a source file is required", code: 2) }
    do {
        let directory = (source as NSString).deletingLastPathComponent
        let result = try SwiftImportLoader(programDirectory: directory.isEmpty ? "." : directory).load(path: source)
        guard !result.imports.isEmpty else {
            print("\(source) imports no Swift framework")
            exit(0)
        }
        for module in result.imports.keys.sorted() {
            print(SwiftInterfaceUnit(api: result.imports[module]!).report())
        }
        // The front end over the whole program, generated units included —
        // and then lowering, which is where the interface unit and the
        // object model have to agree about which members exist.
        let module = try BIRBuilder(externalClasses: result.externalClasses,
                                        externalFunctions: result.externalFunctions, enumMembers: result.enumMembers)
            .build(result.lines, moduleName: Compilation.moduleName(for: source))
        _ = try SwiftDialect(imports: result.imports).lower(module, options: CompileOptions())
        print("shims compiled, interfaces type-check, thunks emit")
    } catch let error as CompileError {
        for diagnostic in error.diagnostics {
            FileHandle.standardError.write(Data((diagnostic.rendered + "\n").utf8))
        }
        exit(1)
    } catch {
        fail("\(error)")
    }
case "import-report":
    guard let source = invocation.source else { fail("a source file is required", code: 2) }
    do {
        let directory = (source as NSString).deletingLastPathComponent
        let result = try SwiftImportLoader(programDirectory: directory.isEmpty ? "." : directory).load(path: source)
        if result.imports.isEmpty {
            print("\(source) imports no Swift framework")
        }
        for module in result.imports.keys.sorted() {
            print(SwiftInterfaceUnit(api: result.imports[module]!).report())
        }
    } catch let error as CompileError {
        for diagnostic in error.diagnostics {
            FileHandle.standardError.write(Data((diagnostic.rendered + "\n").utf8))
        }
        exit(1)
    } catch {
        fail("\(error)")
    }
case "swift-class":
    guard let source = invocation.source else { fail("a source file is required", code: 2) }
    do {
        let compilation = Compilation(dialect: SwiftDialect(), options: CompileOptions())
        let bir = try compilation.bir(sourcePath: source)
        let directory = invocation.output ?? "Build"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let base = (directory as NSString).appendingPathComponent(bir.name)

        // The same lowering a program gets, minus the entry point: one
        // emitter, so a class Swift links behaves exactly as a class the
        // program runs, and both get the probe's symbol names.
        let options = CompileOptions(omitsEntryPoint: true)
        let ir = try SwiftDialect().lower(bir, options: options).llvmIR
        try ir.write(toFile: base + ".ll", atomically: true, encoding: .utf8)
        try Toolchain().assemble(llvmIR: ir, irPath: base + ".ll", objectPath: base + ".o")

        // The interface is generated from the same model that emitted the
        // object, so the two cannot promise different things.
        let objects = SwiftObjectModel(module: bir, probed: (try? SwiftObjectModel.probe(bir)) ?? .init())
        var emitter = SwiftInterfaceEmitter(module: bir)
        emitter.emittedMethods = Set(objects.classes.flatMap { layout in
            layout.visibleMethods.map { "\(layout.composite.name).\($0.name)" }
        })
        let interface = emitter.render(target: SwiftInterfaceEmitter.hostTarget)
        try interface.text.write(toFile: base + ".swiftinterface", atomically: true, encoding: .utf8)
        for skip in interface.skipped {
            FileHandle.standardError.write(Data(
                "basicc: skipped \(skip.owner).\(skip.member) — \(skip.reason)\n".utf8))
        }
        print("\(bir.name).o and \(bir.name).swiftinterface in \(directory)")
    } catch let error as CompileError {
        for diagnostic in error.diagnostics {
            FileHandle.standardError.write(Data((diagnostic.rendered + "\n").utf8))
        }
        exit(1)
    } catch {
        fail("\(error)")
    }
case "swift-interface":
    guard let source = invocation.source else { fail("a source file is required", code: 2) }
    do {
        let compilation = Compilation(dialect: SwiftDialect(), options: CompileOptions())
        let emitter = SwiftInterfaceEmitter(module: try compilation.bir(sourcePath: source))
        let interface = emitter.render(target: SwiftInterfaceEmitter.hostTarget)
        print(interface.text, terminator: "")
        // On stderr so the interface itself stays pipeable into a file.
        for skip in interface.skipped {
            FileHandle.standardError.write(Data(
                "basicc: skipped \(skip.owner).\(skip.member) — \(skip.reason)\n".utf8))
        }
    } catch let error as CompileError {
        for diagnostic in error.diagnostics {
            FileHandle.standardError.write(Data((diagnostic.rendered + "\n").utf8))
        }
        exit(1)
    } catch {
        fail("\(error)")
    }
case "dialects":
    for identity in registry.identities {
        print("\(identity.identifier)\(identity.isDefault ? " (default)" : "")\t\(identity.summary)")
    }
case "new":
    guard let name = invocation.source else { fail("basicc new needs a project name", code: 2) }
    guard let kind = ProjectScaffold.Kind(rawValue: invocation.kind ?? "console") else {
        fail("unknown kind '\(invocation.kind ?? "")' — one of: \(ProjectScaffold.Kind.allCases.map(\.rawValue).joined(separator: ", "))", code: 2)
    }
    do {
        let root = try ProjectScaffold.generate(named: name, into: invocation.output ?? FileManager.default.currentDirectoryPath, kind: kind)
        print("created \(root) — build with: make")
    } catch {
        fail("\(error)")
    }
case "build":
    buildCommand(invocation, thenRun: false)
case "run":
    buildCommand(invocation, thenRun: true)
case "help", "--help", "-h":
    printUsage()
default:
    FileHandle.standardError.write(Data("basicc: unknown command '\(invocation.command)'\n\n".utf8))
    printUsage()
    exit(2)
}
