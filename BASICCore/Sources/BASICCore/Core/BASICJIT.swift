//
//  BASICJIT.swift
//  BASICCore
//
//  Compiling the program in front of you and running it.
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Compiling a program with `basicc` and running what comes out.
///
/// `RUN` interprets. `JIT` compiles first and runs the binary, which on
/// arithmetic is about a hundred times faster — see `Scripts/benchmark.bas`
/// — and is otherwise the same program: the compiler is held to the
/// interpreter's output byte for byte, which is what makes swapping one for
/// the other a speed decision rather than a semantic one.
///
/// The compiler is *run*, not linked. `BASICCore` has no dependency on
/// `BASICCompiler` and gains none here: `basicc` is found on the path like
/// any other tool, so a host without it says so and carries on interpreting.
/// That also keeps the two engines at arm's length, which is where the
/// prime directive wants them.
///
/// There is no debugger here. A compiled program has no interpreter to step,
/// and no host reads the DWARF basicc writes (only `lldb` does), so a host
/// that offers `JIT` alongside a debugger has to say that breakpoints do not
/// apply to it.
public enum BASICJIT {

    /// What a compile produced.
    public enum Outcome: Sendable {
        /// The binary, ready to run.
        case built(binary: String)
        /// The compiler refused, and said why. Lines are as `basicc` printed
        /// them: `file:line: error: message`.
        case refused(diagnostics: [String])
        /// No compiler to run.
        case unavailable(reason: String)
    }

    /// Where `basicc` is, or nil when it is not installed.
    ///
    /// `BASICC` in the environment wins, so a developer can point a host at
    /// the build they are working on without installing it.
    public static func compilerPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let override = environment["BASICC"], FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        // PATH decides, and nothing else. The fallback is the system's own
        // default for a process started without one — naming likely install
        // prefixes here would be this code guessing at somebody's machine,
        // and guessing wrong is how a JIT ends up compiling with a compiler
        // the user did not install and cannot see.
        let searched = (environment["PATH"] ?? "/usr/bin:/bin")
            .split(separator: ":").map(String.init)
        for directory in searched {
            let candidate = (directory as NSString).appendingPathComponent("basicc")
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return loginShellCompilerPath()
    }

    /// `basicc` where the user's own login shell finds it.
    ///
    /// A windowed app does not inherit a terminal's PATH. Launched from
    /// Finder, the Dock or Xcode it gets `/usr/bin:/bin:/usr/sbin:/sbin` and
    /// nothing else — so the install `buildtosystem.sh` makes in
    /// `/usr/local/bin` is invisible to it, and Studio reported the compiler
    /// missing while the very same compiler ran fine in a terminal. That is
    /// what "JIT works in the shell and fails in Studio" was.
    ///
    /// This is still PATH deciding, which is the rule above and worth
    /// keeping: it is the user's own PATH, read by their own shell from
    /// their own profile, rather than a prefix guessed here. A guessed prefix
    /// is how a JIT ends up compiling with a compiler the user did not
    /// install; asking their shell cannot do that.
    ///
    /// Asked once. A login shell costs a great deal more than a directory
    /// check, and the compiler does not move while a host is running.
    private static func loginShellCompilerPath() -> String? {
        #if os(iOS)
        return nil
        #else
        loginShellLock.lock()
        defer { loginShellLock.unlock() }
        if let asked = askedLoginShell { return asked }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", "command -v basicc"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        var found: String?
        do {
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, FileManager.default.isExecutableFile(atPath: text) {
                found = text
            }
        } catch {
            found = nil
        }
        askedLoginShell = .some(found)
        return found
        #endif
    }

    private static let loginShellLock = NSLock()

    /// `nil` until a login shell has been asked; `.some(nil)` once it has been
    /// asked and had no answer, so it is asked exactly once either way.
    nonisolated(unsafe) private static var askedLoginShell: String??

