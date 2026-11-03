//
//  StudioModel+Project.swift
//  BASICStudio
//
//  The open project through ProjectKit: opening, saving, closing, and the
//  sidebar's file commands (BASIC-72).
//

import ActiveUI
import BASICProjects
import Foundation

/// Studio's project, a folder or a zip, through ProjectKit (BASIC-72; ProjectKit PLAN 10.3).
///
/// ```text
///   Open Project…  ─▶ StudioOpenProject ─▶ adoptProject: the sidebar lists its files,
///   Open Recent        (ProjectKit)        projectDirectoryURL and the working directory
///   launch restore                         are its folder (a zip's working copy)
///
///   Save ─▶ the file ─▶ projectDidSave: a zip is written now
///   a program, the console ─▶ noteProjectChanges: a zip saves shortly
///   New File… New Folder… Rename… Move… Delete… ─▶ ProjectKit ─▶ the sidebar again
/// ```
extension StudioModel {
    // MARK: - Opening and closing

    /// Opens the project at `url` (a folder, a zip, or any folder of programs) as
    /// Studio's project, saving and closing the one before. `countsAsOpened` is false
    /// for the project restored at launch, which leaves the sidebar as it was.
    func openStudioProject(at url: URL, countsAsOpened: Bool) {
        let target = url.standardizedFileURL
        if let open = openedProject, open.url.standardizedFileURL.path == target.path {
            adoptProject(open, countsAsOpened: countsAsOpened)
            return
        }
        closeStudioProject()
        do {
            let project = try StudioOpenProject(at: target) { [weak self] in self?.rescanProject() }
            adoptProject(project, countsAsOpened: countsAsOpened)
            if project.isReadOnly, countsAsOpened {
                showWarning("\u{201C}\(project.displayName)\u{201D} is open in another app.",
                            message: "It opens read-only here: nothing in it can be changed until it is closed there.")
            }
        } catch {
            showWarning("Unable to open \(url.lastPathComponent).", message: "\(error)")
        }
    }

    /// The project last open, reopened at launch, without showing the sidebar.
    func restoreStudioProject(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        openStudioProject(at: url, countsAsOpened: false)
    }

    /// Loads the file the open project runs into the editor: the one `project.json`
    /// names, else `src/main.bas`, `Sources/main.bas` or `main.bas`. A manifest naming
    /// a missing file is reported; a project with nothing to run just opens.
    func loadProjectEntry() {
        guard let project = openedProject else { return }
        switch project.entryPoint {
        case .file(let path):
            let entry = project.root.appendingPathComponent(path)
            do {
                try loadProgram(from: entry)
            } catch {
                showWarning("Unable to load \(entry.lastPathComponent).", message: error.localizedDescription)
            }
        case .missing(let path):
            showWarning("\(project.displayName) has no \(path).",
                        message: "Its project.json says it starts there, but the file isn't in the project.")
        case .none:
            break
        }
    }

    /// Saves and lets go of the open project, if any: a zip is written, and its working
    /// copy released.
    func closeStudioProject() {
        guard let project = openedProject else { return }
        adoptProject(nil, countsAsOpened: false)
        do {
            try project.close()
        } catch {
            showWarning("Unable to save \(project.displayName).", message: "\(error)")
        }
    }

    /// A program loaded on its own (File ▸ Load…, Open Recent, an example that is one
    /// file) closes the open project unless it is one of the project's files, so the
    /// sidebar never lists a project the editor's program isn't in.
    func leaveProject(unlessItHolds url: URL?) {
        guard let project = openedProject else { return }
        if let url, project.contains(url) { return }
        closeStudioProject()
    }

    // MARK: - Saving

    /// After Studio saved `url`: in a zip project, the zip is written now, so Save is
    /// all it takes.
    func projectDidSave(_ url: URL) {
        guard let project = openedProject, project.contains(url) else { return }
        project.noteChanges()
        do {
            try project.save()
        } catch {
            showWarning("Unable to save \(project.displayName).", message: "\(error)")
        }
    }

    /// A program or the console may have changed the project's files: a zip saves
    /// them shortly. Cheap: nothing is read until the save.
    func noteProjectChanges() {
        openedProject?.noteChanges()
    }

    // MARK: - The sidebar's commands

    /// Whether the open project's files can be changed: one is open, and no other app
    /// is editing it.
    var canChangeProjectFiles: Bool {
        guard let project = openedProject else { return false }
        return !project.isReadOnly
    }

    /// Whether something in the project is selected, to rename, move or delete.
    var hasProjectSelection: Bool {
        canChangeProjectFiles && selectedProjectPath != nil
    }

    /// Selects a folder in the sidebar: where New File… and New Folder… put things.
    func selectProjectFolder(_ path: String) {
        projectSelection = path
    }

    /// The selected file or folder, as a path in the project.
    var selectedProjectPath: ProjectPath? {
        guard let selection = projectSelection else { return nil }
        let path = try? ProjectPath(selection)
        return path?.isRoot == true ? nil : path
    }

    /// Where new things go: the selected folder, else the selected file's folder, else
    /// the project's top.
    var projectTargetFolder: ProjectPath {
        guard let path = selectedProjectPath else { return .root }
        return projectSelection?.hasSuffix("/") == true ? path : (path.parent ?? .root)
    }

    /// Project ▸ New File…: a name, then an empty file in the target folder, open in
    /// the editor.
    func newProjectFileFromMenu() {
        Task { @MainActor in await newProjectFile() }
    }

