//
//  BundledExampleCatalogTests.swift
//  BASICStudioTests
//
//  The Examples catalog: which files in the demos tree are programs, and how
//  the menus group and name them, one submenu per category folder.
//

import Foundation
import Testing
@testable import BASICStudio

@Suite("Bundled example catalog")
@MainActor
struct BundledExampleCatalogTests {
    @Test("A program is a file, a project's entry, or a folder's main or namesake; a folder with none is a subcategory, unless it is imported")
    func programPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            "games/roids.bas": "PRINT 1", "games/notes.txt": "",
            "games/roids.build/roids.ll": "",
            "games/arcade/pong.bas": "PRINT 1",
            "games/arcade/breakout/main.bas": "IMPORT \"Bricks.bas\"", "games/arcade/breakout/Bricks.bas": "",
            "apps/contacts.basproj/main.bas": "", "apps/contacts.basproj/ContactModel.bas": "",
            "apps/POS.basproj/pos.bas": "import \"poslib/\"", "apps/POS.basproj/poslib/receipt.bas": "",
            "apps/POS.basproj/project.json": #"{"schemaVersion": 1, "kind": "project", "name": "POS", "entry": "pos.bas"}"#,
            "apps/Kit.basproj/src/main.bas": "", "apps/Kit.basproj/src/Parts.bas": "",
            "apps/old/main.bas": "",
            "data/gradebook.bas": "  import \"gradeslib/\" ' its classes", "data/gradeslib/student.bas": "class Student",
            "files/output/legacy.txt": "",
            "loose.bas": "",
        ]
        for (file, text) in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        #expect(Set(StudioModel.programPaths(in: root)) == [
            "games/roids", "games/arcade/pong", "games/arcade/breakout/main",
            "apps/contacts.basproj/main", "apps/POS.basproj/pos", "apps/Kit.basproj/src/main", "apps/old/main",
            "data/gradebook", "loose",
        ])
    }

    @Test("A program in a folder of its own is named for the folder, and sits in the folder above")
    func titles() {
        #expect(BundledExample(path: "games/roids").title == "Roids")
        #expect(BundledExample(path: "games/roids").menuFolders == ["games"])
        #expect(BundledExample(path: "activeui/aui-gallery").title == "Aui Gallery")
        #expect(BundledExample(path: "apps/contacts.basproj/main").title == "Contacts")
        #expect(BundledExample(path: "apps/contacts.basproj/main").menuFolders == ["apps"])
        #expect(BundledExample(path: "apps/contacts.basproj/main").projectFolder == "apps/contacts.basproj")
        #expect(BundledExample(path: "apps/POS.basproj/pos").title == "POS")
        #expect(BundledExample(path: "apps/GradeBook.basproj/src/main").title == "Grade Book")
        #expect(BundledExample(path: "activeui/ActiveUICounterDemo").title == "Active UI Counter Demo")
        #expect(BundledExample(path: "language/fullOfErrors").title == "Full Of Errors")
        #expect(BundledExample(path: "apps/Kit.basproj/src/main").title == "Kit")
        #expect(BundledExample(path: "apps/Kit.basproj/src/main").menuFolders == ["apps"])
        #expect(BundledExample(path: "apps/old/main").title == "Old")
        #expect(BundledExample(path: "apps/old/main").projectFolder == nil)
        #expect(BundledExample(path: "games/arcade/pong").menuFolders == ["games", "arcade"])
        #expect(BundledExample(path: "games/roids").menuTitle == "Games / Roids")
    }

    @Test("The tree: categories in the catalog's order, deeper folders and programs by title")
    func tree() {
        let examples = ["language/hello", "zzz/odd", "games/roids", "games/arcade/pong", "games/arcade/breakout/main",
                        "games/Asteroids", "loose", "activeui/aui-gallery", "input-events/keys"]
            .map(BundledExample.init(path:))
        let tree = BundledExampleFolder.tree(examples)
        #expect(tree.folders.map(\.title) == ["Games", "Input and Events", "ActiveUI", "Language", "Zzz"])
        #expect(tree.examples.map(\.title) == ["Loose"])
        let games = tree.folders[0]
        #expect(games.folders.map(\.title) == ["Arcade"])
        #expect(games.folders[0].examples.map(\.title) == ["Breakout", "Pong"])
        #expect(games.examples.map(\.title) == ["Asteroids", "Roids"])
        #expect(tree.allExamples.count == examples.count)
        #expect(tree.allExamples.prefix(4).map(\.path) == ["games/arcade/breakout/main", "games/arcade/pong", "games/Asteroids", "games/roids"])
    }

    @Test("Desktop Only comes last on the Mac, and is left out on an iPad or iPhone")
    func desktopOnly() {
        let examples = ["desktopOnly/longWait", "language/hello", "games/roids"].map(BundledExample.init(path:))
        let tree = BundledExampleFolder.tree(examples)
        #expect(tree.folders.map(\.title) == ["Games", "Language", "Desktop Only"])
        #expect(BundledExampleFolder.isOffered("desktopOnly/longWait", onMobile: false))
        #expect(!BundledExampleFolder.isOffered("desktopOnly/longWait", onMobile: true))
        #expect(BundledExampleFolder.isOffered("language/fullOfErrors", onMobile: true))
    }

    @Test("The demos are found by walking down from the resources, wherever a build put them")
    func demosFolderIsFoundByWalking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // The release app: the module's resource bundle inside the app's Resources.
        let staged = root.appendingPathComponent("Staged/Contents/Resources")
        let nested = staged.appendingPathComponent("BASICStudio_BASICStudio.bundle/Contents/Resources/Demos/games")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged.appendingPathComponent("Other.bundle/Contents/Resources/Themes"), withIntermediateDirectories: true)
        // The Xcode app: Demos straight in Resources.
        let xcode = root.appendingPathComponent("Xcode/Contents/Resources")
        try FileManager.default.createDirectory(at: xcode.appendingPathComponent("Demos/games"), withIntermediateDirectories: true)

        #expect(StudioModel.folder(named: "Demos", under: staged)?.resolvingSymlinksInPath().path == nested.deletingLastPathComponent().resolvingSymlinksInPath().path)
        #expect(StudioModel.folder(named: "Demos", under: xcode)?.lastPathComponent == "Demos")
        #expect(StudioModel.folder(named: "Demos", under: root.appendingPathComponent("Xcode/Contents/Resources/Demos/games")) == nil)
    }

    @Test("This build's demos folder is the one the Examples menu comes from; Studio opens on no program")
    func thisBuildsDemosFolder() throws {
        let demos = try #require(StudioModel.demosFolder)
        #expect(demos.lastPathComponent == "Demos")
        #expect(FileManager.default.fileExists(atPath: demos.appendingPathComponent("games/roids.bas").path))
        #expect(StudioModel(launch: .headless).programText.isEmpty)
    }

    @Test("The demos tree has its games first, and no program outside a category")
    func shippedTree() {
        let tree = StudioHarness().model.exampleTree
        #expect(tree.folders.first?.name == "games")
        #expect(tree.examples.isEmpty)
        #expect(tree.allExamples.contains { $0.path == "games/roids" })
        #expect(!tree.allExamples.contains { $0.path.contains("gradeslib") || $0.path.contains("poslib") })
    }
}
