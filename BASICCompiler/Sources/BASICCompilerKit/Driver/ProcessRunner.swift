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

    /// Runs an executable and waits for it, capturing both streams through
    /// files so a chatty tool cannot deadlock on a full pipe buffer.
    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, workingDirectory: String? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }

        // **Both streams go to files, and nothing here blocks.** A pipe holds
        // 64KB: read stdout to EOF and *then* stderr, and a tool that fills
        // stderr meanwhile can no longer write, never exits, and is never read
        // — `swift package dump-symbol-graph` over ActiveUI emits 3,000+
        // warning lines and hung exactly there for ten hours.
        //
        // Draining the second pipe on `DispatchQueue.global()` fixes that one
        // and buys a worse one: every concurrent call blocks a pool thread
        // waiting for its reader, and the suite runs dozens of builds at once,
        // so the pool starves and nobody finishes. A file has no capacity to
        // run out of, so the child writes freely and we read after it exits.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("basicc-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outURL = directory.appendingPathComponent("stdout")
        let errURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        process.standardOutput = outHandle
        process.standardError = errHandle
        try process.run()
        process.waitUntilExit()
        try? outHandle.close()
        try? errHandle.close()

        let outData = (try? Data(contentsOf: outURL)) ?? Data()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()
        return Result(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
