@testable import BASICCompilerKit
import Foundation
import Testing

// The demo sweep as a gate.
//
// `Scripts/compiler-demo-sweep.py` builds and runs every program under
// `basicPrograms/demos/` with both `basicc` and `BASICShell` and writes a
// verdict for each. `Documents/BASIC_COMPILER_COMPATABILITY.md` states what
// those verdicts are. This test runs the sweep and holds the two together:
// a demo that stops compiling fails it, and so does one that starts
// compiling, until the document is regenerated to say so.
//
// It takes about three minutes, most of it the four demos that wait for a
// key until their limit expires. Set BASICC_SKIP_DEMO_SWEEP to skip it.

enum DemoSweep {
    /// The repository root — `Code/BASICCompiler` is three levels down.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // BASICCompilerKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // BASICCompiler
        .deletingLastPathComponent()   // Code
        .deletingLastPathComponent()   // the repository

    static var script: String { root.appendingPathComponent("Scripts/compiler-demo-sweep.py").path }
    static var document: String { root.appendingPathComponent("Documents/BASIC_COMPILER_COMPATABILITY.md").path }
    static var demos: String { root.appendingPathComponent("basicPrograms/demos").path }
    static var interpreter: String { root.appendingPathComponent("Code/BASICShell/.build/debug/BASICShell").path }
    static var compiler: String { "/opt/homebrew/bin/basicc" }

    /// Whether everything the sweep needs is here.
    static var isAvailable: Bool {
        ProcessInfo.processInfo.environment["BASICC_SKIP_DEMO_SWEEP"] == nil
            && [script, document, demos, interpreter, compiler].allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }

    /// What Table 1 of the compatibility document claims for each demo,
    /// read from its `basicc` column.
    static func documentedVerdicts() throws -> [String: String] {
        let whole = try String(contentsOfFile: document, encoding: .utf8)
        // Table 1 only: table 2's rows are keyed by demo as well, one per
        // failure, and would otherwise overwrite the verdicts.
        guard let start = whole.range(of: "## Table 1"), let end = whole.range(of: "## Table 2") else {
            throw CompileError("BASIC_COMPILER_COMPATABILITY.md has no Table 1 and Table 2", at: BIRLocation(file: nil, line: 0, statement: 0, lineNumber: nil))
        }
        let text = String(whole[start.upperBound..<end.lowerBound])
        var claimed: [String: String] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("| `") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 5, cells[1].hasPrefix("`"), cells[1].hasSuffix("`") else { continue }
            let name = String(cells[1].dropFirst().dropLast())
            guard name.hasSuffix(".bas") else { continue }
            let cell = cells[3]
            let verdict: String
            if cell.hasPrefix("❌") { verdict = "refused" }
            else if cell.contains("identical to BASICShell") { verdict = "identical" }
            else if cell.contains("under a pty") { verdict = "needs a tty" }
            else if cell.contains("compiles") { verdict = "module compiles" }
            else { continue }
            // A module row says "module refused" where a program says "refused".
            claimed[name] = (verdict == "refused" && cells[4].hasPrefix("—")) ? "module refused" : verdict
        }
        return claimed
    }
}

@Suite("The demo sweep matches what the compatibility document claims")
struct DemoSweepTests {
    @Test(.enabled(if: DemoSweep.isAvailable), .timeLimit(.minutes(10)))
    func everyDemoIsWhatTheDocumentSaysItIs() throws {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("basicc-sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workDir) }
        var environment = ProcessInfo.processInfo.environment
        environment["SWEEP_DIR"] = workDir.path
        let run = try ProcessRunner.run("/usr/bin/env", ["python3", DemoSweep.script], environment: environment)
        #expect(run.exitCode == 0, Comment(rawValue: "the sweep itself failed:\n\(run.stderr)"))

        let results = try JSONSerialization.jsonObject(
            with: Data(contentsOf: workDir.appendingPathComponent("results.json"))
        ) as? [String: [String: Any]] ?? [:]
        #expect(!results.isEmpty, "the sweep wrote no results")

        let claimed = try DemoSweep.documentedVerdicts()
        var wrong: [String] = []
        for (name, result) in results.sorted(by: { $0.key < $1.key }) {
            let verdict = result["verdict"] as? String ?? "?"
            guard let expected = claimed[name] else {
                wrong.append("\(name): swept as \(verdict), the document does not list it")
                continue
            }
            if verdict != expected {
                wrong.append("\(name): swept as \(verdict), the document says \(expected)")
            }
        }
        for name in claimed.keys.sorted() where results[name] == nil {
            wrong.append("\(name): in the document, not in the demo tree")
        }
        let report = "the sweep and BASIC_COMPILER_COMPATABILITY.md disagree:\n" + wrong.joined(separator: "\n")
        #expect(wrong.isEmpty, Comment(rawValue: report))
    }
}
