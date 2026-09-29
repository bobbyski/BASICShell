//
//  ProjectModel.swift
//  BASICStudio
//
//  The project sidebar as values: the open folder and its programs.
//

import Foundation

/// The project sidebar (ACTIVEUI_TRANSITION.md P3.7): the folder that is open
/// as a project, the BASIC programs in it, and which one is in the editor.
///
/// A projection like the P1 ones: built from ``StudioModel``, owning nothing,
/// importing no UI framework. The ActiveUI shell draws it in an `AUISidebar`.
/// The SwiftUI shell does not show it: it is the reference, and gets no new
/// features (§11.2).
///
/// ```text
///   ┌ Samples            [+][⟳] ┐   title, and Open Project… / Rescan
///   │ ▸ hello.bas               │   rows: file name, and its folder when
///   │ ▸ sound.bas               │   nested; the open one is selected
///   │ ▸ roids.bas     roids     │
///   └───────────────────────────┘
/// ```
struct ProjectModel: Equatable {
    struct Row: Equatable {
        /// Relative to the project folder, with its extension.
        let path: String
        /// The file's name.
        let title: String
        /// The folder it is in, for a file below the top.
        let subtitle: String?
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
        self.init(directory: model.projectDirectoryURL, files: model.projectFiles, openFile: model.currentProgramURL)
    }

    init(directory: URL?, files: [String], openFile: URL?) {
        isOpen = directory != nil
        title = directory?.lastPathComponent ?? Self.noProjectTitle
        rows = files.map { path in
            let parts = path.split(separator: "/")
            return Row(
                path: path,
                title: String(parts.last ?? Substring(path)),
                subtitle: parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
            )
        }
        if let directory, let openFile {
            let root = directory.standardizedFileURL.path + "/"
            let open = openFile.standardizedFileURL.path
            selectedIndex = open.hasPrefix(root)
                ? files.firstIndex(of: String(open.dropFirst(root.count)))
                : nil
        } else {
            selectedIndex = nil
        }
    }

    /// The `.bas` files under `directory`, relative to it, in Finder order:
    /// top-level files first by name, then each folder's. Hidden files and
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
            guard url.pathExtension.lowercased() == "bas" else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root.path + "/") else { continue }
            found.append(String(path.dropFirst(root.path.count + 1)))
        }
        return found.sorted { lhs, rhs in
            let lhsDepth = lhs.split(separator: "/").count
            let rhsDepth = rhs.split(separator: "/").count
            if (lhsDepth == 1) != (rhsDepth == 1) { return lhsDepth == 1 }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}
