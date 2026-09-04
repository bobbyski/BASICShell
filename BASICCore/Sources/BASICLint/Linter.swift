import BASICSyntax
import Foundation

/// Every rule the linter knows, in the order they are reported.
public enum RuleCatalog {
    public static let all: [any BASICLintRule] = [
        // Correctness — probably a bug, in any profile.
        UseBeforeAssignmentRule(),
        DimAfterUseRule(),
        UnusedVariableRule(),
        UnusedRoutineRule(),
        UnusedLabelRule(),
        MissingBranchTargetRule(),
        ForVariableAssignedRule(),
        LoopVariableMismatchRule(),
        ResumeWithoutHandlerRule(),
        DuplicateTargetRule(),
        DataWithoutReadRule(),
        UnreachableCodeRule(),
        OptionAfterCodeRule(),
        MissingImportRule(),
        // Style and structure.
        GotoRule(),
        GosubRule(),
        LineNumberRule(),
        LetKeywordRule(),
        ImplicitTypeRule(),
        MixedLetModeRule(),
        MagicNumberRule(),
        LineLengthRule(),
        TrailingWhitespaceRule(),
        EmptyBranchRule(),
        DeeplyNestedIfRule(),
        // Complexity, with CodeWatch's ids and thresholds.
        CyclomaticComplexityRule(),
        LongRoutineRule(),
        LongParameterListRule(),
        NestedBlockDepthRule(),
        LargeTypeRule(),
        TooManyFieldsRule(),
    ]

    /// A rule by id.
    public static func rule(id: String) -> (any BASICLintRule)? {
        all.first { $0.id == id }
    }
}

/// What one file's run produced.
public struct LintResult: Sendable {
    public let path: String
    public let findings: [LintFinding]
    public let metrics: Metrics

    public init(path: String, findings: [LintFinding], metrics: Metrics) {
        self.path = path
        self.findings = findings
        self.metrics = metrics
    }
}

/// The linter.
///
/// One file in, findings and metrics out. It parses with the same parser the
/// interpreter and the compiler use, so a program lints exactly as it runs,
/// and a file that does not parse comes back as a `syntax.error` finding
/// rather than as a crash or a silence.
public struct Linter: Sendable {
    public let configuration: LintConfiguration
    public let rules: [any BASICLintRule]

    public init(configuration: LintConfiguration = LintConfiguration(), rules: [any BASICLintRule] = RuleCatalog.all) {
        self.configuration = configuration
        self.rules = rules
    }

    /// The id a parse failure is reported under.
    public static let syntaxErrorRuleID = "syntax.error"

    /// Lints source text.
    public func lint(source: String, path: String) -> LintResult {
        let tree = LintTree.build(source: source, fileName: (path as NSString).lastPathComponent)
        if let failure = tree.syntaxError {
            let finding = LintFinding(
                ruleID: Self.syntaxErrorRuleID, severity: .error, message: failure.message,
                path: path, range: LintRange(line: failure.line, column: 1)
            )
            return LintResult(path: path, findings: [finding], metrics: Metrics.measure(tree))
        }
        let facts = ProgramFacts.build(tree)
        // The root's own children are statements too: a program's top level
        // is where most of a BASIC program lives.
        let nodes = [tree.root] + tree.root.descendants
        var findings: [LintFinding] = []
        for rule in rules where configuration.runs(rule) {
            let context = LintContext(
                path: path, profile: configuration.profile,
                severity: configuration.severity(for: rule),
                options: configuration.options(for: rule), facts: facts
            )
            findings += rule.check(program: tree, context: context)
            for node in nodes {
                findings += rule.check(node: node, context: context)
            }
        }
        findings.sort {
            ($0.range.line, $0.range.column, $0.ruleID) < ($1.range.line, $1.range.column, $1.ruleID)
        }
        return LintResult(path: path, findings: findings, metrics: Metrics.measure(tree))
    }

    /// Lints a file.
    public func lint(path: String) throws -> LintResult {
        let source = try String(contentsOfFile: path, encoding: .utf8)
        return lint(source: source, path: path)
    }
}

// MARK: - The rule reference

public extension RuleCatalog {
    /// `RULES.md`, generated from the catalog.
    ///
    /// Generated rather than written, and checked by a test, because a rule
    /// reference that drifts from the rules is worse than none: it is the
    /// document people quote at each other while the linter does something
    /// else.
    static var referenceMarkdown: String {
        var text = """
        # BASIC lint rules

        Generated from `RuleCatalog` — edit the rules, not this file. A test
        fails when the two disagree.

        There is no corpus of BASIC lint data to learn from, so every rule
        here is authored: from the language documents, from what the demos
        and the interpreter's tests actually do, and from what CodeWatch's
        other languages already check. Each one says why it exists, so it can
        be disagreed with.

        ## Profiles

        | Profile | What it runs |
        |---|---|
        | `modern` | everything (the default) |
        | `legacy` | everything except the structured-programming rules — `GOTO`, `GOSUB`, line numbers, `LET`, and implicit types. A program written in 1985 is not badly written; it is written in 1985. |

        ## Configuration

        `.basiclint.json`, found by walking up from the file:

        ```json
        {
          "profile": "legacy",
          "disabled": ["style.magic_number"],
          "severities": { "correctness.unused_variable": "error" },
          "options": { "complexity.cyclomatic": { "threshold": 15 } }
        }
        ```


        """
        var byPrefix: [String: [any BASICLintRule]] = [:]
        for rule in all {
            let prefix = rule.id.split(separator: ".").first.map(String.init) ?? "other"
            byPrefix[prefix, default: []].append(rule)
        }
        let titles = [
            "correctness": "Correctness — probably a bug",
            "style": "Style and structure",
            "complexity": "Complexity",
        ]
        for prefix in ["correctness", "style", "complexity"] {
            guard let rules = byPrefix[prefix] else { continue }
            text += "## \(titles[prefix] ?? prefix)\n\n"
            for rule in rules {
                text += "### `\(rule.id)`\n\n"
                text += "**\(rule.name)** · \(rule.defaultSeverity.rawValue)"
                let profiles = rule.supportedProfiles.map(\.rawValue).sorted()
                text += profiles.count == LintProfile.allCases.count ? " · both profiles" : " · \(profiles.joined(separator: ", ")) only"
                if !rule.options.isEmpty {
                    let described = rule.options.sorted { $0.key < $1.key }.map { "`\($0.key)` = \(Self.render($0.value))" }
                    text += " · options: \(described.joined(separator: ", "))"
                }
                text += "\n\n\(rule.rationale)\n\n"
            }
        }
        text += """
        ## Not a rule

        `syntax.error` is reported when a file does not parse. It is not in the
        catalog, cannot be configured, and is always an error — a linter that
        stays quiet about a file it could not read is lying about it.

        """
        return text
    }

    private static func render(_ value: LintOptionValue) -> String {
        switch value {
        case .number(let number): return number.rounded() == number ? String(Int(number)) : String(number)
        case .string(let text): return "`\(text)`"
        case .boolean(let flag): return flag ? "true" : "false"
        }
    }
}
