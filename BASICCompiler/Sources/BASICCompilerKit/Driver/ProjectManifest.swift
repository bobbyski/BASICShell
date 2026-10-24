import Foundation
import BASICRecipes

/// A `.basproj` project in its directory form: a folder holding
/// `project.json` (BASPROJ_AND_BASLIB.md §4).
///
/// ```text
///   MyApp/                 ← basicc build MyApp   (or MyApp/project.json)
///     project.json         { "schemaVersion": 1, "kind": "project",
///                            "name": …, "entry": "Sources/main.bas",
///                            "options": { "stringSub": true } }
///     Sources/main.bas
/// ```
///
/// Inside a project, IMPORT paths resolve against the project root (the
/// document's rule), and `options.stringSub` replaces the shell's default.
/// A zipped project is opened by `ProjectContainer` and read as the directory
/// it unpacks to, so both forms load the same way. Which file runs is
/// `BASICProjectFolder`'s one rule, shared with BASICStudio, BASICShell and the
/// recipes (BASIC-72).
public struct ProjectManifest: Decodable {
    public let schemaVersion: Int
    public let kind: String
    public let name: String
    public let entry: String?
    public let options: Options?
    /// Libraries the project names, in the order it names them.
    public let libraries: [Library]?

    /// One entry of the manifest's `libraries` list.
    public struct Library: Decodable, Sendable {
        public let name: String
        public let path: String
    }

    public struct Options: Decodable {
        public let stringSub: Bool?
        public let shellMode: Bool?
        /// Which compiler builds this project: `"traditional"` (the default)
        /// or `"swift"`.
        ///
        /// The project's own answer, so a scheme carries the dialect into the
        /// build rather than every invocation having to remember `--dialect`
        /// (R5.3). An explicit `--dialect` on the command line still wins, and
        /// the driver says which one it used.
        public let dialect: String?
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, name, entry, options, libraries
    }

    /// The directory holding the manifest.
    public private(set) var root = ""

    /// The entry point, by its path in the project, as `BASICProjectFolder`'s rule
    /// found it when the manifest loaded.
    public private(set) var entryRelativePath = ""

    /// The entry point's absolute path.
    public var entryPath: String {
        (root as NSString).appendingPathComponent(entryRelativePath)
    }

    /// `OPTION STRING-SUB` as the project starts.
    public var stringSubstitution: Bool {
        options?.stringSub ?? true
    }

    /// The manifest for a path that is a project directory or its
    /// `project.json`; nil when the path is a plain source file.
    public static func load(at path: String) throws -> ProjectManifest? {
        // A zipped `.basproj` is unpacked and read as the directory it is.
        var path = path
        if ProjectContainer.isZippedContainer(path) {
            path = try ProjectContainer.directory(of: path)
        }
        var manifestPath = path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            manifestPath = (path as NSString).appendingPathComponent("project.json")
            guard FileManager.default.fileExists(atPath: manifestPath) else { return nil }
        } else if (path as NSString).lastPathComponent != "project.json" {
            return nil
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        var manifest: ProjectManifest
        do {
            manifest = try JSONDecoder().decode(ProjectManifest.self, from: data)
        } catch {
            throw CompileError("\(manifestPath): \(error.localizedDescription)", at: nil)
        }
        guard manifest.schemaVersion <= 1 else {
            throw CompileError("\(manifestPath): schemaVersion \(manifest.schemaVersion) is newer than basicc understands (1)", at: nil)
        }
        guard manifest.kind == "project" else {
            throw CompileError("\(manifestPath): kind '\(manifest.kind)' is not a project; basicc builds projects", at: nil)
        }
        manifest.root = (manifestPath as NSString).deletingLastPathComponent
        manifest.entryRelativePath = try manifest.findEntry(manifestPath: manifestPath)
        return manifest
    }

    /// The file the project starts with, by the rule every tool shares: `entry` as
    /// given, else the first of `src/main.bas`, `Sources/main.bas`, `main.bas` there.
    private func findEntry(manifestPath: String) throws -> String {
        let point = BASICProjectFolder.entryPoint(manifest: BASICProjectFolder.Manifest(entry: entry)) { path in
            FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(path))
        }
        switch point {
        case .file(let path):
            return path
        case .missing(let path):
            throw CompileError("\(manifestPath): the entry \(path) isn't in the project", at: nil)
        case .none:
            let candidates = BASICProjectFolder.entryCandidates.joined(separator: ", ")
            throw CompileError("\(manifestPath): no entry is named, and none of \(candidates) is there", at: nil)
        }
    }
}