    /// Compiles a program.
    ///
    /// - Parameters:
    ///   - source: the program's text, used when it has no file of its own.
    ///   - path: the file it came from, when it came from one. Compiling
    ///     that file rather than a copy is what keeps `IMPORT` working:
    ///     an import resolves against the importing file's directory, and a
    ///     copy in a temporary directory has different neighbours.
    ///   - optimization: `-O0` … `-O3`; `-O0` is the default because a JIT
    ///     is asked for interactively and the optimizer buys about 8% for a
    ///     noticeably longer wait.
    ///   - dialect: which compiler to use — `"traditional"` (Rev 1, the
    ///     default) or `"swift"` (Rev 2). `nil` leaves the choice to
    ///     `basicc`, which uses the traditional dialect unless the program
    ///     sits beside a `Package.swift`. Both dialects are supported
    ///     permanently; this picks between them, it does not replace one.
    public static func compile(
        source: String,
        path: String?,
        optimization: String = "-O0",
        dialect: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Outcome {
        #if os(iOS)
        // No child processes on iOS, so no compiler to run.
        return .unavailable(reason: BASICPlatform.notAvailableMessage("JIT") + "; RUN still interprets")
        #else
        guard let compiler = compilerPath(environment: environment) else {
            return .unavailable(reason: "basicc is not installed; RUN still interprets")
        }
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("basic-jit-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        } catch {
            return .unavailable(reason: "\(error)")
        }

        let sourcePath: String
        if let path, FileManager.default.fileExists(atPath: path) {
            sourcePath = path
        } else {
            sourcePath = workDirectory.appendingPathComponent("program.bas").path
            do {
                try source.write(toFile: sourcePath, atomically: true, encoding: .utf8)
            } catch {
                return .unavailable(reason: "\(error)")
            }
        }
        let binary = workDirectory.appendingPathComponent("program").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: compiler)
        process.environment = compilerEnvironment(environment)
        var arguments = ["build", sourcePath, optimization, "-o", binary]
        if let dialect { arguments += ["--dialect", dialect] }
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return .unavailable(reason: "\(error)")
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: binary) else {
            let text = String(decoding: errData + outData, as: UTF8.self)
            let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            return .refused(diagnostics: lines.isEmpty ? ["basicc failed with no message"] : lines)
        }
        return .built(binary: binary)
        #endif
    }

    /// The environment `basicc` runs with: the host's, without its `DYLD_`
    /// variables.
    ///
    /// A host started by Xcode or `swift test` has `DYLD_LIBRARY_PATH` and
    /// `DYLD_FRAMEWORK_PATH` pointing at its own build products. An installed
    /// `basicc` that inherits them loads the host's `libTUIKit.dylib` instead
    /// of the one installed beside it, and dies before compiling anything:
    /// "dyld: Symbol not found: …TUIKit…" (2026-11-02, GradeBook's `jit` in
    /// Studio run from Xcode). The compiler's libraries are found from where
    /// it is installed, never from where the host was built.
    public static func compilerEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { !$0.key.hasPrefix("DYLD_") }
    }

    /// A typed `JIT`, as BASICShell's prompt and BASICStudio's console both
    /// read it.
    ///
    /// ```text
    ///   JIT                     the loaded program
    ///   JIT SWIFT               … compiled with the Rev 2 dialect; TRADITIONAL names the default
    ///   JIT "file.bas"          that file, leaving the loaded program alone
    /// ```
    public struct Command: Equatable, Sendable {
        /// `swift` or `traditional`, when the command names one.
        public let dialect: String?
        /// The file to compile instead of the loaded program, as typed.
        public let file: String?

        public init(dialect: String? = nil, file: String? = nil) {
            self.dialect = dialect
            self.file = file
        }
    }

    /// `input` as a `JIT` command, or nil when it is not one.
    public static func command(_ input: String) -> Command? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercased = trimmed.uppercased()
        guard uppercased == "JIT" || uppercased.hasPrefix("JIT ") else { return nil }
        var rest = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        // Both compilers are supported permanently, so naming one is a
        // choice for this run, never a migration.
        var dialect: String?
        for name in ["SWIFT", "TRADITIONAL"] where rest.uppercased() == name || rest.uppercased().hasPrefix(name + " ") {
            dialect = name.lowercased()
            rest = String(rest.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
        }
        let file = rest.isEmpty ? nil : rest.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return Command(dialect: dialect, file: file)
    }

    /// The text of a program, as a file the compiler can read.
    ///
    /// Numbered lines keep their numbers, because a diagnostic that names a
    /// line has to name the one the program was written with. Each line is
    /// where the editor has it: the program leaves out blank lines, which
    /// come back as blank lines, so the line a runtime error or the debugger
    /// names is the editor's, as the interpreter's is.
    public static func text(of program: BASICProgram) -> String {
        compiledText(of: program).text
    }

    /// The text of a program, and the editor's line for each of its lines
    /// (nil for a blank line put back, or a line typed at the prompt).
    public static func compiledText(of program: BASICProgram) -> (text: String, editorLines: [Int?]) {
        var lines: [String] = []
        var editorLines: [Int?] = []
        for line in program.orderedLines {
            if !line.isImported, let wanted = line.sourceLineNumber {
                while lines.count + 1 < wanted {
                    lines.append("")
                    editorLines.append(nil)
                }
            }
            lines.append((line.number.map { "\($0) " } ?? "") + line.source)
            editorLines.append(line.isImported ? nil : line.sourceLineNumber)
        }
        return (lines.joined(separator: "\n") + "\n", editorLines)
    }

    /// Runs a compiled binary with the terminal it was started from, so
    /// `INPUT`, `INKEY$` and a TUI application all behave as they would
    /// under `RUN`. Answers its exit status.
    ///
    /// The terminal is handed over for the duration. `Process` starts a
    /// child in a process group of its own, and a process group that is not
    /// the terminal's foreground group is stopped by `SIGTTIN` the instant
    /// it reads a key — the program freezes, the host waits for it, and
    /// neither ever moves again. So the child's group is made the foreground
    /// group before it can read anything, which also puts Ctrl-C where it
    /// belongs: it interrupts the program, not the host waiting on it.
    ///
    /// The terminal's settings are saved and put back too. A program killed
    /// part-way through has no chance to leave raw mode, and a host that
    /// returned to its prompt with echo off would look broken.
    @discardableResult
    public static func run(binary: String, arguments: [String] = []) -> Int32 {
        #if os(iOS)
        // Never reached: `compile` builds nothing on iOS.
        return -1
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        let terminal = STDIN_FILENO
        let isTerminal = isatty(terminal) == 1
        var savedTermios = termios()
        let savedTermiosIsValid = isTerminal && tcgetattr(terminal, &savedTermios) == 0
        let previousForeground: pid_t = isTerminal ? tcgetpgrp(terminal) : -1

        do {
            try process.run()
        } catch {
            return 127
        }

        // Hand over the terminal. SIGCONT covers the race in which the child
        // reached its first read before this ran and was already stopped.
        var handedOver = false
        let childGroup = getpgid(process.processIdentifier)
        if isTerminal, previousForeground > 0, childGroup > 0, childGroup != previousForeground {
            handedOver = withSIGTTOUIgnored { tcsetpgrp(terminal, childGroup) == 0 }
            if handedOver { _ = killpg(childGroup, SIGCONT) }
        }

        process.waitUntilExit()

        if handedOver {
            _ = withSIGTTOUIgnored { tcsetpgrp(terminal, previousForeground) }
        }
        if savedTermiosIsValid {
            _ = tcsetattr(terminal, TCSADRAIN, &savedTermios)
        }
        return process.terminationStatus
        #endif
    }

    /// `tcsetpgrp` from a background process group signals `SIGTTOU` at the
    /// caller, which would stop the very host trying to take its terminal
    /// back. The signal is turned off around the call, as a shell does.
    private static func withSIGTTOUIgnored<T>(_ body: () -> T) -> T {
        let previous = signal(SIGTTOU, SIG_IGN)
        defer { _ = signal(SIGTTOU, previous) }
        return body()
    }

    /// Everything a temporary build left behind.
    public static func discard(binary: String) {
        let directory = (binary as NSString).deletingLastPathComponent
        guard directory.contains("basic-jit-") else { return }
        try? FileManager.default.removeItem(atPath: directory)
    }
}
