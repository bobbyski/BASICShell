@testable import BASICCompilerKit
import BASICDialectSwift
import BASICDialectTraditional
import Foundation
import Testing

/// The contract between the two dialects, enforced rather than asserted.
///
/// Rev 1 and Rev 2 are allowed to differ *inside* — different object model,
/// different string representation at rest, different error channel, ARC
/// instead of runtime-managed lifetimes. They are not allowed to differ
/// **here**: the same program, compiled by either, must print the same bytes
/// and exit with the same status.
///
/// This is the test that gives that freedom its meaning. Every substrate
/// slice in Rev 2 (R2.1 strings, R2.2 arrays, R3.1 errors) changes what the
/// program *is* underneath; this is what says the program still *does* the
/// same thing. Without it, "the internals may differ" is a hope.
///
/// The interpreter stays the oracle above both — `basictest --interpreter`
/// is where that comparison lives, because it needs a built shell. This one
/// needs only the compiler, so it runs anywhere the package builds.
struct DialectParityTests {
    /// The conformance programs, which are chosen to cover the language
    /// rather than to be quick.
    static var programs: [String] {
        let directory = Self.programsDirectory
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasSuffix(".bas") }
            .sorted()
            .map { (directory as NSString).appendingPathComponent($0) }
    }

    static var programsDirectory: String {
        // From this file, up to the package root: Tests/<suite>/<file>.
        let here = URL(fileURLWithPath: #filePath)
        return here.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Programs").path
    }

    /// Builds `program` with `dialect` into `directory` and runs it.
    static func outcome(
        of program: String,
        under dialect: any DialectCompiler,
        in directory: URL
    ) throws -> (stdout: String, exitCode: Int32) {
        let name = ((program as NSString).lastPathComponent as NSString).deletingPathExtension
        let binary = directory
            .appendingPathComponent("\(type(of: dialect).identity.identifier)-\(name)").path
        try Compilation(dialect: dialect).build(sourcePath: program, output: binary)
        // Run where the program lives: several read data files beside
        // themselves, and a program that cannot find its data prints an error
        // — identically under both dialects, which would pass while proving
        // nothing.
        let result = try ProcessRunner.run(
            binary, [], workingDirectory: (program as NSString).deletingLastPathComponent
        )
        return (result.stdout + result.stderr, result.exitCode)
    }

    /// Runs `body` on a thread with a large stack.
    ///
    /// Not ceremony: lowering a big program recurses over its expression
    /// trees, and a test thread's default stack is far smaller than `main`'s.
    /// `suite-arrays.bas` overflows it and takes the whole test process down
    /// with a bus error — the compiler is fine from the command line, where
    /// it runs on `main`. Worth knowing for any host that drives `Compilation`
    /// off the main thread.
    static func onABigStack(_ body: @escaping () -> Void) {
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            body()
            finished.signal()
        }
        thread.stackSize = 64 << 20
        thread.start()
        finished.wait()
    }

    @Test func bothDialectsRunEveryConformanceProgramIdentically() throws {
        let programs = Self.programs
        try #require(!programs.isEmpty, "no conformance programs found at \(Self.programsDirectory)")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialect-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var divergences: [String] = []
        var failure: Error?
        Self.onABigStack {
            do {
        for program in programs {
            let name = (program as NSString).lastPathComponent
            let traditional = try Self.outcome(of: program, under: TraditionalDialect(), in: directory)
            let swift = try Self.outcome(of: program, under: SwiftDialect(), in: directory)
            if traditional.stdout != swift.stdout {
                divergences.append("\(name): output differs\n  traditional: \(traditional.stdout.debugDescription)\n  swift:       \(swift.stdout.debugDescription)")
            } else if traditional.exitCode != swift.exitCode {
                divergences.append("\(name): exit status \(traditional.exitCode) vs \(swift.exitCode)")
            }
        }
            } catch { failure = error }
        }
        if let failure { throw failure }
        let report = divergences.joined(separator: "\n")
        #expect(divergences.isEmpty, "the dialects must run the same:\n\(report)")
    }
}
