//
//  BASICJIT.swift
//  BASICCore
//
//  Compiling the program in front of you and running it.
//

import Foundation

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
/// and DWARF is not emitted yet, so a host that offers `JIT` alongside a
/// debugger has to say that breakpoints do not apply to it.
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
        let searched = (environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin")
            .split(separator: ":").map(String.init)
        for directory in searched {
            let candidate = (directory as NSString).appendingPathComponent("basicc")
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

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
    public static func compile(
        source: String,
        path: String?,
        optimization: String = "-O0",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Outcome {
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
        process.arguments = ["build", sourcePath, optimization, "-o", binary]
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
    }

    /// The text of a program, as a file the compiler can read.
    ///
    /// Numbered lines keep their numbers, because a diagnostic that names a
    /// line has to name the one the program was written with.
    public static func text(of program: BASICProgram) -> String {
        program.orderedLines
            .map { $0.number.map { number in "\(number) " } ?? "" }
            .enumerated()
            .map { index, prefix in prefix + program.orderedLines[index].source }
            .joined(separator: "\n") + "\n"
    }

    /// Runs a compiled binary with the terminal it was started from, so
    /// `INPUT`, `INKEY$` and a TUI application all behave as they would
    /// under `RUN`. Answers its exit status.
    @discardableResult
    public static func run(binary: String, arguments: [String] = []) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            return 127
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Everything a temporary build left behind.
    public static func discard(binary: String) {
        let directory = (binary as NSString).deletingLastPathComponent
        guard directory.contains("basic-jit-") else { return }
        try? FileManager.default.removeItem(atPath: directory)
    }
}
