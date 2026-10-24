//
//  BASICProjects.swift
//  BASICProjects
//
//  BASIC's project types, and recognizing a project in either form.
//

import Foundation
@_exported import ProjectKit
@_exported import BASICRecipes

extension ProjectType {
    /// A BASIC project: `Game.basproj`, a folder or a zip, marked by `project.json`. New
    /// projects are zips (ProjectKit PLAN D7); a folder with a `project.json` and no
    /// extension is a project too (D13).
    public static let basicProject = ProjectType(
        identifier: "com.aibasic.basproj", name: "BASIC Project",
        extension: BASICProjectFolder.fileExtension, defaultForm: .zip, marker: BASICProjectFolder.manifestName,
        neverZipped: ["Build/", ".build/", ".basstate/"])

    /// A BASIC library: `Charts.baslib`, a folder or a zip, marked by `library.json`.
    public static let basicLibrary = ProjectType(
        identifier: "com.aibasic.baslib", name: "BASIC Library",
        extension: "baslib", defaultForm: .zip, marker: "library.json",
        neverZipped: ["Build/", ".build/"])

    /// Any folder of BASIC programs, opened as a project with no manifest: what
    /// BASICStudio's Open Project… has always allowed (BASPROJ_AND_BASLIB.md §8). It
    /// has no marker, so it takes any folder; recognition tries it last.
    public static let basicFolder = ProjectType(
        identifier: "com.aibasic.folder", name: "Folder of BASIC programs",
        extension: "basfolder", defaultForm: .folder,
        neverZipped: ["Build/", ".build/", ".basstate/"])
}

/// BASIC's projects over ProjectKit: what a project is, which file it runs, and
/// making one.
///
/// ```text
///   Game.basproj/          a folder: git sees each file
///   Game.basproj           a zip: one file to mail, sync or keep on an iPad
///     project.json         { "schemaVersion": 1, "kind": "project", "entry": "src/main.bas" }
///     src/main.bas
/// ```
///
/// Tools open either form with ProjectKit (`Project.open(at:as: BASICProjects.types)`),
/// and run what ``entryPoint(of:)`` finds, by `BASICProjectFolder`'s one rule.
public enum BASICProjects {
    /// BASIC's project types, in the order recognition tries them.
    public static let types: [ProjectType] = [.basicProject, .basicLibrary]

    /// What an IDE opens: BASIC's projects and libraries, then any other folder of
    /// programs (``ProjectType/basicFolder``).
    public static let typesForOpening: [ProjectType] = types + [.basicFolder]

    /// What is at `url`: a BASIC project or library, and in which form.
    ///
    /// - Throws: `ProjectError.notAProject` saying what was looked for.
    public static func recognize(_ url: URL) throws -> RecognizedProject {
        try ProjectRecognition.recognize(url, as: types)
    }

    /// Whether `url` is a BASIC project or library, in either form.
    public static func isProject(_ url: URL) -> Bool {
        ProjectRecognition.isProject(url, as: types)
    }

    /// Whether `url` is a BASIC project (not a library), in either form.
    public static func isRunnableProject(_ url: URL) -> Bool {
        (try? recognize(url))?.type == .basicProject
    }

    // MARK: - The entry point

    /// The project's manifest, or nil when it has none or it isn't valid JSON.
    public static func manifest(of project: some ProjectReading) -> BASICProjectFolder.Manifest? {
        guard let data = try? project.data(at: BASICProjectFolder.manifestName) else { return nil }
        return try? JSONDecoder().decode(BASICProjectFolder.Manifest.self, from: data)
    }

    /// Which file the project runs, by `BASICProjectFolder`'s rule, read through the
    /// project: a folder, a zip in place, or a working copy alike.
    public static func entryPoint(of project: some ProjectReading) -> BASICProjectFolder.EntryPoint {
        BASICProjectFolder.entryPoint(manifest: manifest(of: project)) { path in
            ((try? project.item(at: path))?.kind ?? .folder) != .folder
        }
    }

    /// The file the project runs, by its path in the project.
    ///
    /// - Throws: ``EntryProblem`` saying what is wrong: the manifest names a file
    ///   that isn't there, or there is nothing to run.
    public static func entry(of project: some ProjectReading) throws -> ProjectPath {
        switch entryPoint(of: project) {
        case .file(let path):
            return try ProjectPath(path)
        case .missing(let path):
            throw EntryProblem("\(project.url.lastPathComponent)'s project.json says it starts in \(path), which isn't there")
        case .none:
            let candidates = BASICProjectFolder.entryCandidates.joined(separator: ", ")
            throw EntryProblem("\(project.url.lastPathComponent) has no entry in project.json, and none of \(candidates)")
        }
    }

    /// Why a project has no file to run.
    public struct EntryProblem: Error, CustomStringConvertible, Equatable {
        public let description: String

        public init(_ description: String) {
            self.description = description
        }
    }
}
