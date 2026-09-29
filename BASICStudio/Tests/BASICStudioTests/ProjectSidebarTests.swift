//
//  ProjectSidebarTests.swift
//  BASICStudioTests
//
//  P3.7: the project sidebar. Open a folder; pick its programs from a list.
//

import ActiveUI
import Foundation
import Testing
@testable import BASICStudio

@Suite("Project sidebar", .serialized)
@MainActor
struct ProjectSidebarTests {
    /// A folder with programs at the top and below, and things not to list.
    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("studio-project-\(UUID().uuidString)")
        let files = [
            "hello.bas": "PRINT \"HELLO\"",
            "Zeta.bas": "PRINT 26",
            "games/roids.bas": "PRINT \"ROIDS\"",
            "games/pong.BAS": "PRINT \"PONG\"",
            "notes.txt": "not a program",
            ".hidden.bas": "PRINT 0",
            ".build/debug/generated.bas": "PRINT 0",
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("The scan lists .bas files, top level first, in Finder order, skipping hidden files and build output")
    func scan() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ProjectModel.scan(root) == ["hello.bas", "Zeta.bas", "games/pong.BAS", "games/roids.bas"])
    }

    @Test("Rows show the file's name, and its folder when nested; the open program is selected")
    func projection() {
        let root = URL(fileURLWithPath: "/tmp/Samples")
        let files = ["hello.bas", "games/roids.bas"]
        let none = ProjectModel(directory: nil, files: [], openFile: nil)
        #expect(!none.isOpen && none.title == ProjectModel.noProjectTitle && none.rows.isEmpty)
        let project = ProjectModel(directory: root, files: files, openFile: root.appendingPathComponent("games/roids.bas"))
        #expect(project.title == "Samples")
        #expect(project.rows.map(\.title) == ["hello.bas", "roids.bas"])
        #expect(project.rows.map(\.subtitle) == [nil, "games"])
        #expect(project.selectedIndex == 1)
        let elsewhere = ProjectModel(directory: root, files: files, openFile: URL(fileURLWithPath: "/tmp/other.bas"))
        #expect(elsewhere.selectedIndex == nil)
    }

    @Test("Opening a project lists it and makes it the working directory; picking a file loads it")
    func openAndPick() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StudioHarness().model
        model.openProject(at: root)
        #expect(model.projectDirectoryURL == root.standardizedFileURL)
        #expect(model.projectFiles.count == 4)
        model.openProjectFile("games/roids.bas")
        #expect(model.programText == "PRINT \"ROIDS\"")
        #expect(model.selectedPane == .editor)
        #expect(ProjectModel(model).selectedIndex == 3)

        try "PRINT 1".write(to: root.appendingPathComponent("new.bas"), atomically: true, encoding: .utf8)
        model.rescanProject()
        #expect(model.projectFiles.contains("new.bas"))
    }

    @Test("P3.7 · The ActiveUI window's root is a real sidebar: its rows are the project, a pick loads the file")
    func shellSidebar() async throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = StudioActiveUIShell(model: StudioHarness().model)
        #expect(studio.root === studio.sidebar)
        #expect(studio.sidebar.items.isEmpty && studio.sidebar.headerTitle == ProjectModel.noProjectTitle)

        studio.model.openProject(at: root)
        studio.refresh()
        #expect(studio.sidebar.headerTitle == root.lastPathComponent)
        #expect(studio.sidebar.items.map(\.title) == ["hello.bas", "Zeta.bas", "pong.BAS", "roids.bas"])
        #expect(studio.sidebar.items.map(\.subtitle) == [nil, nil, "games", "games"])

        studio.sidebar.onSelect?(0)
        studio.refresh()
        #expect(studio.model.programText == "PRINT \"HELLO\"")
        // The native list holds a selection only in a window; what the
        // shell asked it to select is the projection's.
        #expect(studio.drawnProject?.selectedIndex == 0)
        #expect(studio.sidebar.headerActions.map(\.tooltip) == [ProjectModel.openProjectTitle, "Rescan the project"])
    }

    @Test("P3.7 · View ▸ Toggle Sidebar collapses it")
    func toggle() {
        let studio = StudioActiveUIShell(model: StudioHarness().model)
        let before = studio.sidebar.isSidebarCollapsed
        studio.sidebar.toggleSidebar()
        #expect(studio.sidebar.isSidebarCollapsed != before)
    }
}
