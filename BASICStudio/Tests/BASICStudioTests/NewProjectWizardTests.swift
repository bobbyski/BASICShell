//
//  NewProjectWizardTests.swift
//  BASICStudioTests
//
//  File ▸ New Project… (BASIC-24): the wizard's pages, the name it suggests
//  and refuses, and the project Create makes and opens.
//

import ActiveUI
import BASICRecipes
import Foundation
import Testing
@testable import BASICStudio

@Suite("New Project wizard", .serialized)
@MainActor
struct NewProjectWizardTests {
    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("studio-new-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.standardizedFileURL
    }

    /// A recipe with one text option and one checkbox, for the Options page.
    private func recipeWithOptions() throws -> BASICRecipe {
        try BASICRecipe(json: """
        {
          "identifier": "user.greeter",
          "name": "Greeter",
          "language": "BASIC",
          "summary": "Says hello.",
          "folderExtension": "basproj",
          "openFile": "src/main.bas",
          "options": [
            { "key": "GREETING", "prompt": "Greeting", "defaultValue": "Hello" },
            { "key": "LOUD", "prompt": "Shout it", "defaultValue": "", "checkedValue": "!" }
          ]
        }
        """, files: [
            BASICRecipe.File(path: "project.json", contents: BASICProjectFolder.manifestText(name: "{{NAME}}", entry: "src/main.bas")),
            BASICRecipe.File(path: "src/main.bas", contents: "PRINT \"{{GREETING}}, {{NAME}}{{LOUD}}\"\n"),
        ])
    }

    @Test("It starts on the recipes, with a name suggested for the first")
    func startsOnRecipes() throws {
        let wizard = NewProjectWizardModel(recipes: BASICRecipes.builtIn, location: try scratch(), canChooseLocation: true)
        #expect(wizard.page == .recipe)
        #expect(wizard.recipe?.id == "basic.console")
        #expect(wizard.name == "MyConsoleProgram")
        #expect(wizard.pages == [.recipe, .nameAndLocation])
        #expect(!wizard.canGoBack)
        #expect(wizard.canGoOn)
        #expect(!wizard.isLastPage)
    }

    @Test("Picking a recipe suggests its name until one is typed")
    func suggestsNames() throws {
        var wizard = NewProjectWizardModel(recipes: BASICRecipes.builtIn, location: try scratch(), canChooseLocation: true)
        let game = try #require(BASICRecipes.builtIn.firstIndex { $0.id == "basic.game" })
        wizard.select(game)
        #expect(wizard.name == "MyGame")
        wizard.name = "Asteroids"
        wizard.select(0)
        #expect(wizard.name == "Asteroids")
        #expect(wizard.recipe?.id == "basic.console")
    }

