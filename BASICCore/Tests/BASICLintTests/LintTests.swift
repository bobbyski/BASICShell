@testable import BASICLint
import Foundation
import Testing

// The linter, held to three promises: every rule is reachable, every rule
// has a fixture that trips it, and the rule reference says what the catalog
// says.

enum LintFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// Every fixture, named for the rule it trips.
    static var all: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".bas") }
            .sorted()
    }

    static func lint(_ fixture: String, profile: LintProfile = .modern) throws -> LintResult {
        let path = directory.appendingPathComponent(fixture).path
        return try Linter(configuration: LintConfiguration(profile: profile)).lint(path: path)
    }
}

@Suite("Every rule has a fixture that trips it")
struct RuleFixtureTests {
    @Test(arguments: LintFixtures.all)
    func theFixtureTripsItsOwnRule(fixture: String) throws {
        let ruleID = String(fixture.dropLast(4))
        #expect(RuleCatalog.rule(id: ruleID) != nil, Comment(rawValue: "\(fixture) names no rule"))
        let result = try LintFixtures.lint(fixture)
        let tripped = result.findings.contains { $0.ruleID == ruleID }
        #expect(tripped, Comment(rawValue: "\(fixture) did not trip \(ruleID): \(result.findings.map(\.ruleID).sorted())"))
    }

    @Test func everyRuleHasAFixture() {
        let fixtures = Set(LintFixtures.all.map { String($0.dropLast(4)) })
        let missing = RuleCatalog.all.map(\.id).filter { !fixtures.contains($0) }
        #expect(missing.isEmpty, Comment(rawValue: "rules with no fixture: \(missing.joined(separator: ", "))"))
    }

    @Test func ruleIdentifiersAreUniqueAndDotted() {
        var seen: Set<String> = []
        for rule in RuleCatalog.all {
            #expect(seen.insert(rule.id).inserted, Comment(rawValue: "duplicate rule id \(rule.id)"))
            #expect(rule.id.contains("."), Comment(rawValue: "\(rule.id) is not dotted"))
            #expect(!rule.rationale.isEmpty, Comment(rawValue: "\(rule.id) has no rationale"))
        }
    }
}

@Suite("Profiles")
struct ProfileTests {
    /// The legacy set: the rules a 1985 program should not be nagged about.
    static let legacySet = [
        "style.goto", "style.gosub", "style.line_numbers", "style.let_keyword", "style.implicit_type",
    ]

    @Test(arguments: ProfileTests.legacySet)
    func theLegacyProfileSilencesTheStructuredProgrammingRules(ruleID: String) throws {
        let fixture = "\(ruleID).bas"
        #expect(try LintFixtures.lint(fixture, profile: .modern).findings.contains { $0.ruleID == ruleID })
        #expect(try !LintFixtures.lint(fixture, profile: .legacy).findings.contains { $0.ruleID == ruleID })
    }

    @Test func correctnessRulesRunInBothProfiles() throws {
        for profile in LintProfile.allCases {
            let result = try LintFixtures.lint("correctness.unreachable_code.bas", profile: profile)
            #expect(result.findings.contains { $0.ruleID == "correctness.unreachable_code" }, Comment(rawValue: "\(profile)"))
        }
    }
}

@Suite("The linter's own promises")
struct LinterTests {
    @Test func aFileThatDoesNotParseIsAFindingRatherThanACrash() {
        let result = Linter().lint(source: "PRINT @\n", path: "broken.bas")
        #expect(result.findings.count == 1)
        #expect(result.findings.first?.ruleID == Linter.syntaxErrorRuleID)
        #expect(result.findings.first?.severity == .error)
    }

    @Test func aCleanProgramReportsNothing() {
        let source = """
        DIM total AS INTEGER
        total = 0
        FOR index = 1 TO 2
            total = total + index
        NEXT index
        PRINT total
        """
        let result = Linter().lint(source: source, path: "clean.bas")
        #expect(result.findings.isEmpty, Comment(rawValue: result.findings.map(\.rendered).joined(separator: "\n")))
    }

    @Test func configurationDisablesAndReSeveritizes() throws {
        let path = LintFixtures.directory.appendingPathComponent("style.goto.bas").path
        let source = try String(contentsOfFile: path, encoding: .utf8)

        let disabled = LintConfiguration(disabled: ["style.goto"])
        #expect(!Linter(configuration: disabled).lint(source: source, path: path).findings.contains { $0.ruleID == "style.goto" })

        let raised = LintConfiguration(severities: ["style.goto": .error])
        let finding = Linter(configuration: raised).lint(source: source, path: path).findings.first { $0.ruleID == "style.goto" }
        #expect(finding?.severity == .error)
    }

