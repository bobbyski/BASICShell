//
//  RecentItems.swift
//  BASICStudio
//
//  File ▸ Open Recent: the projects and files opened lately. No UI framework
//  here; StudioModel keeps one and saves it with the settings, and
//  MenuCommandModel turns it into the menu.
//

import BASICRecipes
import Foundation

/// The projects and files opened lately, newest first, at most ``limit``
/// of each.
///
/// What counts as opening one is the user's choice of it: File ▸ Load…,
/// New, Save As…, Open Project…, New Project, an example project, and Open
/// Recent itself. A file picked in the project sidebar is not: it is a move
/// inside a project already counted, and would push everything else out.
///
/// ```text
///   File ▸ Open Recent ▸   Projects
///                            MyGame
///                            contacts
///                          Files
///                            main.bas — MyGame       (two main.bas: each says
///                            main.bas — contacts      which project it is in)
///                            hello.bas
///                          ─────
///                          Clear Menu
/// ```
struct StudioRecentItems: Codable, Equatable {
    static let limit = 10

    enum Kind: String, Codable, Equatable {
        case project
        case file
    }

    /// Paths as saved: under the home folder they start with `~`, so a list
    /// saved on iPhone or iPad still finds its files when the app's folder
    /// moves, as it does when the app is updated.
    private(set) var projectPaths: [String] = []
    private(set) var filePaths: [String] = []
    /// The folder the last project or file came from, where Load… and Open
    /// Project… open next. Saved the same way as the lists.
    private(set) var lastFolderPath: String?

    init() {}

    /// The projects, newest first, as they are now on disk.
    var projects: [URL] { projectPaths.map(Self.url(fromSaved:)) }
    /// The files, newest first.
    var files: [URL] { filePaths.map(Self.url(fromSaved:)) }

    var isEmpty: Bool { projectPaths.isEmpty && filePaths.isEmpty }

    /// The folder the last project or file came from, if there has been one.
    var lastFolder: URL? { lastFolderPath.map(Self.url(fromSaved:)) }

    /// Puts `url` first in its list, taking it out of where it was, and
    /// drops the oldest past ``limit``.
    mutating func note(_ url: URL, as kind: Kind) {
        let saved = Self.savedPath(for: url)
        switch kind {
        case .project: Self.putFirst(saved, in: &projectPaths)
        case .file: Self.putFirst(saved, in: &filePaths)
        }
        lastFolderPath = Self.savedPath(for: url.standardizedFileURL.deletingLastPathComponent())
    }

    /// Takes `url` out of its list: it was not there when it was chosen.
    mutating func remove(_ url: URL, as kind: Kind) {
        let saved = Self.savedPath(for: url)
        switch kind {
        case .project: projectPaths.removeAll { $0 == saved }
        case .file: filePaths.removeAll { $0 == saved }
        }
    }

    mutating func clear() {
        projectPaths = []
        filePaths = []
        lastFolderPath = nil
    }

    private static func putFirst(_ path: String, in paths: inout [String]) {
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > limit {
            paths.removeLast(paths.count - limit)
        }
    }

    // MARK: - Saved paths

    static func savedPath(for url: URL) -> String {
        (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
    }

    static func url(fromSaved path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    // MARK: - Names in the menu

    /// What the menu calls each of `urls`: a project by its name without
    /// `.basproj`, a file by its file name. Where two would read the same,
    /// each also says where it is: the project it is in, else its folder.
    static func titles(for urls: [URL], kind: Kind) -> [String] {
        let names = urls.map { name(of: $0, kind: kind) }
        return zip(urls, names).map { url, name in
            names.filter { $0 == name }.count > 1 ? "\(name) — \(place(of: url))" : name
        }
    }

    static func name(of url: URL, kind: Kind) -> String {
        switch kind {
        case .project: return BASICProjectFolder.displayName(ofFolder: url.lastPathComponent)
        case .file: return url.lastPathComponent
        }
    }

    /// The project a file is in, by name, else the folder it is in.
    private static func place(of url: URL) -> String {
        var folder = url.deletingLastPathComponent()
        while folder.path != "/" && !folder.path.isEmpty {
            if folder.pathExtension == BASICProjectFolder.fileExtension {
                return BASICProjectFolder.displayName(ofFolder: folder.lastPathComponent)
            }
            folder = folder.deletingLastPathComponent()
        }
        return url.deletingLastPathComponent().lastPathComponent
    }
}
