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
/// `entry` is the one thing that says which file starts the program, read
/// the same way here as by `basicc`. Without it, a project runs
/// `src/main.bas`, then `Sources/main.bas`, then `main.bas`, whichever is
/// there first.
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

    /// The file the project starts with: its manifest's `entry`, else the
    /// first of ``entryCandidates`` that is there. Nil when none is.
    public static func entry(of project: URL) -> URL? {
        let fileManager = FileManager.default
        if let entry = manifest(of: project)?.entry, !entry.isEmpty {
            let url = project.appendingPathComponent(entry)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        return entryCandidates
            .map { project.appendingPathComponent($0) }
            .first { fileManager.fileExists(atPath: $0.path) }
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
