//
//  OpenRecentTests.swift
//  BASICStudioTests
//
//  File ▸ Open Recent: what goes on the list, what does not (a file picked
//  in the project sidebar), how the menu names them, and opening one.
//

import BASICRecipes
import Foundation
import Testing
@testable import BASICStudio

@Suite("Open Recent", .serialized)
@MainActor
struct OpenRecentTests {
    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("studio-recent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.standardizedFileURL
    }

    /// `name.basproj` with a `main.bas`, in `folder`.
    private func project(_ name: String, in folder: URL) throws -> URL {
        let project = folder.appendingPathComponent("\(name).basproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "PRINT \"\(name)\"\n".write(to: project.appendingPathComponent("main.bas"), atomically: true, encoding: .utf8)
        try "PRINT \"other\"\n".write(to: project.appendingPathComponent("other.bas"), atomically: true, encoding: .utf8)
        return project
    }

    private func file(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try "PRINT \"\(name)\"\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - The list

    @Test("Newest first, each once, at most ten of each")
    func list() {
        var recent = StudioRecentItems()
        let a = URL(fileURLWithPath: "/tmp/a.bas")
        let b = URL(fileURLWithPath: "/tmp/b.bas")
        recent.note(a, as: .file)
        recent.note(b, as: .file)
        recent.note(a, as: .file)
        #expect(recent.files == [a, b])
        #expect(recent.projects.isEmpty)

        for index in 0..<12 {
            recent.note(URL(fileURLWithPath: "/tmp/p\(index).basproj"), as: .project)
        }
        #expect(recent.projects.count == StudioRecentItems.limit)
        #expect(recent.projects.first?.lastPathComponent == "p11.basproj")

        recent.clear()
        #expect(recent.isEmpty)
    }

    @Test("Saved under the home folder with ~, so it survives the app's folder moving")
    func savedPaths() throws {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let inside = home.appendingPathComponent("Documents/Game.basproj")
        #expect(StudioRecentItems.savedPath(for: inside) == "~/Documents/Game.basproj")
        #expect(StudioRecentItems.url(fromSaved: "~/Documents/Game.basproj") == inside.standardizedFileURL)

        var recent = StudioRecentItems()
        recent.note(inside, as: .project)
        let decoded = try JSONDecoder().decode(StudioRecentItems.self, from: JSONEncoder().encode(recent))
        #expect(decoded == recent)
        #expect(decoded.projects == [inside.standardizedFileURL])
    }

    @Test("The menu names a project without .basproj, and says where when two names match")
    func titles() {
        let projects = [URL(fileURLWithPath: "/u/Games/Rocks.basproj"), URL(fileURLWithPath: "/u/Old/Rocks.basproj"), URL(fileURLWithPath: "/u/Quiz.basproj")]
        #expect(StudioRecentItems.titles(for: projects, kind: .project) == ["Rocks — Games", "Rocks — Old", "Quiz"])

        let files = [
            URL(fileURLWithPath: "/u/Rocks.basproj/src/main.bas"),
            URL(fileURLWithPath: "/u/Quiz.basproj/main.bas"),
            URL(fileURLWithPath: "/u/hello.bas"),
        ]
        #expect(StudioRecentItems.titles(for: files, kind: .file) == ["main.bas — Rocks", "main.bas — Quiz", "hello.bas"])
    }

    // MARK: - What goes on it

    @Test("Load…, New, Save As… and Open Project… go on the list")
    func menuOpens() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudioHarness().model
        let hello = try file("hello.bas", in: folder)
        let game = try project("Game", in: folder)

        model.fileRequestAnswer = { _ in hello }
        model.loadProgramFromMenu()
        model.fileRequestAnswer = { _ in game }
        model.openProjectFromMenu()
        let copy = folder.appendingPathComponent("copy.bas")
        model.fileRequestAnswer = { _ in copy }
        model.saveProgramAsFromMenu()
        let fresh = folder.appendingPathComponent("fresh.bas")
        model.fileRequestAnswer = { _ in fresh }
        model.newProgramFromMenu()

        #expect(model.recentItems.projects == [game.standardizedFileURL])
        #expect(model.recentItems.files == [fresh, copy, hello].map(\.standardizedFileURL))
    }

    @Test("A file picked in the project sidebar does not go on the list")
    func sidebarDoesNotCount() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudioHarness().model
        let game = try project("Game", in: folder)
        model.fileRequestAnswer = { _ in game }
        model.openProjectFromMenu()

        model.openProjectFile("other.bas")
        #expect(model.currentProgramURL?.lastPathComponent == "other.bas")
        #expect(model.recentItems.files.isEmpty)
        #expect(model.recentItems.projects == [game.standardizedFileURL])
    }

