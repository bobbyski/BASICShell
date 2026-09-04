import Foundation

/// `.basiclint.json` — what a project says about how it wants to be linted.
///
/// ```json
/// {
///   "profile": "legacy",
///   "disabled": ["style.magic_number"],
///   "severities": { "correctness.unused_variable": "error" },
///   "options": { "complexity.cyclomatic": { "threshold": 15 } }
/// }
/// ```
///
/// Found by walking up from the file being linted, so a directory of legacy
/// programs can say so once. Hosts that have no files build the same value
/// in memory.
public struct LintConfiguration: Sendable, Codable, Equatable {
    public var profile: LintProfile
    public var disabled: Set<String>
    public var severities: [String: LintSeverity]
    public var options: [String: [String: LintOptionValue]]

    public init(
        profile: LintProfile = .modern,
        disabled: Set<String> = [],
        severities: [String: LintSeverity] = [:],
        options: [String: [String: LintOptionValue]] = [:]
    ) {
        self.profile = profile
        self.disabled = disabled
        self.severities = severities
        self.options = options
    }

    /// The name a configuration file has.
    public static let fileName = ".basiclint.json"

    /// Reads the configuration for a file, walking up from its directory
    /// until one is found or the root is reached.
    public static func find(for path: String, in fileManager: FileManager = .default) -> LintConfiguration {
        var directory = (path as NSString).deletingLastPathComponent
        while !directory.isEmpty, directory != "/" {
            let candidate = (directory as NSString).appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: candidate), let found = try? load(at: candidate) {
                return found
            }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory { break }
            directory = parent
        }
        return LintConfiguration()
    }

    /// Reads one configuration file.
    public static func load(at path: String) throws -> LintConfiguration {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(LintConfiguration.self, from: data)
    }

    /// Whether a rule runs, given its profile support.
    public func runs(_ rule: any BASICLintRule) -> Bool {
        !disabled.contains(rule.id) && rule.supportedProfiles.contains(profile)
    }

    /// The severity a rule reports at.
    public func severity(for rule: any BASICLintRule) -> LintSeverity {
        severities[rule.id] ?? rule.defaultSeverity
    }

    /// A rule's options, its defaults overlaid with the configuration's.
    public func options(for rule: any BASICLintRule) -> [String: LintOptionValue] {
        rule.options.merging(options[rule.id] ?? [:]) { _, configured in configured }
    }
}
