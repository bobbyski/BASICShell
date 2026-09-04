import Foundation

/// What an IDE needs from a compiler, whichever language it compiles.
///
/// FreebirdStudio and OmegaCLIDE each discovered schemes, built, and read
/// diagnostics three times over — once for Pascal, once for COBOL, once for
/// BASIC — because each compiler was reached its own way. This is the shape
/// they have in common, published here so `apc` and `cobolc` can adopt it
/// and three scheme discoverers become one (BASIC_COMPILER.md 7.6).
///
/// Deliberately small. It says what an IDE actually does: decide whether it
/// can build a path, build it, and ask what is wrong with a file without
/// building it. Everything else a compiler offers stays behind its own API.
public protocol LanguageCompiler: Sendable {
    /// The language's identifier, matching the IDEs' `LanguageProfile`:
    /// `"basic"`, `"pascal"`, `"cobol"`.
    static var languageIdentifier: String { get }
    /// Source extensions, lowercased and without the dot.
    static var sourceExtensions: Set<String> { get }
    /// Project or library container extensions, lowercased.
    static var containerExtensions: Set<String> { get }

    /// Whether this compiler builds what is at `path` — a source file, a
    /// project directory, or a container.
    func canBuild(path: String) -> Bool

    /// Builds `path` into `output`. Diagnostics come back in the result
    /// rather than as an error, because an IDE shows them either way.
    func build(path: String, output: String) -> LanguageBuildResult

    /// What is wrong with a file, without building it — the check an editor
    /// runs while someone types.
    func diagnostics(for path: String) -> [Diagnostic]
}

/// What a build produced.
public struct LanguageBuildResult: Sendable {
    /// Whether an artifact was produced.
    public let succeeded: Bool
    /// The artifact, when there is one.
    public let artifact: String?
    /// Everything the compiler had to say.
    public let diagnostics: [Diagnostic]

    public init(succeeded: Bool, artifact: String?, diagnostics: [Diagnostic]) {
        self.succeeded = succeeded
        self.artifact = artifact
        self.diagnostics = diagnostics
    }
}

extension Compilation: LanguageCompiler {
    public static var languageIdentifier: String { "basic" }
    public static var sourceExtensions: Set<String> { ["bas"] }
    public static var containerExtensions: Set<String> { ProjectContainer.containerExtensions }

    public func canBuild(path: String) -> Bool {
        let extensionName = (path as NSString).pathExtension.lowercased()
        if Self.sourceExtensions.contains(extensionName) || Self.containerExtensions.contains(extensionName) { return true }
        // A project is a directory holding a manifest, and so is an unpacked
        // container; the manifest is what makes it one.
        return (try? ProjectManifest.load(at: path)) ?? nil != nil
    }

    public func build(path: String, output: String) -> LanguageBuildResult {
        do {
            try build(sourcePath: path, output: output)
            return LanguageBuildResult(succeeded: true, artifact: output, diagnostics: [])
        } catch let error as CompileError {
            return LanguageBuildResult(succeeded: false, artifact: nil, diagnostics: error.diagnostics)
        } catch {
            return LanguageBuildResult(
                succeeded: false, artifact: nil,
                diagnostics: [Diagnostic(severity: .error, file: path, line: nil, message: "\(error)")]
            )
        }
    }

    public func diagnostics(for path: String) -> [Diagnostic] {
        do {
            _ = try bir(sourcePath: path)
            return []
        } catch let error as CompileError {
            return error.diagnostics
        } catch {
            return [Diagnostic(severity: .error, file: path, line: nil, message: "\(error)")]
        }
    }
}
