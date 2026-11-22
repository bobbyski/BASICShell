//
//  StudioOpenProject.swift
//  BASICStudio
//
//  The project Studio has open, a folder or a zip, through ProjectKit.
//

import BASICProjects
import Foundation

/// The project Studio has open (BASIC-72): a `.basproj` folder or a `.basproj` zip,
/// opened with ProjectKit so both behave the same; or, as Open Project… has always
/// allowed, any folder of programs.
///
/// ```text
///   Game.basproj (zip) ──ProjectKit──▶ working copy ◀── root: the sidebar, the editor,
///   Game.basproj/      ─────────────▶ the folder   ◀──       the interpreter, compiles
/// ```
///
/// Everything in Studio that works on files works on ``root``, a real folder: a zip's
/// working copy, or the project's own folder. A zip saves itself: two seconds after a
/// change ProjectKit made or was told about (``noteChanges()``), when Studio saves a
/// file, and when the project closes. A zip another app is editing opens read-only.
@MainActor
final class StudioOpenProject {
    /// The ProjectKit project.
    let project: Project
    private var observation: ProjectObservation?

    /// Where zip projects' working copies go: nil for ProjectKit's own folder in
    /// Application Support. Tests point it at a folder of their own.
    static var workingCopies: URL?

    /// Opens the project at `url`; `onChange` hears that its files changed, on the main
    /// actor, whoever changed them.
    init(at url: URL, onChange: @escaping @MainActor () -> Void) throws {
        let options = ProjectOptions(whenLocked: .openReadOnly, workingCopies: Self.workingCopies)
        project = try Project.open(at: url, as: BASICProjects.typesForOpening, options: options)
        observation = project.observe { _ in
            Task { @MainActor in onChange() }
        }
    }

    /// Where the project is: its folder, or its zip.
    var url: URL { project.url }

    /// The folder its files are in: the folder itself, or a zip's working copy.
    var root: URL { project.workingDirectory.standardizedFileURL }

    /// Whether it is a zip.
    var isZip: Bool { project.form == .zip }

    /// Whether changes are refused: another app is editing the zip.
    var isReadOnly: Bool { project.isReadOnly }

    /// `Game` for `Game.basproj`, as the sidebar and the alerts name it.
    var displayName: String { BASICProjectFolder.displayName(ofFolder: url.lastPathComponent) }

    /// The file it runs, by the rule every BASIC tool shares: found, named in
    /// `project.json` but missing, or none.
    var entryPoint: BASICProjectFolder.EntryPoint {
        BASICProjects.entryPoint(of: project)
    }

    /// Whether `url` is in the project's files.
    func contains(_ url: URL) -> Bool {
        relativePath(of: url) != nil
    }

    /// `url`'s path in the project, or nil when it is outside.
    func relativePath(of url: URL) -> ProjectPath? {
        let path = url.standardizedFileURL.path
        let top = root.path
        if path == top { return .root }
        guard path.hasPrefix(top + "/") else { return nil }
        return try? ProjectPath(String(path.dropFirst(top.count + 1)))
    }

    /// How many files it holds, for the delete warning.
    var fileCount: Int {
        ((try? project.items(recursive: true)) ?? []).filter { $0.kind == .file }.count
    }

    // MARK: - Changes

    /// Tells the project its files changed outside ProjectKit (a program wrote, Studio
    /// saved a file), so a zip saves them.
    func noteChanges() {
        guard !isReadOnly else { return }
        try? project.noteChanges()
    }

    /// Writes every change into the zip now; a folder has nothing pending.
    func save() throws {
        guard !isReadOnly else { return }
        try project.save()
    }

    /// Saves and lets go: a zip's working copy and lock are released.
    func close() throws {
        observation?.cancel()
        try project.close()
    }

    // MARK: - The sidebar's commands

    /// Makes an empty file `name` in `folder`; returns it.
    func newFile(named name: String, in folder: ProjectPath) throws -> URL {
        let path = try folder.appending(name)
        try project.write(path, text: "")
        return root.appendingPathComponent(path.description)
    }

    /// Makes the folder `name` in `folder`.
    func newFolder(named name: String, in folder: ProjectPath) throws {
        try project.createFolder(try folder.appending(name))
    }

    /// Renames the item at `path` to `name` in its own folder; returns its new path.
    func rename(_ path: ProjectPath, to name: String) throws -> ProjectPath {
        let destination = try (path.parent ?? .root).appending(name)
        try project.move(path, to: destination)
        return destination
    }

    /// Moves the item at `path` into `folder`; returns its new path.
    func move(_ path: ProjectPath, into folder: ProjectPath) throws -> ProjectPath {
        let destination = try folder.appending(path.name)
        try project.move(path, to: destination)
        return destination
    }

    /// Deletes the item at `path`: to the Trash where there is one; returns whether it
    /// went there.
    func delete(_ path: ProjectPath) throws -> Bool {
        try project.delete(path)
    }
}
