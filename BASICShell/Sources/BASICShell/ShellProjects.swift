import BASICCore
import BASICProjects
import Foundation

/// The project the shell has open (BASIC-72): `basicshell Game.basproj`, or
/// `LOAD "Game.basproj"` / `RUN "Game.basproj"` at the prompt, a folder or a zip.
///
/// ```text
///   basicshell Game.basproj ─▶ open with ProjectKit ─▶ cd into its folder (a zip's
///                              working copy) ─▶ run its entry ─▶ at exit, save and close
/// ```
///
/// The program runs in the project's folder, so it reads `Resources/data.csv` from the
/// project's top, as BASPROJ_AND_BASLIB.md says. What it writes there is noted, and a
/// zip saves it: shortly after, and when the shell lets the project go. If another app
/// is editing the zip, the shell opens it read-only and what the program writes is not
/// kept. The interpreter is untouched: the shell's file host does all of this.
final class ShellProjects {
    /// The open project, if any.
    private(set) var current: Project?

    /// Whether `path` names a BASIC project to run, in either form: a `.basproj` file or
    /// any folder recognized as one. A `.bas` file is never asked about.
    static func isProject(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue || url.pathExtension.lowercased() == BASICProjectFolder.fileExtension else {
            return false
        }
        return BASICProjects.isRunnableProject(url)
    }

    /// Opens the project at `path` (saving and closing the one before), moves into its
    /// folder, and returns its entry program, under the entry's own path so `IMPORT`
    /// resolves beside it.
    func open(_ path: String) throws -> BASICProgramFile {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if current?.url.standardizedFileURL.path != url.path {
            try closeCurrent()
            current = try Project.open(at: url, as: BASICProjects.types, options: ProjectOptions(whenLocked: .openReadOnly))
        }
        guard let project = current else { throw BASICError.runtime("\(path) could not be opened") }
        let root = project.workingDirectory
        guard FileManager.default.changeCurrentDirectoryPath(root.path) else {
            throw BASICError.runtime("Could not change directory to \(root.path)")
        }
        let entry: ProjectPath
        do {
            entry = try BASICProjects.entry(of: project)
        } catch {
            throw BASICError.runtime("\(error)")
        }
        let file = root.appendingPathComponent(entry.description).path
        return BASICProgramFile(text: try String(contentsOfFile: file, encoding: .utf8), fileName: file)
    }

    /// Whether the open project is read-only: another app is editing it.
    var isReadOnly: Bool {
        current?.isReadOnly ?? false
    }

    /// Notes that the program changed what is at `path`, so a zip project saves it.
    /// Paths outside the open project are none of its business.
    func noteWrite(at path: String) {
        guard let project = current, !project.isReadOnly else { return }
        let written = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = project.workingDirectory.standardizedFileURL.path
        guard written == root || written.hasPrefix(root + "/") else { return }
        try? project.noteChanges()
    }

    /// Saves and lets go of the open project.
    func closeCurrent() throws {
        defer { current = nil }
        try current?.close()
    }
}