    @Test("A project made by New Project goes on the list")
    func newProjectCounts() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudioHarness().model
        var wizard = NewProjectWizardModel(recipes: BASICRecipes.builtIn, location: folder, canChooseLocation: true)
        wizard.next()
        wizard.name = "Made"
        let made = try model.createProject(from: wizard)
        #expect(model.recentItems.projects == [made.standardizedFileURL])
    }

    // MARK: - The menu

    @Test("The menu lists projects, then files, then Clear Menu; gone ones are left out")
    func menu() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudioHarness().model
        #expect(MenuCommandModel.recentEntries(model) == [.placeholder("No Recent Items")])

        let game = try project("Game", in: folder)
        let hello = try file("hello.bas", in: folder)
        let gone = try file("gone.bas", in: folder)
        model.noteRecent(game, as: .project)
        model.noteRecent(gone, as: .file)
        model.noteRecent(hello, as: .file)
        try FileManager.default.removeItem(at: gone)

        let entries = MenuCommandModel.recentEntries(model)
        let titles = entries.map { entry -> String in
            switch entry {
            case .heading(let text): return "# " + text
            case .item(let item): return item.title
            case .separator: return "---"
            case .placeholder(let text): return "(\(text))"
            case .submenu(let title, _): return title + " ▸"
            }
        }
        #expect(titles == ["# Projects", "Game", "# Files", "hello.bas", "---", "Clear Menu"])

        guard case .item(let clear) = entries.last else {
            Issue.record("no Clear Menu")
            return
        }
        MenuCommandModel.perform(clear.action, on: model)
        #expect(model.recentItems.isEmpty)
    }

    @Test("Choosing one opens it as Open Project… or Load… would, and puts it first")
    func opening() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudioHarness().model
        let game = try project("Game", in: folder)
        let quiz = try project("Quiz", in: folder)
        let hello = try file("hello.bas", in: folder)
        model.noteRecent(game, as: .project)
        model.noteRecent(quiz, as: .project)
        model.noteRecent(hello, as: .file)

        MenuCommandModel.perform(.openRecent(.project, game.standardizedFileURL), on: model)
        #expect(model.projectDirectoryURL == game.standardizedFileURL)
        #expect(model.currentProgramURL?.lastPathComponent == "main.bas")
        #expect(model.recentItems.projects.first == game.standardizedFileURL)

        MenuCommandModel.perform(.openRecent(.file, hello.standardizedFileURL), on: model)
        #expect(model.programText == "PRINT \"hello.bas\"\n")
    }

    @Test("One gone since the menu was drawn comes off the list")
    func goneWhenChosen() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudioHarness().model
        let hello = try file("hello.bas", in: folder)
        model.noteRecent(hello, as: .file)
        try FileManager.default.removeItem(at: hello)
        var warnings: [String] = []
        model.warningPresenter = { title, _ in warnings.append(title) }

        model.openRecent(hello, as: .file)
        #expect(model.recentItems.files.isEmpty)
        #expect(warnings == ["hello.bas is no longer there."])
    }
}

@Suite("Where Load and Open Project open", .serialized)
@MainActor
struct OpenPanelStartTests {
    @Test("Before anything is opened: the iCloud Drive folder, else Documents")
    func firstTime() {
        let model = StudioHarness().model
        var asked: [URL?] = []
        model.fileRequestAnswer = { asked.append($0.directory); return nil }
        model.openProjectFromMenu()
        model.loadProgramFromMenu()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.standardizedFileURL
        #expect(asked == [documents, documents])
    }

    @Test("After that: the folder the last project or file came from")
    func whereTheLastCameFrom() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("studio-panel-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        let games = folder.appendingPathComponent("Games", isDirectory: true)
        let project = games.appendingPathComponent("Rocks.basproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "PRINT 1\n".write(to: project.appendingPathComponent("main.bas"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: folder) }

        let model = StudioHarness().model
        model.fileRequestAnswer = { _ in project }
        model.openProjectFromMenu()

        var asked: [URL?] = []
        model.fileRequestAnswer = { asked.append($0.directory); return nil }
        model.loadProgramFromMenu()
        model.openProjectFromMenu()
        #expect(asked == [games, games])

        // Saved with the settings, and back after a restart.
        let saved = try JSONDecoder().decode(StudioRecentItems.self, from: JSONEncoder().encode(model.recentItems))
        #expect(saved.lastFolder == games)

        // Gone since: back to Documents rather than a folder that is not there.
        try FileManager.default.removeItem(at: folder)
        asked = []
        model.openProjectFromMenu()
        #expect(asked.first != games)
    }
}
