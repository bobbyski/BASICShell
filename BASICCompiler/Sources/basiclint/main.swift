import BASICLint
import Foundation

// `basiclint` — the linter at the terminal.
//
// Text output is `path:line:column: severity: message [rule.id]`, the shape
// CodeWatch's CLI and the IDEs' issue panes already parse. JSON is the
// findings plus the per-routine metrics, for a host that wants to score a
// file rather than show it.

let usage = """
basiclint 0.1.0 — a linter for BASIC

usage:
  basiclint [paths…] [options]      lint files and directories
  basiclint --list-rules            every rule, with its default severity
  basiclint --explain <rule.id>     what a rule is for
  basiclint --rules-markdown        the rule reference, generated from the catalog

options:
  --profile modern|legacy   which body of rules to run (default: modern)
  --config <file>           a .basiclint.json to use instead of searching
  --format text|json        how to report (default: text)
  --fail-on never|warnings|errors
                            what makes the exit code non-zero (default: errors)
"""

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("basiclint: \(message)\n".utf8))
    exit(code)
}

struct Options {
    var paths: [String] = []
    var profile: LintProfile?
    var configPath: String?
    var format = "text"
    var failOn = "errors"
    var listRules = false
    var explain: String?
}

var options = Options()
var arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--help", "-h":
        print(usage)
        exit(0)
    case "--list-rules":
        options.listRules = true
    case "--rules-markdown":
        print(RuleCatalog.referenceMarkdown, terminator: "")
        exit(0)
    case "--explain":
        index += 1
        guard index < arguments.count else { fail("--explain needs a rule id") }
        options.explain = arguments[index]
    case "--profile":
        index += 1
        guard index < arguments.count, let profile = LintProfile(rawValue: arguments[index]) else {
            fail("--profile is modern or legacy")
        }
        options.profile = profile
    case "--config":
        index += 1
        guard index < arguments.count else { fail("--config needs a path") }
        options.configPath = arguments[index]
    case "--format":
        index += 1
        guard index < arguments.count, ["text", "json"].contains(arguments[index]) else { fail("--format is text or json") }
        options.format = arguments[index]
    case "--fail-on":
        index += 1
        guard index < arguments.count, ["never", "warnings", "errors"].contains(arguments[index]) else {
            fail("--fail-on is never, warnings, or errors")
        }
        options.failOn = arguments[index]
    default:
        if argument.hasPrefix("-") { fail("unknown option '\(argument)'") }
        options.paths.append(argument)
    }
    index += 1
}

if options.listRules {
    for rule in RuleCatalog.all {
        let profiles = rule.supportedProfiles.map(\.rawValue).sorted().joined(separator: ",")
        print("\(rule.id)  \(rule.defaultSeverity.rawValue)  [\(profiles)]  \(rule.name)")
    }
    exit(0)
}

if let id = options.explain {
    guard let rule = RuleCatalog.rule(id: id) else { fail("no rule called \(id)") }
    print("\(rule.id) — \(rule.name)")
    print("severity: \(rule.defaultSeverity.rawValue)")
    print("profiles: \(rule.supportedProfiles.map(\.rawValue).sorted().joined(separator: ", "))")
    if !rule.options.isEmpty {
        let described = rule.options.sorted { $0.key < $1.key }.map { "\($0.key)=\(render($0.value))" }
        print("options:  \(described.joined(separator: ", "))")
    }
    print("")
    print(rule.rationale)
    exit(0)
}

func render(_ value: LintOptionValue) -> String {
    switch value {
    case .number(let number): return number.rounded() == number ? String(Int(number)) : String(number)
    case .string(let text): return text
    case .boolean(let flag): return flag ? "true" : "false"
    }
}

guard !options.paths.isEmpty else {
    print(usage)
    exit(2)
}

/// Every `.bas` under a path, recursing into directories.
func sources(at path: String) -> [String] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
        fail("\(path) does not exist")
    }
    guard isDirectory.boolValue else { return [path] }
    let enumerator = FileManager.default.enumerator(atPath: path)
    return ((enumerator?.allObjects as? [String]) ?? [])
        .filter { ($0 as NSString).pathExtension.lowercased() == "bas" }
        .map { (path as NSString).appendingPathComponent($0) }
        .sorted()
}

let files = options.paths.flatMap(sources(at:))
var results: [LintResult] = []
for file in files {
    var configuration: LintConfiguration
    if let configPath = options.configPath {
        do { configuration = try LintConfiguration.load(at: configPath) } catch { fail("\(configPath): \(error)") }
    } else {
        configuration = LintConfiguration.find(for: file)
    }
    // The flag wins over the file, because it is the more specific thing
    // someone just typed.
    if let profile = options.profile { configuration.profile = profile }
    do {
        results.append(try Linter(configuration: configuration).lint(path: file))
    } catch {
        fail("\(file): \(error)")
    }
}

if options.format == "json" {
    struct Report: Encodable {
        let path: String
        let findings: [LintFinding]
        let metrics: Metrics
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let report = results.map { Report(path: $0.path, findings: $0.findings, metrics: $0.metrics) }
    print(String(decoding: try encoder.encode(report), as: UTF8.self))
} else {
    for result in results {
        for finding in result.findings { print(finding.rendered) }
    }
    let all = results.flatMap(\.findings)
    let errors = all.filter { $0.severity == .error }.count
    let warnings = all.filter { $0.severity == .warning }.count
    let notes = all.filter { $0.severity == .note }.count
    if all.isEmpty {
        print("\(files.count) file\(files.count == 1 ? "" : "s"), nothing to report")
    } else {
        print("\(files.count) file\(files.count == 1 ? "" : "s"): \(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s"), \(notes) note\(notes == 1 ? "" : "s")")
    }
}

let all = results.flatMap(\.findings)
switch options.failOn {
case "never": exit(0)
case "warnings": exit(all.contains { $0.severity >= .warning } ? 1 : 0)
default: exit(all.contains { $0.severity == .error } ? 1 : 0)
}
