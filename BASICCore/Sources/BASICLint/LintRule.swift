import BASICSyntax
import Foundation

// The rule model: what a rule is, what it produces, and what decides
// whether it runs.

/// How serious a finding is.
public enum LintSeverity: String, Sendable, Codable, Comparable, CaseIterable {
    case note
    case warning
    case error

    private var rank: Int {
        switch self {
        case .note: return 0
        case .warning: return 1
        case .error: return 2
        }
    }

    public static func < (lhs: LintSeverity, rhs: LintSeverity) -> Bool { lhs.rank < rhs.rank }
}

/// Which body of rules to run.
///
/// `legacy` exists because a program written in 1985 is not badly written,
/// it is written in 1985: line numbers, `GOTO`, and untyped variables are
/// the language it was written in. The profile silences that set as a set,
/// rather than making someone turn off eight rules one at a time.
public enum LintProfile: String, Sendable, Codable, CaseIterable {
    case modern
    case legacy
}

/// One thing a rule found.
public struct LintFinding: Sendable, Codable, Equatable {
    public let ruleID: String
    public let severity: LintSeverity
    public let message: String
    public let path: String
    public let range: LintRange

    public init(ruleID: String, severity: LintSeverity, message: String, path: String, range: LintRange) {
        self.ruleID = ruleID
        self.severity = severity
        self.message = message
        self.path = path
        self.range = range
    }

    /// `path:line:column: severity: message [rule.id]` — the shape
    /// CodeWatch's CLI and the IDEs' issue panes already parse.
    public var rendered: String {
        "\(path):\(range.line):\(range.column): \(severity.rawValue): \(message) [\(ruleID)]"
    }
}

/// What a rule is told about the run.
public struct LintContext: Sendable {
    public let path: String
    public let profile: LintProfile
    /// The severity this rule reports at, after any override.
    public let severity: LintSeverity
    /// Per-rule options from the configuration.
    public let options: [String: LintOptionValue]
    /// What a whole-program rule needs, worked out once.
    public let facts: ProgramFacts

    public init(path: String, profile: LintProfile, severity: LintSeverity, options: [String: LintOptionValue], facts: ProgramFacts) {
        self.path = path
        self.profile = profile
        self.severity = severity
        self.options = options
        self.facts = facts
    }

    /// An integer option, or its default.
    public func option(_ name: String, default fallback: Int) -> Int {
        if case .number(let value)? = options[name] { return Int(value) }
        return fallback
    }

    /// A finding at a node, from this rule.
    public func finding(_ rule: String, _ message: String, at range: LintRange) -> LintFinding {
        LintFinding(ruleID: rule, severity: severity, message: message, path: path, range: range)
    }
}

/// A configuration value: the shapes `.basiclint.json` actually holds.
public enum LintOptionValue: Sendable, Codable, Equatable {
    case number(Double)
    case string(String)
    case boolean(Bool)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(Bool.self) { self = .boolean(value); return }
        self = .string(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        }
    }
}

/// A rule.
///
/// A rule implements whichever half it needs: `check(node:context:)` for the
/// ones that look at a statement, `check(program:context:)` for the ones
/// that need the whole file. Most correctness rules are the second kind,
/// because "used before it was assigned" is not a property of a statement.
public protocol BASICLintRule: Sendable {
    /// Stable, dotted, and never renamed: it is what a configuration file
    /// and a `// swiftlint:disable`-shaped comment name.
    var id: String { get }
    var name: String { get }
    /// Why the rule exists, in a sentence a person can disagree with.
    var rationale: String { get }
    var defaultSeverity: LintSeverity { get }
    /// The profiles it runs in.
    var supportedProfiles: Set<LintProfile> { get }
    /// Options it reads, with their defaults, for `--explain` and settings.
    var options: [String: LintOptionValue] { get }

    func check(node: LintNode, context: LintContext) -> [LintFinding]
    func check(program tree: LintTree, context: LintContext) -> [LintFinding]
}

public extension BASICLintRule {
    var supportedProfiles: Set<LintProfile> { Set(LintProfile.allCases) }
    var options: [String: LintOptionValue] { [:] }
    func check(node: LintNode, context: LintContext) -> [LintFinding] { [] }
    func check(program tree: LintTree, context: LintContext) -> [LintFinding] { [] }
}
