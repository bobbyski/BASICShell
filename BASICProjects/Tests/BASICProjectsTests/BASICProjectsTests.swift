import Foundation
import Testing
import BASICRecipes
@testable import BASICProjects

/// A new empty folder for one test, under the temporary folder.
private func scratchFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("basic-projects-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Options that keep a zip's working copy beside the test's files.
private func options(_ folder: URL) -> ProjectOptions {
    ProjectOptions(saving: .manual, workingCopies: folder.appendingPathComponent("WorkingCopies", isDirectory: true))
}

@Suite("BASIC projects over ProjectKit")
struct BASICProjectsTests {
    private let console = BASICRecipes.builtIn(named: "console")!

    @Test("BASIC's types: .basproj and .baslib, both forms, new projects zipped")
    func types() {
        #expect(ProjectType.basicProject.extension == "basproj")
        #expect(ProjectType.basicProject.marker == "project.json")
        #expect(ProjectType.basicProject.defaultForm == .zip)
        #expect(ProjectType.basicLibrary.marker == "library.json")
        #expect(BASICProjects.types == [.basicProject, .basicLibrary])
    }

    @Test("A new project is a zip by default: recognized as one, and it runs src/main.bas")
    func newZip() throws {
        let folder = try scratchFolder()
        let made = try BASICProjects.create(from: console, named: "Invaders", in: folder)
        #expect(made.lastPathComponent == "Invaders.basproj")
        let found = try BASICProjects.recognize(made)
        #expect(found.form == .zip)
        #expect(found.type == .basicProject)
        #expect(BASICProjects.isRunnableProject(made))
        let reader = try ProjectReader.open(at: made, as: BASICProjects.types)
        #expect(try BASICProjects.entry(of: reader).description == "src/main.bas")
        #expect(try reader.text(at: "src/main.bas").contains("PRINT"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(leftovers == ["Invaders.basproj"], "nothing but the zip is left behind")
    }

    @Test("Asked for a folder, the recipe's folder as it always was")
    func newFolder() throws {
        let folder = try scratchFolder()
        let made = try BASICProjects.create(from: console, named: "Notes", in: folder, form: .folder)
        #expect(try BASICProjects.recognize(made).form == .folder)
        let project = try Project.open(at: made, as: BASICProjects.types, options: options(folder))
        #expect(try BASICProjects.entry(of: project).description == "src/main.bas")
    }

    @Test("Never over something already there, in either form")
    func refusesExisting() throws {
        let folder = try scratchFolder()
        try BASICProjects.create(from: console, named: "Twice", in: folder)
        #expect(throws: BASICRecipe.Failure.self) { try BASICProjects.create(from: console, named: "Twice", in: folder) }
        #expect(throws: BASICRecipe.Failure.self) {
            try BASICProjects.create(from: console, named: "Twice", in: folder, form: .folder)
        }
    }

    @Test("The entry rule reads through the project: a named file that's missing is said, not swapped")
    func entryThroughZip() throws {
        let folder = try scratchFolder()
        let made = try BASICProjects.create(from: console, named: "Broken", in: folder)
        let project = try Project.open(at: made, as: BASICProjects.types, options: options(folder))
        try project.write("project.json", text: BASICProjectFolder.manifestText(name: "Broken", entry: "src/gone.bas"))
        #expect(BASICProjects.entryPoint(of: project) == .missing("src/gone.bas"))
        #expect(throws: BASICProjects.EntryProblem.self) { try BASICProjects.entry(of: project) }
        try project.delete("project.json", toTrash: false)
        #expect(BASICProjects.entryPoint(of: project) == .file("src/main.bas"))
        try project.close()
    }

    @Test("An IDE opens any folder of programs too, last; a real project still wins")
    func openingAnyFolder() throws {
        let folder = try scratchFolder()
        try "PRINT 1\n".write(to: folder.appendingPathComponent("main.bas"), atomically: true, encoding: .utf8)
        #expect(try ProjectRecognition.recognize(folder, as: BASICProjects.typesForOpening).type == .basicFolder)
        let project = try Project.open(at: folder, as: BASICProjects.typesForOpening, options: options(folder))
        #expect(BASICProjects.entryPoint(of: project) == .file("main.bas"))
        let made = try BASICProjects.create(from: console, named: "Real", in: folder)
        #expect(try ProjectRecognition.recognize(made, as: BASICProjects.typesForOpening).type == .basicProject)
    }

    @Test("Not projects: a loose .bas, a plain folder, a missing path")
    func notProjects() throws {
        let folder = try scratchFolder()
        let loose = folder.appendingPathComponent("hello.bas")
        try "PRINT 1\n".write(to: loose, atomically: true, encoding: .utf8)
        #expect(!BASICProjects.isProject(loose))
        #expect(!BASICProjects.isProject(folder))
        #expect(!BASICProjects.isProject(folder.appendingPathComponent("missing.basproj")))
    }
}