    @Test("The name suggested is one not taken: MyGame2 when MyGame is there")
    func suggestsFreeNames() throws {
        let location = try scratch()
        defer { try? FileManager.default.removeItem(at: location) }
        for taken in ["MyGame.basproj", "MyGame2.basproj"] {
            try FileManager.default.createDirectory(at: location.appendingPathComponent(taken), withIntermediateDirectories: true)
        }
        var wizard = NewProjectWizardModel(recipes: BASICRecipes.builtIn, location: location, canChooseLocation: true)
        wizard.select(try #require(BASICRecipes.builtIn.firstIndex { $0.id == "basic.game" }))
        #expect(wizard.name == "MyGame3")
        #expect(wizard.nameProblem == nil)
    }

    @Test("A bad name, or a project already there, keeps Create from being pressed")
    func refusesNames() throws {
        let location = try scratch()
        defer { try? FileManager.default.removeItem(at: location) }
        var wizard = NewProjectWizardModel(recipes: BASICRecipes.builtIn, location: location, canChooseLocation: true)
        wizard.next()
        #expect(wizard.page == .nameAndLocation)
        #expect(wizard.isLastPage)
        #expect(wizard.nameProblem == nil)

        wizard.name = ""
        #expect(wizard.nameProblem != nil)
        #expect(!wizard.canGoOn)
        wizard.name = "a/b"
        #expect(wizard.nameProblem != nil)

        wizard.name = "Taken"
        try FileManager.default.createDirectory(at: location.appendingPathComponent("Taken.basproj"), withIntermediateDirectories: true)
        #expect(wizard.nameProblem == "Taken.basproj is already there.")
        #expect(!wizard.canGoOn)
    }

    @Test("Options get a page of their own, and Back keeps what was entered")
    func optionsPage() throws {
        let location = try scratch()
        defer { try? FileManager.default.removeItem(at: location) }
        var wizard = NewProjectWizardModel(recipes: [try recipeWithOptions()], location: location, canChooseLocation: true)
        #expect(wizard.pages == [.recipe, .nameAndLocation, .options])
        wizard.next()
        wizard.name = "Hi"
        #expect(!wizard.isLastPage)
        wizard.next()
        #expect(wizard.page == .options)
        #expect(wizard.isLastPage)
        wizard.optionValues["GREETING"] = "Howdy"
        wizard.back()
        #expect(wizard.page == .nameAndLocation)
        #expect(wizard.name == "Hi")
        wizard.next()
        #expect(wizard.optionValues["GREETING"] == "Howdy")

        let project = try wizard.create()
        #expect(project.lastPathComponent == "Hi.basproj")
        let main = try String(contentsOf: project.appendingPathComponent("src/main.bas"), encoding: .utf8)
        #expect(main == "PRINT \"Howdy, Hi\"\n")
    }

    @Test("Create makes Name.basproj, opens it, and puts its main.bas in the editor")
    func createsAndOpens() throws {
        let location = try scratch()
        defer { try? FileManager.default.removeItem(at: location) }
        let model = StudioHarness().model
        var wizard = NewProjectWizardModel(recipes: BASICRecipes.builtIn, location: location, canChooseLocation: true)
        wizard.select(try #require(BASICRecipes.builtIn.firstIndex { $0.id == "basic.game" }))
        wizard.next()
        wizard.name = "Rocks"

        let project = try model.createProject(from: wizard)
        #expect(project == location.appendingPathComponent("Rocks.basproj").standardizedFileURL)
        #expect(BASICProjectFolder.entry(of: project) == project.appendingPathComponent("src/main.bas"))
        #expect(model.projectDirectoryURL == project)
        #expect(model.currentProgramURL == project.appendingPathComponent("src/main.bas"))
        #expect(model.programText.contains("Rocks"))
        #expect(ProjectModel(model).title == "Rocks")
    }

    @Test("In the ActiveUI shell, File ▸ New Project… brings up the wizard, not a save panel")
    func shellPresentsWizard() {
        let model = StudioHarness().model
        #expect(model.newProjectWizardPresenter == nil)
        let studio = StudioActiveUIShell(model: model)
        #expect(model.newProjectWizardPresenter != nil)
        #expect(studio.newProjectWizard == nil)
    }

    @Test("The sheet walks the pages: pick, name, Create")
    func sheetWalksPages() throws {
        let location = try scratch()
        defer { try? FileManager.default.removeItem(at: location) }
        var finished: [NewProjectWizardModel?] = []
        let sheet = NewProjectWizardAUI(wizard: NewProjectWizardModel(recipes: BASICRecipes.builtIn, location: location, canChooseLocation: true)) {
            finished.append($0)
        }
        #expect(sheet.pageTitle.text == "Choose a recipe")
        #expect(!sheet.backButton.isEnabled)
        #expect(sheet.nextButton.title == "Next")

        let game = try #require(BASICRecipes.builtIn.firstIndex { $0.id == "basic.game" })
        sheet.recipeTable.onSelectionChange?([game])
        #expect(sheet.wizard.recipe?.id == "basic.game")
        #expect(sheet.recipeSummary.text == sheet.wizard.recipe?.definition.summary)

        sheet.nextButton.onClick?()
        #expect(sheet.pageTitle.text == "Name the project")
        #expect(sheet.nameField.text == "MyGame")
        #expect(sheet.nextButton.title == "Create")
        #expect(sheet.backButton.isEnabled)

        sheet.nameField.onChange?("")
        #expect(!sheet.nextButton.isEnabled)
        #expect(!sheet.nameProblem.text.isEmpty)
        sheet.nameField.onChange?("Rocks")
        #expect(sheet.nextButton.isEnabled)
        #expect(sheet.createsLabel.text == "Creates Rocks.basproj")

        sheet.nextButton.onClick?()
        sheet.nextButton.onClick?()
        #expect(finished.count == 1)
        #expect(finished.first??.name == "Rocks")
        #expect(finished.first??.recipe?.id == "basic.game")
    }

    @Test("Cancel ends it with nothing made")
    func sheetCancels() throws {
        let location = try scratch()
        defer { try? FileManager.default.removeItem(at: location) }
        var finished: [NewProjectWizardModel?] = []
        let sheet = NewProjectWizardAUI(wizard: NewProjectWizardModel(recipes: BASICRecipes.builtIn, location: location, canChooseLocation: true)) {
            finished.append($0)
        }
        sheet.cancelButton.onClick?()
        #expect(finished.count == 1)
        #expect(finished.first! == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: location.path).isEmpty)
    }

    @Test("Options show as a field and a switch, and fill the files")
    func sheetOptions() throws {
        let location = try scratch()
        defer { try? FileManager.default.removeItem(at: location) }
        let sheet = NewProjectWizardAUI(wizard: NewProjectWizardModel(recipes: [try recipeWithOptions()], location: location, canChooseLocation: true))
        sheet.nextButton.onClick?()
        sheet.nameField.onChange?("Hi")
        sheet.nextButton.onClick?()
        #expect(sheet.pageTitle.text == "Options")
        let greeting = try #require(sheet.optionFields["GREETING"])
        #expect(greeting.text == "Hello")
        let loud = try #require(sheet.optionSwitches["LOUD"])
        loud.onChange?(true)
        let project = try sheet.wizard.create()
        let main = try String(contentsOf: project.appendingPathComponent("src/main.bas"), encoding: .utf8)
        #expect(main == "PRINT \"Hello, Hi!\"\n")
    }
}
