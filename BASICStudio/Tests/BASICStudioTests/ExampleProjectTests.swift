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
}
