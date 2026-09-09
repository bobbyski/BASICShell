import Foundation

/// Runs one external tool and captures what it said.
///
/// Every tool the driver invokes goes through `xcrun`, so the toolchain that
/// answers is whichever Xcode is selected — the same one `swift build` uses.
public enum ProcessRunner {
    /// A finished process: exit code plus both streams, fully drained.
    public struct Result {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
    }

    /// Runs `xcrun <tool> <arguments>` and waits for it.
    public static func xcrun(_ tool: String, _ arguments: [String]) throws -> Result {
        try run("/usr/bin/xcrun", [tool] + arguments)
    }

    /// Runs an executable and waits for it, draining both pipes so a chatty
    /// tool cannot deadlock on a full pipe buffer.
    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, workingDirectory: String? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
