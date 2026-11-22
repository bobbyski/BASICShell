//
//  ZipProjectTests.swift
//  BASICStudioTests
//
//  BASIC-72: a zipped project in Studio, through ProjectKit. It opens from its
//  working copy, Save writes the zip, and the sidebar's commands change it.
//

import BASICProjects
import BASICRecipes
import Foundation
import Testing
@testable import BASICStudio

@Suite("Zipped projects", .serialized)
@MainActor
struct ZipProjectTests {
    /// A folder of its own, with the working copies in it, and a new zipped project
    /// `Rocks.basproj` from the console recipe.
    private func makeZip() throws -> (folder: URL, zip: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("studio-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        StudioOpenProject.workingCopies = folder.appendingPathComponent("WorkingCopies", isDirectory: true)
        let recipe = try #require(BASICRecipes.builtIn(named: "console"))
        return (folder, try BASICProjects.create(from: recipe, named: "Rocks", in: folder))
    }

    /// The text of `path` in the zip, read in place.
    private func zipText(_ zip: URL, _ path: String) throws -> String {
        try ProjectReader.open(at: zip, as: BASICProjects.types).text(at: path)
    }

    @Test("A zip opens with its entry in the editor, from the working copy; Save writes the zip at once")
    func openAndSave() throws {
        let (folder, zip) = try makeZip()
        defer {
            StudioOpenProject.workingCopies = nil
            try? FileManager.default.removeItem(at: folder)
        }
        let model = StudioHarness().model
        model.openProjectAndEntry(at: zip)
        let files = try #require(model.projectDirectoryURL)
        #expect(model.openedProject?.isZip == true)
        #expect(files.path.hasPrefix(folder.appendingPathComponent("WorkingCopies").path), "the working copy")
        #expect(model.currentProgramURL == files.appendingPathComponent("src/main.bas"))
        #expect(ProjectModel(model).title == "Rocks")
        #expect(model.projectFiles.contains("src/main.bas") && model.projectFiles.contains("project.json"))

        model.programText = "PRINT \"SAVED INTO THE ZIP\"\n"
        model.saveProgramFromMenu()
        #expect(try zipText(zip, "src/main.bas") == "PRINT \"SAVED INTO THE ZIP\"\n")

        model.closeStudioProject()
        #expect(model.projectDirectoryURL == nil)
        #expect(!FileManager.default.fileExists(atPath: files.path), "closing lets the working copy go")
    }

    @Test("The sidebar's commands: New File, New Folder, Rename, Move and Delete, saved into the zip")
    func fileCommands() async throws {
        let (folder, zip) = try makeZip()
        defer {
            StudioOpenProject.workingCopies = nil
            try? FileManager.default.removeItem(at: folder)
        }
        let model = StudioHarness().model
        var answers = ["levels", "level1.txt", "first.txt", "levels"]
        model.projectNamePrompter = { _, _ in answers.isEmpty ? nil : answers.removeFirst() }
        model.deleteConfirmationAnswer = { _, _ in true }
        model.openProjectAndEntry(at: zip)

        await model.newProjectFolder()                       // levels/
        #expect(model.projectFiles.contains("levels/"))
        #expect(model.projectSelection == "levels/")
        await model.newProjectFile()                         // levels/level1.txt, in the selected folder
        #expect(model.projectFiles.contains("levels/level1.txt"))
        #expect(model.currentProgramURL?.lastPathComponent == "level1.txt")
        await model.renameProjectItem()                      // levels/first.txt; the editor follows it
        #expect(model.projectFiles.contains("levels/first.txt") && !model.projectFiles.contains("levels/level1.txt"))
        #expect(model.currentProgramURL?.lastPathComponent == "first.txt")
        model.projectSelection = "src/main.bas"
        await model.moveProjectItem()                        // src/main.bas into levels/
        #expect(model.projectFiles.contains("levels/main.bas"))
        await model.deleteProjectItem()                      // levels/main.bas
        #expect(!model.projectFiles.contains("levels/main.bas"))

        try model.openedProject?.save()
        let names = try ProjectReader.open(at: zip, as: BASICProjects.types).items(recursive: true).map(\.path.description)
        #expect(names.contains("levels/first.txt"))
        #expect(!names.contains("src/main.bas") && !names.contains("levels/main.bas"))
        model.closeStudioProject()
    }

    @Test("A one-file example closes the open project; the program runs where the project was, not in its working copy")
    func oneFileExampleClosesProject() throws {
        let (folder, zip) = try makeZip()
        defer {
            StudioOpenProject.workingCopies = nil
            try? FileManager.default.removeItem(at: folder)
        }
        let model = StudioHarness().model
        model.openProjectAndEntry(at: zip)
        #expect(model.openedProject != nil && !model.projectFiles.isEmpty)
        let example = try #require(model.bundledExamples.first { $0.path == "games/brick-breaker" })
        model.loadBundledExample(example)
        #expect(model.openedProject == nil, "the sidebar lists no project")
        #expect(model.projectDirectoryURL == nil && model.projectFiles.isEmpty)
        #expect(!model.programText.isEmpty && model.currentProgramURL == nil)
        // With no project open, this is the working directory: the zip's folder.
        #expect(model.currentDirectoryURL.standardizedFileURL.path == folder.standardizedFileURL.path)
    }

    @Test("Open Recent of a file outside the project closes it; one of the project's own files keeps it")
    func loneFileClosesProject() throws {
        let (folder, zip) = try makeZip()
        defer {
            StudioOpenProject.workingCopies = nil
            try? FileManager.default.removeItem(at: folder)
        }
        let model = StudioHarness().model
        model.openProjectAndEntry(at: zip)
        let inside = try #require(model.projectDirectoryURL).appendingPathComponent("src/main.bas")
        model.openRecent(inside, as: .file)
        #expect(model.openedProject != nil, "its own file keeps the project open")

        let outside = folder.appendingPathComponent("loose.bas")
        try "PRINT 1\n".write(to: outside, atomically: true, encoding: .utf8)
        model.openRecent(outside, as: .file)
        #expect(model.openedProject == nil)
        #expect(model.projectFiles.isEmpty)
        #expect(model.currentProgramURL == outside)
    }

    @Test("What a program writes into a zip project is saved with it")
    func programWritesAreSaved() throws {
        let (folder, zip) = try makeZip()
        defer {
            StudioOpenProject.workingCopies = nil
            try? FileManager.default.removeItem(at: folder)
        }
        let model = StudioHarness().model
        model.openProjectAndEntry(at: zip)
        let files = try #require(model.projectDirectoryURL)
        try model.saveTextFile(path: files.appendingPathComponent("scores.txt").path, text: "100\n")
        model.closeStudioProject()
        #expect(try zipText(zip, "scores.txt") == "100\n")
    }
}
