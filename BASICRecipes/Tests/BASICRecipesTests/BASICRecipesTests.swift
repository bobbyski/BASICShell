//
//  BASICRecipesTests.swift
//  BASICRecipesTests
//
//  The recipes BASIC projects start from, and the projects they make
//  (BASIC-24).
//

import Foundation
import Testing
@testable import BASICRecipes

/// The recipe folders as edited, found by walking down from this test
/// bundle's resources to the `Recipes` link copied into it.
private func recipesFolder() throws -> URL {
    let bundles = [Bundle.module, Bundle.main]
    for bundle in bundles {
        guard let resources = bundle.resourceURL,
              let walker = FileManager.default.enumerator(at: resources, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
        for case let url as URL in walker where url.lastPathComponent == "Recipes" {
            return url.resolvingSymlinksInPath()
        }
    }
    throw BASICRecipe.Failure("no Recipes folder among the test bundle's resources")
}

/// A fresh folder to make projects in.
private func scratchFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("basic-recipes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Suite("The built-in recipes")
struct BuiltInRecipeTests {
    @Test("The compiled-in catalog is the recipe folders exactly: run basic-recipe-catalog after changing one")
    func catalogMatchesFolders() throws {
        let fromFolders = try BASICRecipes.load(folder: try recipesFolder())
        #expect(!fromFolders.isEmpty)
        #expect(BASICRecipes.builtIn.map(\.id) == fromFolders.map(\.id))
        for (built, folder) in zip(BASICRecipes.builtIn, fromFolders) {
            #expect(built == folder, "\(built.id) differs from its folder")
        }
    }

    @Test("Each one is a BASIC project: a .basproj with a manifest naming a program that is there")
    func everyRecipeIsAProject() throws {
        for recipe in BASICRecipes.builtIn {
            #expect(recipe.definition.language == "BASIC")
            #expect(recipe.definition.folderExtension == "basproj")
            let paths = Set(recipe.files.map(\.path))
            #expect(paths.isSuperset(of: ["project.json", "Makefile", ".gitignore", "README.md", "src/main.bas"]), "\(recipe.id): \(paths.sorted())")
            #expect(recipe.definition.openFile.map(paths.contains) == true, "\(recipe.id) opens a file it does not make")
        }
    }

    @Test("They are offered in order, starting with the console program, and found by short name")
    func order() {
        let ids = BASICRecipes.builtIn.map(\.id)
        #expect(ids.prefix(5) == ["basic.console", "basic.structured", "basic.game", "basic.tui", "basic.activeui"])
        #expect(BASICRecipes.builtIn(named: "game")?.id == "basic.game")
        #expect(BASICRecipes.builtIn(named: "basic.tui")?.id == "basic.tui")
        #expect(BASICRecipes.builtIn(named: "nothing") == nil)
        #expect(BASICRecipes.builtIn.map(BASICRecipes.shortName).prefix(2) == ["console", "structured"])
    }
}

@Suite("Making a project")
struct ProjectCreationTests {
    @Test("A recipe makes Name.basproj, with its name filled in everywhere")
    func create() throws {
        let parent = try scratchFolder()
        let game = try #require(BASICRecipes.builtIn(named: "game"))
        let project = try game.create(named: "Rocks", in: parent)
        #expect(project.lastPathComponent == "Rocks.basproj")
        #expect(BASICProjectFolder.isProject(project))
        #expect(BASICProjectFolder.name(of: project) == "Rocks")
        let main = try String(contentsOf: project.appendingPathComponent("src/main.bas"), encoding: .utf8)
        #expect(main.hasPrefix("#!/usr/bin/env BASICShell\n' Rocks — a game to build on."))
        #expect(!main.contains("{{"))
        let makefile = try String(contentsOf: project.appendingPathComponent("Makefile"), encoding: .utf8)
        #expect(makefile.contains("NAME := Rocks\n"))
        #expect(BASICProjectFolder.entry(of: project)?.lastPathComponent == "main.bas")
        #expect(game.fileToOpen(in: project, name: "Rocks") == project.appendingPathComponent("src/main.bas"))
    }

    @Test("Nothing that is there is written over")
    func refusesExisting() throws {
        let parent = try scratchFolder()
        let console = try #require(BASICRecipes.builtIn(named: "console"))
        try console.create(named: "Hello", in: parent)
        #expect(throws: BASICRecipe.Failure("Hello.basproj is already there.")) {
            try console.create(named: "Hello", in: parent)
        }
    }

    @Test("A name is letters, digits, - and _")
    func names() {
        #expect(BASICRecipe.problem(withName: "My_Game-2") == nil)
        #expect(BASICRecipe.problem(withName: "") != nil)
        #expect(BASICRecipe.problem(withName: "My Game") != nil)
        #expect(BASICRecipe.problem(withName: "a/b") != nil)
        #expect(BASICRecipe.problem(withName: "-x") != nil)
    }

    @Test("Options fill their {{KEY}}s; a checkbox fills its value or nothing")
    func options() throws {
        let recipe = BASICRecipe(
            definition: .init(
                identifier: "test.options", name: "Options", language: "BASIC", summary: "",
                options: [
                    .init(key: "GREETING", prompt: "Greeting", defaultValue: "Hello"),
                    .init(key: "LOUD", prompt: "Shout", checkedValue: "!"),
                ],
                folderExtension: "basproj"
            ),
            files: [.init(path: "src/{{NAME_LOWER}}.bas", contents: "PRINT \"{{GREETING}} from {{NAME}}{{LOUD}}\"\n{{UNKNOWN}}\n")]
        )
        let parent = try scratchFolder()
        let quiet = try recipe.create(named: "Quiet", in: parent)
        #expect(try String(contentsOf: quiet.appendingPathComponent("src/quiet.bas"), encoding: .utf8) == "PRINT \"Hello from Quiet\"\n{{UNKNOWN}}\n")
        let loud = try recipe.create(named: "Loud", in: parent, options: ["GREETING": "Hi", "LOUD": "true"])
        #expect(try String(contentsOf: loud.appendingPathComponent("src/loud.bas"), encoding: .utf8) == "PRINT \"Hi from Loud!\"\n{{UNKNOWN}}\n")
    }
}

@Suite("Project folders")
struct ProjectFolderTests {
    @Test("A folder is a project by its .basproj name or its project.json; it runs its entry")
    func recognize() throws {
        let parent = try scratchFolder()
        let plain = parent.appendingPathComponent("Plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(!BASICProjectFolder.isProject(plain))

        // A folder with a manifest, its program where the manifest says.
        let named = parent.appendingPathComponent("Named", isDirectory: true)
        try FileManager.default.createDirectory(at: named.appendingPathComponent("app"), withIntermediateDirectories: true)
        try BASICProjectFolder.manifestText(name: "Named", entry: "app/start.bas").write(to: named.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        try "PRINT 1\n".write(to: named.appendingPathComponent("app/start.bas"), atomically: true, encoding: .utf8)
        #expect(BASICProjectFolder.isProject(named))
        #expect(BASICProjectFolder.entry(of: named)?.lastPathComponent == "start.bas")

        // A .basproj with no manifest runs main.bas.
        let bare = parent.appendingPathComponent("Bare.basproj", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try "PRINT 2\n".write(to: bare.appendingPathComponent("main.bas"), atomically: true, encoding: .utf8)
        #expect(BASICProjectFolder.isProject(bare))
        #expect(BASICProjectFolder.name(of: bare) == "Bare")
        #expect(BASICProjectFolder.entry(of: bare)?.lastPathComponent == "main.bas")
        #expect(BASICProjectFolder.displayName(ofFolder: "contacts.basproj") == "contacts")
    }

    @Test("A user's recipe folder is read like the built-in ones, without taking a built-in's place")
    func userRecipes() throws {
        let folder = try scratchFolder()
        let mine = folder.appendingPathComponent("mine", isDirectory: true)
        try FileManager.default.createDirectory(at: mine.appendingPathComponent("src"), withIntermediateDirectories: true)
        try #"{"identifier": "me.mine", "name": "Mine", "language": "BASIC", "summary": "Mine."}"#
            .write(to: mine.appendingPathComponent("recipe.json"), atomically: true, encoding: .utf8)
        try "PRINT 3\n".write(to: mine.appendingPathComponent("src/main.bas"), atomically: true, encoding: .utf8)
        let clash = folder.appendingPathComponent("clash", isDirectory: true)
        try FileManager.default.createDirectory(at: clash, withIntermediateDirectories: true)
        try #"{"identifier": "basic.game", "name": "Not the game", "language": "BASIC", "summary": "No."}"#
            .write(to: clash.appendingPathComponent("recipe.json"), atomically: true, encoding: .utf8)
        try "x\n".write(to: clash.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)

        let all = BASICRecipes.all(userFolders: [folder])
        #expect(all.last?.id == "me.mine")
        #expect(all.filter { $0.id == "basic.game" }.count == 1)
        #expect(all.first { $0.id == "basic.game" }?.definition.name == "Game")
        #expect(all.last?.files.map(\.path) == ["src/main.bas"])
    }
}
