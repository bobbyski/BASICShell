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
    @Test("A program is a file, or a folder's main or namesake; a folder with neither is a subcategory, unless it is imported")
    func programPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            "games/roids.bas": "PRINT 1", "games/notes.txt": "",
            "games/roids.build/roids.ll": "",
            "games/arcade/pong.bas": "PRINT 1",
            "games/arcade/breakout/main.bas": "IMPORT \"Bricks.bas\"", "games/arcade/breakout/Bricks.bas": "",
            "apps/contacts/main.bas": "", "apps/contacts/ContactModel.bas": "",
            "apps/POS/pos.bas": "import \"poslib/\"", "apps/POS/poslib/receipt.bas": "",
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
            "apps/contacts/main", "apps/POS/pos", "data/gradebook", "loose",
        ])
    }

    @Test("A program in a folder of its own is named for the folder, and sits in the folder above")
    func titles() {
        #expect(BundledExample(path: "games/roids").title == "Roids")
        #expect(BundledExample(path: "games/roids").menuFolders == ["games"])
        #expect(BundledExample(path: "activeui/aui-gallery").title == "Aui Gallery")
        #expect(BundledExample(path: "apps/contacts/main").title == "Contacts")
        #expect(BundledExample(path: "apps/contacts/main").menuFolders == ["apps"])
        #expect(BundledExample(path: "apps/POS/pos").title == "POS")
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

    @Test("The demos tree has its games first, and no program outside a category")
    func shippedTree() {
        let tree = StudioHarness().model.exampleTree
        #expect(tree.folders.first?.name == "games")
        #expect(tree.examples.isEmpty)
        #expect(tree.allExamples.contains { $0.path == "games/roids" })
        #expect(!tree.allExamples.contains { $0.path.contains("gradeslib") || $0.path.contains("poslib") })
    }
}
