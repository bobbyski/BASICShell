//
//  DeleteProjectTests.swift
//  BASICStudioTests
//
//  File ▸ Delete Project…: it asks first, says what goes, and closes what
//  it deleted.
//

import Foundation
import Testing
@testable import BASICStudio

@Suite("Delete Project", .serialized)
@MainActor
struct DeleteProjectTests {
    private func project(_ name: String) throws -> (folder: URL, project: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("studio-delete-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        let project = folder.appendingPathComponent("\(name).basproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "PRINT 1\n".write(to: project.appendingPathComponent("src/main.bas"), atomically: true, encoding: .utf8)
        try "PRINT 2\n".write(to: project.appendingPathComponent("src/other.bas"), atomically: true, encoding: .utf8)
        try "{}".write(to: project.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        return (folder, project)
    }

    @Test("It asks first, naming the project, its folder and how many files go")
    func asksFirst() throws {
        let (folder, project) = try project("Rocks")
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudioHarness().model
        model.openProjectAndEntry(at: project)
        var asked: [(String, String)] = []
        model.deleteConfirmationAnswer = { asked.append(($0, $1)); return false }

        model.deleteProjectFromMenu()
        #expect(asked.count == 1)
        #expect(asked.first?.0 == "Delete \u{201C}Rocks\u{201D}?")
        #expect(asked.first?.1.contains("Rocks.basproj") == true)
        #expect(asked.first?.1.contains("3 files") == true)
        // No is no: everything is where it was.
        #expect(FileManager.default.fileExists(atPath: project.path))
        #expect(model.projectDirectoryURL == project)
    }

    @Test("Yes deletes it and closes it: sidebar, editor and Open Recent")
    func deletes() throws {
        let (folder, project) = try project("Rocks")
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudioHarness().model
        model.openProjectAndEntry(at: project)
        model.noteRecent(project, as: .project)
        model.noteRecent(project.appendingPathComponent("src/other.bas"), as: .file)
        #expect(model.currentProgramURL?.lastPathComponent == "main.bas")
        model.deleteConfirmationAnswer = { _, _ in true }

        model.deleteProjectFromMenu()
        #expect(!FileManager.default.fileExists(atPath: project.path))
        #expect(model.projectDirectoryURL == nil)
        #expect(model.projectFiles.isEmpty)
        #expect(model.currentProgramURL == nil)
        #expect(model.programText.isEmpty)
        #expect(model.recentItems.isEmpty)
        #expect(!model.canDeleteProject)
    }

    @Test("Nothing to delete with no project open")
    func noProject() {
        let model = StudioHarness().model
        var asked = false
        model.deleteConfirmationAnswer = { _, _ in asked = true; return true }
        model.deleteProjectFromMenu()
        #expect(!asked)
        #expect(!model.canDeleteProject)
    }
}
