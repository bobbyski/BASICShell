//
//  BASICProjectFolder.swift
//  BASICRecipes
//
//  What a BASIC project folder is, and which file it runs.
//

import Foundation

/// A BASIC project on disk: a folder named `Name.basproj`, holding a
/// `project.json` that names the file to run (BASPROJ_AND_BASLIB.md §4).
///
/// ```text
///   MyGame.basproj/
///     project.json    { "schemaVersion": 1, "kind": "project",
///                       "name": "MyGame", "entry": "src/main.bas" }
///     src/main.bas    the program; its modules beside it
/// ```
///
/// `entry` is the one thing that says which file starts the program.
/// ``entryPoint(manifest:exists:)`` is the rule, and every tool uses it:
/// `basicc`, BASICStudio, BASICShell and these recipes (BASIC-72). Without an
/// `entry`, a project runs `src/main.bas`, then `Sources/main.bas`, then
/// `main.bas`, whichever is there first.
///
/// This type knows folders on disk only, so the IDEs that take this package
/// need nothing else. Zipped projects, and recognizing either form, are
/// `BASICProjects` (over ProjectKit).
public enum BASICProjectFolder {
    /// The project folder's extension.
    public static let fileExtension = "basproj"
    /// The manifest's name.
    public static let manifestName = "project.json"
    /// Where a project's program is looked for when its manifest names none.
    public static let entryCandidates = ["src/main.bas", "Sources/main.bas", "main.bas"]

    /// `project.json`, as far as finding the program goes.
    public struct Manifest: Codable, Equatable, Sendable {
        public var schemaVersion: Int?
        public var kind: String?
        public var name: String?
        public var entry: String?

        /// A manifest with these fields; each left out is absent.
        public init(schemaVersion: Int? = nil, kind: String? = nil, name: String? = nil, entry: String? = nil) {
            self.schemaVersion = schemaVersion
            self.kind = kind
            self.name = name
            self.entry = entry
        }
    }

    /// Whether `url` is a project: a folder named `.basproj`, or any folder
    /// with a `project.json` in it.
    public static func isProject(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return url.pathExtension.lowercased() == fileExtension
            || FileManager.default.fileExists(atPath: url.appendingPathComponent(manifestName).path)
    }

    /// The project's name: its manifest's, else its folder's without
    /// `.basproj`.
    public static func name(of project: URL) -> String {
        if let name = manifest(of: project)?.name, !name.isEmpty {
            return name
        }
        return displayName(ofFolder: project.lastPathComponent)
    }

    /// `MyGame.basproj` as `MyGame`; any other folder name as it is.
    public static func displayName(ofFolder name: String) -> String {
        let suffix = "." + fileExtension
        guard name.lowercased().hasSuffix(suffix), name.count > suffix.count else { return name }
        return String(name.dropLast(suffix.count))
    }

    /// The project's manifest, or nil when it has none or it cannot be read.
    public static func manifest(of project: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: project.appendingPathComponent(manifestName)) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Where a project starts, as ``entryPoint(manifest:exists:)`` finds it.
    public enum EntryPoint: Equatable, Sendable {
        /// The file to run, by its path in the project (`src/main.bas`).
        case file(String)
        /// The manifest names this file, and it isn't there.
        case missing(String)
        /// The manifest names no file, and none of ``entryCandidates`` is there.
        case none
    }

    /// The rule for which file a project runs, the same in every tool: the
    /// manifest's `entry` when it names one, whether or not it is there (a
    /// missing one is reported, never swapped for another); else the first of
    /// ``entryCandidates`` that `exists` says is there.
    ///
    /// `exists` answers for a path in the project, so the rule works on a
    /// folder, a zip read in place, or a zip's working copy alike.
    public static func entryPoint(manifest: Manifest?, exists: (String) -> Bool) -> EntryPoint {
        if let entry = manifest?.entry, !entry.isEmpty {
            return exists(entry) ? .file(entry) : .missing(entry)
        }
        return entryCandidates.first(where: exists).map(EntryPoint.file) ?? .none
    }

    /// The file the project folder starts with, by ``entryPoint(manifest:exists:)``;
    /// nil when its manifest names a missing file, or it has none to run.
    public static func entry(of project: URL) -> URL? {
        let point = entryPoint(manifest: manifest(of: project)) { path in
            FileManager.default.fileExists(atPath: project.appendingPathComponent(path).path)
        }
        guard case .file(let path) = point else { return nil }
        return project.appendingPathComponent(path)
    }

    /// The manifest a new project gets: its name, and the file it starts with.
    public static func manifestText(name: String, entry: String) -> String {
        """
        {
          "schemaVersion": 1,
          "kind": "project",
          "name": "\(name)",
          "entry": "\(entry)"
        }

        """
    }
}
