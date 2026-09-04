import Foundation

/// Runs one external tool and captures what it said.
///
/// Every tool the driver invokes goes through `xcrun`, so the toolchain that
/// answers is whichever Xcode is selected — the same one `swift build` uses.
enum ProcessRunner {
    /// A finished process: exit code plus both streams, fully drained.
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs `xcrun <tool> <arguments>` and waits for it.
    static func xcrun(_ tool: String, _ arguments: [String]) throws -> Result {
        try run("/usr/bin/xcrun", [tool] + arguments)
    }

    /// Runs an executable and waits for it, draining both pipes so a chatty
    /// tool cannot deadlock on a full pipe buffer.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

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