    @Test func optionsComeFromTheConfiguration() {
        let source = "PRINT \"" + String(repeating: "x", count: 40) + "\"\n"
        let strict = LintConfiguration(options: ["style.line_length": ["limit": .number(20)]])
        let findings = Linter(configuration: strict).lint(source: source, path: "long.bas").findings
        #expect(findings.contains { $0.ruleID == "style.line_length" })
        #expect(!Linter().lint(source: source, path: "long.bas").findings.contains { $0.ruleID == "style.line_length" })
    }

    @Test func findingsRenderTheWayAnIssuePaneReadsThem() {
        let finding = LintFinding(
            ruleID: "style.goto", severity: .warning, message: "GOTO", path: "a.bas",
            range: LintRange(line: 3, column: 5)
        )
        #expect(finding.rendered == "a.bas:3:5: warning: GOTO [style.goto]")
    }

    @Test func metricsCountWhatTheyClaimTo() throws {
        let result = try LintFixtures.lint("complexity.cyclomatic.bas")
        let routine = result.metrics.routines.first { $0.name?.uppercased() == "TANGLED" }
        #expect(routine != nil)
        #expect((routine?.cyclomaticComplexity ?? 0) > 10)
        #expect(result.metrics.routines.contains { $0.name == nil }, "the main program is measured too")
    }

    @Test func theBackwardJumpCountIsTheSpaghettiMeasure() throws {
        let result = try LintFixtures.lint("style.goto.bas")
        let main = result.metrics.routines.first { $0.name == nil }
        #expect(main?.gotoCount == 1)
        #expect(main?.backwardJumpCount == 1, "GOTO to a label above it is a backward jump")
    }
}

@Suite("The rule reference and the demo tree")
struct RuleReferenceTests {
    /// Where the generated reference lives.
    static var referencePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BASICLintTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // BASICCore
            .deletingLastPathComponent()   // Code
            .deletingLastPathComponent()   // the repository
            .appendingPathComponent("Documents/BASIC_LINT_RULES.md").path
    }

    @Test func theRuleReferenceMatchesTheCatalog() throws {
        let generated = RuleCatalog.referenceMarkdown
        guard let onDisk = try? String(contentsOfFile: Self.referencePath, encoding: .utf8) else {
            Issue.record("BASIC_LINT_RULES.md is missing; regenerate it from RuleCatalog.referenceMarkdown")
            return
        }
        // Generated rather than written, so it cannot drift: when this fails,
        // write `RuleCatalog.referenceMarkdown` back to the file.
        #expect(onDisk == generated, "BASIC_LINT_RULES.md is stale; regenerate it from RuleCatalog.referenceMarkdown")
    }

    /// The demo tree is the corpus: 49 programs nobody wrote to be linted.
    static var demoDirectory: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("basicPrograms/demos").path
    }

    static var demoPrograms: [String] {
        let enumerator = FileManager.default.enumerator(atPath: demoDirectory)
        return ((enumerator?.allObjects as? [String]) ?? [])
            .filter { $0.hasSuffix(".bas") }
            .map { (demoDirectory as NSString).appendingPathComponent($0) }
            .sorted()
    }

    @Test(.enabled(if: !RuleReferenceTests.demoPrograms.isEmpty))
    func theDemoTreeLintsWithoutSurprises() throws {
        var byRule: [String: Int] = [:]
        var errors: [LintFinding] = []
        for path in Self.demoPrograms {
            let result = try Linter().lint(path: path)
            for finding in result.findings {
                byRule[finding.ruleID, default: 0] += 1
                if finding.severity == .error { errors.append(finding) }
            }
        }
        // Every error in the tree is one of the four that are meant to be
        // there: the two deliberately broken files, and the two branches
        // error-trapping-suite takes to prove they fail.
        let expectedErrors = [
            "syntax.error": 2,
            "correctness.missing_branch_target": 2,
        ]
        var actualErrors: [String: Int] = [:]
        for error in errors { actualErrors[error.ruleID, default: 0] += 1 }
        #expect(
            actualErrors == expectedErrors,
            Comment(rawValue: "errors in the demo tree changed: \(actualErrors) — " + errors.map(\.rendered).joined(separator: "\n"))
        )
        // The legacy profile silences the structured-programming rules and
        // nothing else.
        var legacyByRule: [String: Int] = [:]
        for path in Self.demoPrograms {
            let result = try Linter(configuration: LintConfiguration(profile: .legacy)).lint(path: path)
            for finding in result.findings { legacyByRule[finding.ruleID, default: 0] += 1 }
        }
        for silenced in ProfileTests.legacySet {
            #expect(legacyByRule[silenced] == nil, Comment(rawValue: "\(silenced) still fires in legacy"))
        }
        for (rule, count) in byRule where !ProfileTests.legacySet.contains(rule) {
            #expect(legacyByRule[rule] == count, Comment(rawValue: "\(rule) differs between profiles"))
        }
    }
}
