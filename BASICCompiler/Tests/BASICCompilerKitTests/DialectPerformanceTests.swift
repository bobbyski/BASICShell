@testable import BASICCompilerKit
import BASICDialectSwift
import BASICDialectTraditional
import Foundation
import Testing

/// The round-trip performance gate (R2.4).
///
/// A named requirement rather than a hope: the plan records that
/// ActivePascal shipped owing this one, and says not to repeat it.
///
/// ## Why the gate is a ratio
///
/// Rev 2's time is compared to **Rev 1's, in the same run, on the same
/// machine** — not to a wall-clock budget. An absolute number passes or fails
/// on how busy the machine is; the ratio between two binaries built from one
/// source in one run is a property of the compiler, which is the thing under
/// test. Best-of-three, because the minimum is the sample least contaminated
/// by whatever else was running.
///
/// ## What it caught being right
///
/// Object-heavy code runs about **twice as fast** under Rev 2 — a Swift
/// object reads a field at a known offset, where the runtime's record walks a
/// boxed value list. String code is level, which is the load-bearing half of
/// the claim in R2.1: strings stay the runtime's own inside a program and are
/// converted only where they cross into Swift, so a BASIC-only string program
/// should pay nothing. A regression here means a conversion crept into a path
/// that never leaves BASIC.
struct DialectPerformanceTests {
    /// Rev 2 may not be slower than this multiple of Rev 1.
    ///
    /// Generous on purpose. The gate exists to catch a change of *kind* — an
    /// accidental conversion in a hot path, a copy where there was none — not
    /// to police a few percent, which on a shared machine is noise.
    static let limit = 1.5

    static var benchmarks: [String] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Benchmarks").path
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasSuffix(".bas") }.sorted()
            .map { (directory as NSString).appendingPathComponent($0) }
    }

    /// The best of `repeats` runs, in seconds, and what the program printed.
    static func time(_ binary: String, repeats: Int = 3) throws -> (seconds: Double, output: String) {
        var best = Double.infinity
        var output = ""
        for _ in 0..<repeats {
            let start = Date()
            let run = try ProcessRunner.run(binary, [])
            best = min(best, -start.timeIntervalSinceNow)
            output = run.stdout
        }
        return (best, output)
    }

    @Test func revTwoIsNotSlowerThanRevOne() throws {
        let benchmarks = Self.benchmarks
        try #require(!benchmarks.isEmpty, "no benchmarks found")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialect-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var failures: [String] = []
        // Building and timing recurse deeply enough to overflow a test
        // thread's stack — see DialectParityTests for the same note.
        DialectParityTests.onABigStack {
            do {
                for program in benchmarks {
                    let name = ((program as NSString).lastPathComponent as NSString).deletingPathExtension
                    let one = directory.appendingPathComponent("rev1-\(name)").path
                    let two = directory.appendingPathComponent("rev2-\(name)").path
                    try Compilation(dialect: TraditionalDialect()).build(sourcePath: program, output: one)
                    try Compilation(dialect: SwiftDialect()).build(sourcePath: program, output: two)

                    let rev1 = try Self.time(one)
                    let rev2 = try Self.time(two)
                    // Fast and wrong is not fast.
                    if rev1.output != rev2.output {
                        failures.append("\(name): the dialects disagree — \(rev1.output.debugDescription) vs \(rev2.output.debugDescription)")
                        continue
                    }
                    let ratio = rev2.seconds / max(rev1.seconds, 0.0001)
                    if ratio > Self.limit {
                        failures.append(String(format: "%@: Rev 2 took %.3fs against Rev 1's %.3fs — %.2fx, over the %.2fx limit",
                                               name, rev2.seconds, rev1.seconds, ratio, Self.limit))
                    }
                }
            } catch {
                failures.append("\(error)")
            }
        }
        let report = failures.joined(separator: "\n")
        #expect(failures.isEmpty, "the performance gate:\n\(report)")
    }
}
