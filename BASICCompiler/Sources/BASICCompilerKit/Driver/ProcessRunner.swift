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
        #if os(macOS)
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
        running.add(process)
        process.waitUntilExit()
        running.remove(process)
        // Interrupted: the tool ended because `interruptAll` stopped it. Its failure is
        // not the caller's to report; the interrupt finishes the cleanup and exits.
        if running.isInterrupting { while true { Thread.sleep(forTimeInterval: 60) } }
        try? outHandle.close()
        try? errHandle.close()

        let outData = (try? Data(contentsOf: outURL)) ?? Data()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()
        return Result(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
        #else
        // iPhone and iPad start no other programs, so there is no clang,
        // swiftc or xcrun to run: the compiler's front end and lowering
        // work there, and the steps after them answer this.
        throw Unavailable(tool: (executable as NSString).lastPathComponent, arguments: arguments)
        #endif
    }

    /// Stops every tool still running, and every process they started: SIGINT
    /// first, which SwiftPM answers by cancelling its build and its compilers,
    /// SIGTERM for anything that outlives its tool, and SIGTERM then SIGKILL for
    /// whatever is left halfway through `seconds`. Returns once they have all
    /// ended or the time is up.
    ///
    /// For an interrupted `basicc`: without it, a `swift build` it started kept
    /// running after `basicc` was killed, and a retry loop stacked builds in one
    /// folder (2026-11-08, ActiveUI's `.build-basicc` at 45 GB).
    public static func interruptAll(waitingUpTo seconds: Double = 10) {
        #if os(macOS)
        let processes = running.snapshot()
        // Their descendants too, listed now: a helper a build starts (Swift Build's
        // `clang-stat-cache`) outlives it, and once its parent is gone it can no longer
        // be found by parent, and goes on writing into the folder being removed.
        let family = descendants(of: processes.map(\.processIdentifier))
        running.isInterrupting = true
        for process in processes where process.isRunning { process.interrupt() }
        let start = Date()
        var terminated = false
        func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }
        while processes.contains(where: \.isRunning) || family.contains(where: alive),
              Date().timeIntervalSince(start) < seconds {
            if !terminated, Date().timeIntervalSince(start) > seconds / 2 {
                for process in processes where process.isRunning { process.terminate() }
                terminated = true
            }
            // Whatever outlived the tool that started it.
            if !processes.contains(where: \.isRunning) {
                for pid in family where alive(pid) { kill(pid, terminated ? SIGKILL : SIGTERM) }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        #endif
    }

    #if os(macOS)
    /// Every process descended from `roots`, from one `ps` listing.
    private static func descendants(of roots: [Int32]) -> [Int32] {
        guard !roots.isEmpty else { return [] }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [] }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        var children: [Int32: [Int32]] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ").compactMap { Int32($0) }
            if fields.count == 2 { children[fields[1], default: []].append(fields[0]) }
        }
        var found: [Int32] = []
        var pending = roots
        while let next = pending.popLast() {
            for child in children[next] ?? [] where !found.contains(child) {
                found.append(child)
                pending.append(child)
            }
        }
        return found
    }
    #endif

    #if os(macOS)
    /// The tools running now, for ``interruptAll(waitingUpTo:)``.
    private static let running = RunningProcesses()

    private final class RunningProcesses: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [ObjectIdentifier: Process] = [:]
        private var interrupting = false

        /// Set once `interruptAll` has begun; never cleared, since the process is ending.
        var isInterrupting: Bool {
            get { lock.lock(); defer { lock.unlock() }; return interrupting }
            set { lock.lock(); defer { lock.unlock() }; interrupting = newValue }
        }

        func add(_ process: Process) {
            lock.lock(); defer { lock.unlock() }
            processes[ObjectIdentifier(process)] = process
        }

        func remove(_ process: Process) {
            lock.lock(); defer { lock.unlock() }
            processes[ObjectIdentifier(process)] = nil
        }

        func snapshot() -> [Process] {
            lock.lock(); defer { lock.unlock() }
            return Array(processes.values)
        }
    }
    #endif

    /// The error on a platform that cannot start another program.
    public struct Unavailable: Error, CustomStringConvertible {
        public let tool: String
        public let arguments: [String]
        public var description: String {
            "\((arguments.first.map { [tool, $0] } ?? [tool]).joined(separator: " ")) cannot run here: this platform does not start other programs"
        }
    }
}
