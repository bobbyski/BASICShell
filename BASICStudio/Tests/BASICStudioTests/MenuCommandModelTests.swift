//
//  MenuCommandModelTests.swift
//  BASICStudioTests
//
//  P1 unit 5: the menu bar as data.
//

import Foundation
import Testing
@testable import BASICStudio

@Suite("MenuCommandModel")
@MainActor
struct MenuCommandModelTests {
    private func items(_ entries: [MenuCommandModel.Entry]) -> [MenuCommandModel.Item] {
        entries.compactMap { if case .item(let item) = $0 { item } else { nil } }
    }

    /// Every item, the ones in submenus too.
    private func allItems(_ entries: [MenuCommandModel.Entry]) -> [MenuCommandModel.Item] {
        entries.flatMap { entry -> [MenuCommandModel.Item] in
            switch entry {
            case .item(let item): [item]
            case .submenu(_, let inner): allItems(inner)
            default: []
            }
        }
    }

    private func describe(_ shortcut: MenuCommandModel.Shortcut?) -> String {
        guard let shortcut else { return "" }
        let symbols: [MenuCommandModel.Modifier: String] = [.control: "⌃", .option: "⌥", .shift: "⇧", .command: "⌘"]
        return [MenuCommandModel.Modifier.control, .option, .shift, .command]
            .filter(shortcut.modifiers.contains)
            .compactMap { symbols[$0] }
            .joined() + shortcut.key.uppercased()
    }

    @Test("W5 M6 M7 M8 M9 · The File items, their order and shortcuts")
    func fileItems() {
        let menu = MenuCommandModel(StudioHarness().model)
        #expect(menu.about.title == "About BASICStudio" && menu.about.action == .about)
        #expect(items(menu.fileOpen).map { "\($0.title) \(describe($0.shortcut))" } == ["Load... ⌘O"])
        #expect(menu.fileSave.count == 4)
        #expect(menu.fileSave[2] == .separator)
        #expect(items(menu.fileSave).map { "\($0.title) \(describe($0.shortcut))" } == [
            "Save ⌘S", "Save As... ⇧⌘S", "Set Working Directory... ",
        ])
    }

    @Test("M10 · File ▸ New ⌘N and New Project ⇧⌘N, in place of a second window")
    func fileNew() {
        let menu = MenuCommandModel(StudioHarness().model)
        #expect(items(menu.fileNew).map { "\($0.title) \(describe($0.shortcut))" } == ["New ⌘N", "New Project... ⇧⌘N"])
        #expect(items(menu.fileNew).map(\.action) == [.newProgram, .newProject])
    }

    @Test("M3 · Edit gets a divider, then Find ⌘F and Find and Replace ⌥⌘F")
    func editItems() {
        let menu = MenuCommandModel(StudioHarness().model)
        #expect(menu.editFind.first == .separator)
        #expect(items(menu.editFind).map { "\($0.title) \(describe($0.shortcut))" } == ["Find ⌘F", "Find and Replace ⌥⌘F"])
    }

    @Test("M1 M4 M5 · Examples, Console and Debug, in that order")
    func ownMenus() {
        let model = StudioHarness().model
        let menu = MenuCommandModel(model)
        #expect(menu.menus.map(\.title) == ["Examples", "Console", "Debug"])
        #expect(allItems(menu.menus[0].entries).count == model.bundledExamples.count)
        #expect(items(menu.menus[1].entries).map { "\($0.title) \(describe($0.shortcut))" } == ["Overwrite Mode ⌃I", "Show Graphics ⇧⌘G"])
        #expect(items(menu.menus[2].entries).map { "\($0.title) \(describe($0.shortcut))" } == ["Show Debugger ⇧⌘D"])
    }

    @Test("M1 · Examples is the demos tree: a submenu per folder, then the folder's programs")
    func exampleTree() {
        let model = StudioHarness().model
        let submenus = MenuCommandModel(model).menus[0].entries.compactMap { entry -> String? in
            if case .submenu(let title, _) = entry { title } else { nil }
        }
        #expect(submenus == model.exampleTree.folders.map(\.title))
        #expect(submenus.first == "Games")
    }

    @Test("M1 · A folder inside a category is a submenu inside its submenu")
    func nestedExamples() {
        let tree = BundledExampleFolder.tree(["games/arcade/pong", "games/arcade/breakout/main", "games/roids", "loose"].map(BundledExample.init(path:)))
        func describe(_ entries: [MenuCommandModel.Entry]) -> [String] {
            entries.map { entry in
                switch entry {
                case .item(let item): item.title
                case .submenu(let title, let inner): "\(title) [\(describe(inner).joined(separator: ", "))]"
                default: "?"
                }
            }
        }
        #expect(describe(MenuCommandModel.exampleEntries(tree)) == ["Games [Arcade [Breakout, Pong], Roids]", "Loose"])
    }

    @Test("M4 · The Console toggles are checked from the model, and flip it")
    func toggles() {
        let model = StudioHarness().model
        var console = items(MenuCommandModel(model).menus[1].entries)
        #expect(console.map(\.isChecked) == [false, true])
        MenuCommandModel.perform(.overwriteMode, on: model)
        MenuCommandModel.perform(.showGraphics, on: model)
        console = items(MenuCommandModel(model).menus[1].entries)
        #expect(console.map(\.isChecked) == [true, false])
        #expect(model.isConsoleOverwriteMode && !model.areGraphicsLayersVisible)
    }

    @Test("Commands carry no check state")
    func commandsAreNotToggles() {
        let menu = MenuCommandModel(StudioHarness().model)
        let commands = items(menu.fileOpen + menu.fileSave + menu.editFind + menu.menus[2].entries) + allItems(menu.menus[0].entries)
        #expect(commands.allSatisfy { $0.isChecked == nil })
    }

    @Test("M2 M3 M5 · Performing an item makes the same model call the old menu did")
    func perform() throws {
        let model = StudioHarness().model
        let example = try #require(model.bundledExamples.first)
        MenuCommandModel.perform(.example(example), on: model)
        #expect(!model.programText.isEmpty && model.selectedPane == .editor)
        MenuCommandModel.perform(.findAndReplace, on: model)
        #expect(model.editorReplaceRequest == 1)
        MenuCommandModel.perform(.showDebugger, on: model)
        #expect(model.inspectorPane == .debug)
    }
}
