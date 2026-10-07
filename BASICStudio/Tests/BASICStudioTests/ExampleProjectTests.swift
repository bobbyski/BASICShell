//
//  ExampleProjectTests.swift
//  BASICStudioTests
//
//  An example that is a project (`apps/contacts.basproj`) opens as a
//  project, on a copy Studio can change (BASIC-24).
//

import ActiveUI
import Foundation
import Testing
@testable import BASICStudio

@Suite("Example projects", .serialized)
@MainActor
struct ExampleProjectTests {
    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("studio-examples-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("Contacts opens as a project: copied, listed in the sidebar, its main.bas in the editor")
    func opensAsProject() throws {
        let examples = try scratch()
        defer { try? FileManager.default.removeItem(at: examples) }
        let model = StudioHarness().model
        model.examplesFolderOverride = examples
        let contacts = try #require(model.bundledExamples.first { $0.projectFolder == "apps/contacts.basproj" })
        #expect(contacts.title == "Contacts")

        model.loadBundledExample(contacts)
        let copy = examples.appendingPathComponent("contacts.basproj")
        #expect(model.projectDirectoryURL == copy.standardizedFileURL)
        #expect(model.currentProgramURL == copy.appendingPathComponent("main.bas"))
        #expect(model.projectFiles.contains("ContactModel.bas"))
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("project.json").path))
        #expect(ProjectModel(model).title == "contacts")
    }

    @Test("Opened again, the copy is opened as it is, never written over")
    func keepsChanges() throws {
        let examples = try scratch()
        defer { try? FileManager.default.removeItem(at: examples) }
        let model = StudioHarness().model
        model.examplesFolderOverride = examples
        let pos = try #require(model.bundledExamples.first { $0.projectFolder == "apps/POS.basproj" })
        model.loadBundledExample(pos)
        let entry = examples.appendingPathComponent("POS.basproj/pos.bas")
        #expect(model.currentProgramURL == entry)
        try "PRINT \"mine\"\n".write(to: entry, atomically: true, encoding: .utf8)

        model.loadBundledExample(pos)
        #expect(model.programText == "PRINT \"mine\"\n")
    }

    @Test("What building left behind is not copied")
    func leavesBuildOutput() throws {
        let source = try scratch()
        let copy = try scratch().appendingPathComponent("Copy.basproj")
        defer { try? FileManager.default.removeItem(at: source) }
        let files = ["main.bas": "PRINT 1", "lib/part.bas": "", "project.json": "{}", "gallery.build/main.o": "", "Build/out": ""]
        for (path, text) in files {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let program = source.appendingPathComponent("gallery")
        try "binary".write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)

        try StudioModel.copyExampleProject(from: source, to: copy)
        let copied = FileManager.default.subpaths(atPath: copy.path)?.filter { !$0.hasSuffix("lib") }.sorted()
        #expect(copied == ["lib/part.bas", "main.bas", "project.json"])
    }

    @Test("A project opened on purpose shows the sidebar; one restored at launch does not")
    func sidebarShows() throws {
        let examples = try scratch()
        defer { try? FileManager.default.removeItem(at: examples) }
        let model = StudioHarness().model
        model.examplesFolderOverride = examples
        let studio = StudioActiveUIShell(model: model)
        studio.refresh()
        #expect(studio.sidebar.isSidebarCollapsed)
        let gallery = try #require(model.bundledExamples.first { $0.projectFolder == "tui/gallery.basproj" })
        model.loadBundledExample(gallery)
        studio.refresh()
        #expect(!studio.sidebar.isSidebarCollapsed)
        #expect(studio.sidebar.headerTitle == "gallery")
    }

    @Test("A project's programs run in the project's folder, wherever their source sits; a file outside it runs in its own")
    func projectIsTheWorkingDirectory() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Kit.basproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try #"{"schemaVersion": 1, "kind": "project", "name": "Kit", "entry": "src/main.bas"}"#
            .write(to: project.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        try "PRINT PWD$\n".write(to: project.appendingPathComponent("src/main.bas"), atomically: true, encoding: .utf8)
        let loose = root.appendingPathComponent("loose.bas")
        try "PRINT 1\n".write(to: loose, atomically: true, encoding: .utf8)

        let model = StudioHarness().model
        model.openProjectAndEntry(at: project)
        #expect(model.currentProgramURL == project.appendingPathComponent("src/main.bas"))
        #expect(try model.currentDirectoryPath() == project.standardizedFileURL.path)
        try model.loadProgram(from: loose)
        #expect(try model.currentDirectoryPath() == root.standardizedFileURL.path)

        // Loaded on its own, with no project open, a project's file still
        // runs in its project's folder.
        let fresh = StudioHarness().model
        try fresh.loadProgram(from: project.appendingPathComponent("src/main.bas"))
        #expect(try fresh.currentDirectoryPath() == project.standardizedFileURL.path)
    }

    @Test("LOAD at the prompt: a project's program moves to its project's folder; any other file leaves the folder alone")
    func consoleLoadOfAProjectFile() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Kit.basproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "PRINT PWD$\n".write(to: project.appendingPathComponent("src/main.bas"), atomically: true, encoding: .utf8)
        try "PRINT 1\n".write(to: root.appendingPathComponent("loose.bas"), atomically: true, encoding: .utf8)

        let studio = StudioHarness()
        try studio.model.changeDirectory(path: root.path)
        try await studio.submit("LOAD \"loose.bas\"")
        #expect(try studio.model.currentDirectoryPath() == root.standardizedFileURL.path)
        try await studio.submit("LOAD \"Kit.basproj/src/main.bas\"")
        #expect(try studio.model.currentDirectoryPath() == project.standardizedFileURL.path)
    }
}
