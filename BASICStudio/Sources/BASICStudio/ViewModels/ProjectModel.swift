//
//  ProjectModel.swift
//  BASICStudio
//
//  The project sidebar as values: the open project and its files and folders.
//

import BASICRecipes
import Foundation

/// The project sidebar (ACTIVEUI_TRANSITION.md P3.7, BASIC-72): the open project,
/// a folder or a zip, every file and folder in it, and which one is selected.
///
/// A projection like the P1 ones: built from ``StudioModel``, owning nothing,
/// importing no UI framework. The ActiveUI shell draws it in an `AUISidebar`.
///
/// ```text
///   ┌ GradeBook        [+][⊕][⟳] ┐   title, and Open Project… / New File… / Rescan
///   │ ▸ project.json             │   rows: each folder, then what is in it; a
///   │ ▸ src                      │   nested one shows its folder; the selected
///   │ ▸ main.bas      src        │   one (or the editor's file) is highlighted
///   │ ▸ models        src        │
///   └────────────────────────────┘
/// ```
struct ProjectModel: Equatable {
    struct Row: Equatable {
        /// Relative to the project folder, with its extension; a folder's ends in `/`.
        let path: String
        /// The file's or folder's name.
        let title: String
        /// The folder it is in, for one below the top.
        let subtitle: String?

        /// Whether the row is a folder.
        var isFolder: Bool { path.hasSuffix("/") }
    }

    /// The folder's name, or ``noProjectTitle``.
    let title: String
    let isOpen: Bool
    let rows: [Row]
    /// The row for the program in the editor, when it is one of these.
    let selectedIndex: Int?

    static let noProjectTitle = "No Project"
    static let openProjectTitle = "Open Project…"
    /// Folders not worth listing: build output and package checkouts.
    static let skippedFolders: Set<String> = [".build", ".build-claude", "Build", "DerivedData", "node_modules"]

    @MainActor
    init(_ model: StudioModel) {
        self.init(directory: model.projectDirectoryURL, files: model.projectFiles, openFile: model.currentProgramURL,
                  name: model.openedProject?.displayName, selection: model.projectSelection)
    }

    /// The sidebar for the files under `directory`. `name` is the project's (a zip's
    /// working copy has a name of its own); `selection` wins over the editor's file.
    init(directory: URL?, files: [String], openFile: URL?, name: String? = nil, selection: String? = nil) {
        isOpen = directory != nil
        // `MyGame.basproj` is the project MyGame.
        title = name ?? directory.map { BASICProjectFolder.displayName(ofFolder: $0.lastPathComponent) } ?? Self.noProjectTitle
        rows = files.map { path in
            let parts = path.split(separator: "/")
            return Row(
                path: path,
                title: String(parts.last ?? Substring(path)),
                subtitle: parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
            )
        }
        if let selection, let index = files.firstIndex(of: selection) {
            selectedIndex = index
        } else if let directory, let openFile {
            let root = directory.standardizedFileURL.path + "/"
            let open = openFile.standardizedFileURL.path
            selectedIndex = open.hasPrefix(root)
                ? files.firstIndex(of: String(open.dropFirst(root.count)))
                : nil
        } else {
            selectedIndex = nil
        }
    }

    /// The files and folders under `directory`, relative to it, each folder (ending
    /// in `/`) followed by what is in it, by name as Finder sorts. Hidden names and
    /// ``skippedFolders`` are left out.
    static func scan(_ directory: URL) -> [String] {
        let root = directory.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var found: [String] = []
        for case let url as URL in enumerator {
            if skippedFolders.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root.path + "/") else { continue }
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            found.append(String(path.dropFirst(root.path.count + 1)) + (isFolder ? "/" : ""))
        }
        // Component by component, so a folder comes right before what is in it.
        return found.sorted { lhs, rhs in
            let left = lhs.split(separator: "/"), right = rhs.split(separator: "/")
            for (a, b) in zip(left, right) where a != b {
                return String(a).localizedStandardCompare(String(b)) == .orderedAscending
            }
            return left.count < right.count
        }
    }
}
