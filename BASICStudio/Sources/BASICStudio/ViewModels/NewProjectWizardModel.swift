//
//  NewProjectWizardModel.swift
//  BASICStudio
//
//  File ▸ New Project…: choose a recipe, name the project and say where it
//  goes, fill in the recipe's options, and create it (BASIC-24). No UI
//  framework here; the ActiveUI shell draws it (NewProjectWizardAUI).
//

import BASICRecipes
import Foundation

/// The New Project wizard's state: which page is showing, the recipe, the
/// name, the place, the options, and what creating them makes.
///
/// ```text
///   Recipe ──► Name & Location ──► Options (only if the recipe has any) ──► Create
///     ◄── Back keeps what was entered ──
/// ```
struct NewProjectWizardModel {
    enum Page: Equatable {
        case recipe
        case nameAndLocation
        case options
    }

    /// Every recipe offered: the built-in ones, then the user's.
    let recipes: [BASICRecipe]
    private(set) var page: Page = .recipe
    private(set) var selectedIndex = 0
    /// The project's name, as typed.
    var name: String {
        didSet { nameEdited = true }
    }
    /// The folder the project goes in.
    var location: URL
    /// Whether the location can be changed: on the Mac, yes; on iPhone and
    /// iPad, projects go in the Documents folder Studio works in.
    let canChooseLocation: Bool
    /// The recipe's options as entered, by key.
    var optionValues: [String: String] = [:]
    /// Once the name has been typed, picking another recipe leaves it be.
    private var nameEdited = false

    init(recipes: [BASICRecipe], location: URL, canChooseLocation: Bool) {
        self.recipes = recipes
        self.location = location
        self.canChooseLocation = canChooseLocation
        name = "MyProject"
        if let first = recipes.first {
            name = Self.freeName(Self.suggestedName(for: first), recipe: first, in: location)
        }
        nameEdited = false
    }

    var recipe: BASICRecipe? {
        recipes.indices.contains(selectedIndex) ? recipes[selectedIndex] : nil
    }

    /// The pages this recipe takes: Options only when it has some.
    var pages: [Page] {
        (recipe?.definition.options ?? []).isEmpty ? [.recipe, .nameAndLocation] : [.recipe, .nameAndLocation, .options]
    }

    var isLastPage: Bool { page == pages.last }
    var canGoBack: Bool { page != .recipe }

    /// Whether Next (or Create, on the last page) can be pressed.
    var canGoOn: Bool {
        switch page {
        case .recipe: return recipe != nil
        case .nameAndLocation, .options: return nameProblem == nil
        }
    }

    /// Picks recipe `index`, suggesting a name for it until one is typed.
    mutating func select(_ index: Int) {
        guard recipes.indices.contains(index) else { return }
        selectedIndex = index
        if !nameEdited {
            name = Self.freeName(Self.suggestedName(for: recipes[index]), recipe: recipes[index], in: location)
            nameEdited = false
        }
    }

    mutating func next() {
        guard canGoOn, let at = pages.firstIndex(of: page), at + 1 < pages.count else { return }
        page = pages[at + 1]
    }

    mutating func back() {
        guard let at = pages.firstIndex(of: page), at > 0 else { return }
        page = pages[at - 1]
    }

    /// `MyGame` for the Game recipe: "My" and the recipe's name, as one word.
    static func suggestedName(for recipe: BASICRecipe) -> String {
        "My" + recipe.definition.name.filter { $0.isLetter || $0.isNumber }
    }

    /// `name`, or `name2`, `name3` … when a project of that name is already
    /// in the folder, so the name suggested can be taken as it is.
    static func freeName(_ name: String, recipe: BASICRecipe, in location: URL) -> String {
        var candidate = name
        var number = 2
        while FileManager.default.fileExists(atPath: location.appendingPathComponent(recipe.folderName(for: candidate)).path) {
            candidate = name + String(number)
            number += 1
        }
        return candidate
    }

    /// What is wrong with the name here, or nil: a bad name, or a project of
    /// that name already in the folder.
    var nameProblem: String? {
        guard let recipe else { return "Choose a recipe." }
        if let problem = BASICRecipe.problem(withName: name) {
            return problem
        }
        if FileManager.default.fileExists(atPath: projectURL.path) {
            return "\(recipe.folderName(for: name)) is already there."
        }
        return nil
    }

    /// The folder creating it makes: `<location>/<Name>.basproj`.
    var projectURL: URL {
        location.appendingPathComponent(recipe?.folderName(for: name) ?? name, isDirectory: true)
    }

    /// The files the recipe makes, for the recipe page to list.
    var recipeFiles: [String] {
        recipe?.files.map { BASICRecipe.substitute($0.path, name: name, values: recipe?.optionValues(optionValues) ?? [:]) } ?? []
    }

    /// Makes the project; returns its folder.
    func create() throws -> URL {
        guard let recipe else { throw BASICRecipe.Failure("Choose a recipe.") }
        return try recipe.create(named: name, in: location, options: optionValues)
    }
}