    /// The work of ``newProjectFileFromMenu()``, for a test to await.
    func newProjectFile() async {
        guard let project = openedProject, canChangeProjectFiles else { return }
        let folder = projectTargetFolder
        guard let name = await askProjectName("New File in \(folderTitle(folder, of: project))", initial: "untitled.bas") else { return }
        do {
            let url = try project.newFile(named: name, in: folder)
            rescanProject()
            try loadProgram(from: url)
            projectSelection = project.relativePath(of: url)?.description
        } catch {
            showWarning("Unable to make \(name).", message: "\(error)")
        }
    }

    /// Project ▸ New Folder…: a name, then a folder in the target folder.
    func newProjectFolderFromMenu() {
        Task { @MainActor in await newProjectFolder() }
    }

    /// The work of ``newProjectFolderFromMenu()``, for a test to await.
    func newProjectFolder() async {
        guard let project = openedProject, canChangeProjectFiles else { return }
        let folder = projectTargetFolder
        guard let name = await askProjectName("New Folder in \(folderTitle(folder, of: project))", initial: "untitled folder") else { return }
        do {
            try project.newFolder(named: name, in: folder)
            rescanProject()
            projectSelection = (try? folder.appending(name))?.description.appending("/")
        } catch {
            showWarning("Unable to make \(name).", message: "\(error)")
        }
    }

    /// Project ▸ Rename…: a new name for the selected file or folder; the editor
    /// follows a file it has open.
    func renameProjectItemFromMenu() {
        Task { @MainActor in await renameProjectItem() }
    }

    /// The work of ``renameProjectItemFromMenu()``, for a test to await.
    func renameProjectItem() async {
        guard let project = openedProject, canChangeProjectFiles, let path = selectedProjectPath else { return }
        guard let name = await askProjectName("Rename \(path.name)", initial: path.name), name != path.name else { return }
        do {
            let moved = try project.rename(path, to: name)
            projectItemMoved(from: path, to: moved, in: project)
        } catch {
            showWarning("Unable to rename \(path.name).", message: "\(error)")
        }
    }

    /// Project ▸ Move…: the folder, from the project's top (`src/games`; empty for the
    /// top), to move the selected file or folder into.
    func moveProjectItemFromMenu() {
        Task { @MainActor in await moveProjectItem() }
    }

    /// The work of ``moveProjectItemFromMenu()``, for a test to await.
    func moveProjectItem() async {
        guard let project = openedProject, canChangeProjectFiles, let path = selectedProjectPath else { return }
        guard let answer = await askProjectName("Move \(path.name) Into the Folder", initial: path.parent?.description ?? "",
                                                allowsEmpty: true) else { return }
        do {
            let moved = try project.move(path, into: try ProjectPath(answer))
            projectItemMoved(from: path, to: moved, in: project)
        } catch {
            showWarning("Unable to move \(path.name).", message: "\(error)")
        }
    }

    /// Project ▸ Delete…: the selected file or folder, after asking; the editor clears
    /// if its file goes.
    func deleteProjectItemFromMenu() {
        Task { @MainActor in await deleteProjectItem() }
    }

    /// The work of ``deleteProjectItemFromMenu()``, for a test to await.
    func deleteProjectItem() async {
        guard let project = openedProject, canChangeProjectFiles, let path = selectedProjectPath else { return }
        let title = "Delete \u{201C}\(path.name)\u{201D}?"
        let message = project.isZip
            ? "It leaves the project, and the project's zip, when the project is next saved."
            : "It is moved to the Trash where there is one; otherwise it is deleted."
        let confirmed: Bool
        if let deleteConfirmationAnswer {
            confirmed = deleteConfirmationAnswer(title, message)
        } else {
            confirmed = await AUIAlert.show(title: title, message: message, buttons: [.destructive("Delete"), .cancel()]) == 0
        }
        guard confirmed else { return }
        let url = project.root.appendingPathComponent(path.description)
        do {
            _ = try project.delete(path)
            projectSelection = nil
            programFileDeleted(at: url)
            rescanProject()
        } catch {
            showWarning("Unable to delete \(path.name).", message: "\(error)")
        }
    }

    // MARK: - Helpers

    /// After a rename or move: the sidebar again, the selection on the item where it
    /// went, and the editor's file renamed with it.
    private func projectItemMoved(from old: ProjectPath, to new: ProjectPath, in project: StudioOpenProject) {
        let wasFolder = projectSelection?.hasSuffix("/") == true
        programFileMoved(from: project.root.appendingPathComponent(old.description),
                         to: project.root.appendingPathComponent(new.description))
        rescanProject()
        projectSelection = new.description + (wasFolder ? "/" : "")
    }

    /// "the top" or `src/games`, for a sheet's title.
    private func folderTitle(_ folder: ProjectPath, of project: StudioOpenProject) -> String {
        folder.isRoot ? project.displayName : folder.description
    }

    /// A name from the shell's sheet (or a test); nil when cancelled or left empty.
    private func askProjectName(_ title: String, initial: String, allowsEmpty: Bool = false) async -> String? {
        guard let projectNamePrompter else { return nil }
        guard let answer = await projectNamePrompter(title, initial)?.trimmingCharacters(in: .whitespaces) else { return nil }
        return answer.isEmpty && !allowsEmpty ? nil : answer
    }
}
