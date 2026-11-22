//
//  NewProjectWizardAUI.swift
//  BASICStudio
//
//  File ▸ New Project…, drawn with ActiveUI in a sheet, on the Mac and on
//  iPad (BASIC-24). The pages and what they hold are NewProjectWizardModel's;
//  this draws the page showing and passes on what is done to it.
//

import ActiveUI
import BASICProjects
import BASICRecipes
import Foundation

/// The wizard's sheet content.
///
/// ```text
///   ┌ New Project ────────────────────────────────┐
///   │  Choose a recipe          ← the page's title │
///   │  ┌──────────────────────────────────────┐   │
///   │  │  page: recipes │ name │ options      │   │
///   │  └──────────────────────────────────────┘   │
///   │  Cancel                     Back   Next ▸    │
///   └──────────────────────────────────────────────┘
/// ```
@MainActor
final class NewProjectWizardAUI {
    static let contentSize = CGSize(width: 560, height: 440)

    private(set) var wizard: NewProjectWizardModel
    let root: AUIStack
    let pageTitle = AUILabel("")
    /// Where the page showing goes.
    let page = AUIStack(.vertical, spacing: 10, alignment: .fill)
    let cancelButton = AUIButton("Cancel")
    let backButton = AUIButton("Back")
    let nextButton = AUIButton("Next")

    // The recipe page.
    private(set) var recipeTable: AUITable!
    let recipeSummary = AUILabel("")
    let recipeFiles = AUILabel("")

    // The name and location page.
    let nameField = AUITextField("", placeholder: "Name")
    let nameProblem = AUILabel("")
    let locationLabel = AUILabel("")
    let chooseLocationButton = AUIButton("Choose…")
    /// Zip (the default) or Package: how the project is stored.
    let formControl = AUISegmentedControl(["Zip", "Package"], selectedIndex: 0)
    let formNote = AUILabel("")
    let createsLabel = AUILabel("")

    // The options page: one control per option, by key.
    private(set) var optionFields: [String: AUITextField] = [:]
    private(set) var optionSwitches: [String: AUISwitch] = [:]

    /// Told how it ended: the wizard to create the project from, or nil
    /// for Cancel. Called once.
    var onFinish: (NewProjectWizardModel?) -> Void
    /// Asks for a folder, starting at the one given; set where the
    /// location can be changed.
    var chooseFolder: ((URL, @escaping (URL) -> Void) -> Void)?

    init(wizard: NewProjectWizardModel, onFinish: @escaping (NewProjectWizardModel?) -> Void = { _ in }) {
        self.wizard = wizard
        self.onFinish = onFinish
        root = AUIStack(.vertical, spacing: 14, alignment: .fill)
        root.wraps = false
        root.padding = AUIEdgeInsets(top: 20, leading: 20, bottom: 16, trailing: 20)

        pageTitle.font = .title
        page.wraps = false
        let footer = LogPaneAUI.row([cancelButton, AUISpacer(), backButton, nextButton])

        root.addChild(pageTitle)
        root.addChild(page)
        root.addChild(AUISpacer())
        root.addChild(footer)

        let recipes = wizard.recipes
        recipeTable = AUITable(rowCount: { recipes.count }) { index in
            Self.recipeRow(recipes[index])
        }
        // A fixed height, so a longer summary under it does not move it.
        recipeTable.minimumSize = CGSize(width: 0, height: 200)
        recipeTable.maximumSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 200)
        recipeTable.onSelectionChange = { [weak self] rows in
            guard let self, let row = rows.first else { return }
            self.wizard.select(row)
            self.refresh()
        }
        recipeSummary.wraps = true
        recipeFiles.wraps = true
        recipeFiles.font = .caption
        nameProblem.wraps = true
        nameProblem.font = .caption
        nameProblem.textColor = .red
        locationLabel.wraps = true
        formNote.wraps = true
        formNote.font = .caption
        createsLabel.wraps = true
        createsLabel.font = .caption

        nameField.onChange = { [weak self] text in
            self?.wizard.name = text
            self?.refreshButtons()
        }
        chooseLocationButton.onClick = { [weak self] in self?.chooseLocation() }
        formControl.onSelectionChange = { [weak self] index in
            self?.wizard.form = index == 1 ? .folder : .zip
            self?.refresh()
        }
        cancelButton.onClick = { [weak self] in self?.finish(with: nil) }
        backButton.onClick = { [weak self] in self?.back() }
        nextButton.onClick = { [weak self] in self?.goOn() }

        showPage()
    }

    // MARK: - Moving through it

    func back() {
        wizard.back()
        showPage()
    }

    /// Next, or Create on the last page.
    func goOn() {
        guard wizard.canGoOn else { return }
        if wizard.isLastPage {
            finish(with: wizard)
        } else {
            wizard.next()
            showPage()
        }
    }

    private var finished = false

    private func finish(with result: NewProjectWizardModel?) {
        guard !finished else { return }
        finished = true
        onFinish(result)
    }

    func chooseLocation() {
        chooseFolder?(wizard.location) { [weak self] url in
            self?.wizard.location = url.standardizedFileURL
            self?.refresh()
        }
    }

    // MARK: - Drawing the page

    /// Puts the page showing in place and fills it from the wizard.
    private func showPage() {
        page.removeAllChildren()
        switch wizard.page {
        case .recipe:
            pageTitle.text = "Choose a recipe"
            page.addChild(recipeTable)
            page.addChild(recipeSummary)
            page.addChild(recipeFiles)
            recipeTable.reloadData()
            recipeTable.selectedRows = [wizard.recipes.firstIndex { $0.id == wizard.recipe?.id } ?? 0]
        case .nameAndLocation:
            pageTitle.text = "Name the project"
            nameField.text = wizard.name
            page.addChild(Self.labeled("Name", nameField))
            page.addChild(nameProblem)
            // The path on a line of its own, Choose… under it: a long path wraps
            // rather than pushing the button out of the sheet.
            page.addChild(Self.labeled("Location", locationLabel))
            if wizard.canChooseLocation {
                page.addChild(Self.labeled("", LogPaneAUI.row([chooseLocationButton, AUISpacer()])))
            }
            formControl.selectedIndex = wizard.form == .folder ? 1 : 0
            page.addChild(Self.labeled("Form", LogPaneAUI.row([formControl, AUISpacer()])))
            page.addChild(Self.labeled("", formNote))
            page.addChild(createsLabel)
        case .options:
            pageTitle.text = "Options"
            optionFields = [:]
            optionSwitches = [:]
            for option in wizard.recipe?.definition.options ?? [] {
                page.addChild(optionControl(option))
            }
        }
        refresh()
    }

    /// The words on the page, from the wizard.
    func refresh() {
        let recipe = wizard.recipe
        recipeSummary.text = recipe?.definition.summary ?? ""
        recipeFiles.text = "Makes " + wizard.recipeFiles.joined(separator: ", ")
        #if os(iOS)
        locationLabel.text = "In Documents"
        #else
        locationLabel.text = (wizard.location.path as NSString).abbreviatingWithTildeInPath
        #endif
        refreshButtons()
    }

    /// "Creates Game.basproj, a zip", and what the form chosen is good for.
    private func refreshForm() {
        let made = wizard.recipe?.folderName(for: wizard.name) ?? wizard.name
        switch wizard.form {
        case .zip:
            createsLabel.text = "Creates \(made), a zip"
            formNote.text = "One file, to mail, copy, keep in iCloud or keep on an iPad."
        case .folder:
            createsLabel.text = "Creates \(made), a package (a folder)"
            formNote.text = "A folder named \(made), so git can see each file."
        }
    }

    private func refreshButtons() {
        nameProblem.text = wizard.page == .recipe ? "" : (wizard.nameProblem ?? "")
        refreshForm()
        backButton.isEnabled = wizard.canGoBack
        nextButton.title = wizard.isLastPage ? "Create" : "Next"
        nextButton.isEnabled = wizard.canGoOn
    }

    private func optionControl(_ option: BASICRecipe.Option) -> AUIView {
        let key = option.key
        if option.isCheckbox {
            let value = wizard.optionValues[key] ?? option.defaultValue ?? ""
            let toggle = AUISwitch(isOn: !value.isEmpty && value.lowercased() != "false") { [weak self] on in
                self?.wizard.optionValues[key] = on ? "true" : "false"
            }
            optionSwitches[key] = toggle
            return LogPaneAUI.row([AUILabel(option.prompt), AUISpacer(), toggle])
        }
        let field = AUITextField(wizard.optionValues[key] ?? option.defaultValue ?? "", placeholder: option.prompt)
        field.onChange = { [weak self] text in self?.wizard.optionValues[key] = text }
        optionFields[key] = field
        return Self.labeled(option.prompt, field)
    }

    /// A recipe in the list: its icon and its name. Its summary shows
    /// under the list when it is picked.
    private static func recipeRow(_ recipe: BASICRecipe) -> AUIView {
        let name = AUILabel(recipe.definition.name)
        name.font = .headline
        let image = AUIImageView(AUIImage(systemSymbolName: recipe.definition.icon ?? "doc.text", accessibilityDescription: nil))
        image.minimumSize = CGSize(width: 18, height: 18)
        image.maximumSize = CGSize(width: 18, height: 18)
        let row = LogPaneAUI.row([image, name, AUISpacer()])
        row.padding = AUIEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        return row
    }

    private static func labeled(_ title: String, _ control: AUIView) -> AUIView {
        let label = AUILabel(title)
        label.minimumSize = CGSize(width: 70, height: 0)
        return LogPaneAUI.row([label, control])
    }
}
