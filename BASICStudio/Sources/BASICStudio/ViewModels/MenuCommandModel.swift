//
//  MenuCommandModel.swift
//  BASICStudio
//
//  The menu bar as data, for either shell.
//

import Foundation

/// Studio's own menu items: titles, shortcuts, check marks, and what each does.
///
/// The SwiftUI shell places these with `CommandGroup`s, and the ActiveUI shell
/// builds an `AUIMenuBar` from the same lists. The standard menus (Edit's
/// clipboard items, Window, Help) are each framework's own and are not here.
///
/// ```text
///   BASICStudio  About BASICStudio                    about
///   File         New                   ⌘N             fileNew
///                New Project…          ⇧⌘N
///                Load…                 ⌘O             fileOpen
///                Save                  ⌘S             fileSave
///                Save As…              ⇧⌘S
///                ─────
///                Set Working Directory…
///   Edit         ─────                                editFind
///                Find                  ⌘F
///                Find and Replace      ⌥⌘F
///   Examples     one item per bundled demo            menus[0]
///   Console      ✓ Overwrite Mode      ⌃I             menus[1]
///                ✓ Show Graphics       ⇧⌘G
///   Debug        Show Debugger         ⇧⌘D            menus[2]
/// ```
struct MenuCommandModel: Equatable {
    /// What a menu item does. ``perform(_:on:)`` turns it into a model call.
    enum Action: Equatable {
        case about
        case newProgram, newProject
        case load, save, saveAs, setWorkingDirectory
        case example(BundledExample)
        case find, findAndReplace
        case overwriteMode, showGraphics
        case showDebugger
    }

    enum Modifier: Equatable {
        case command, shift, option, control
    }

    struct Shortcut: Equatable {
        /// Lowercase, as both frameworks take it.
        let key: Character
        let modifiers: [Modifier]
    }

    struct Item: Equatable {
        let title: String
        let shortcut: Shortcut?
        let action: Action
        /// nil for a command; true or false for a toggle, shown as a check.
        let isChecked: Bool?
    }

    enum Entry: Equatable {
        case item(Item)
        case separator
        /// A disabled line of text, such as "No Examples Found".
        case placeholder(String)
    }

    /// A menu of Studio's own, after the standard ones.
    struct Menu: Equatable {
        let title: String
        let entries: [Entry]
    }

    let about: Item
    /// File ▸ New and New Project…, in place of the standard New group:
    /// ⌘N used to open a second window over the same program (M10, ruled
    /// 2026-09-29).
    let fileNew: [Entry]
    /// File items that go where New's group ends.
    let fileOpen: [Entry]
    /// File items that replace the standard Save group.
    let fileSave: [Entry]
    /// Edit items that follow the text-editing group.
    let editFind: [Entry]
    /// Examples, Console and Debug, in that order.
    let menus: [Menu]

    @MainActor
    init(_ model: StudioModel) {
        about = Item(title: "About BASICStudio", shortcut: nil, action: .about, isChecked: nil)
        fileNew = [
            .item(Item(title: "New", shortcut: Shortcut(key: "n", modifiers: [.command]), action: .newProgram, isChecked: nil)),
            .item(Item(title: "New Project...", shortcut: Shortcut(key: "n", modifiers: [.command, .shift]), action: .newProject, isChecked: nil)),
        ]
        fileOpen = [
            .item(Item(title: "Load...", shortcut: Shortcut(key: "o", modifiers: [.command]), action: .load, isChecked: nil)),
        ]
        fileSave = [
            .item(Item(title: "Save", shortcut: Shortcut(key: "s", modifiers: [.command]), action: .save, isChecked: nil)),
            .item(Item(title: "Save As...", shortcut: Shortcut(key: "s", modifiers: [.command, .shift]), action: .saveAs, isChecked: nil)),
            .separator,
            .item(Item(title: "Set Working Directory...", shortcut: nil, action: .setWorkingDirectory, isChecked: nil)),
        ]
        editFind = [
            .separator,
            .item(Item(title: "Find", shortcut: Shortcut(key: "f", modifiers: [.command]), action: .find, isChecked: nil)),
            .item(Item(title: "Find and Replace", shortcut: Shortcut(key: "f", modifiers: [.command, .option]), action: .findAndReplace, isChecked: nil)),
        ]
        let examples: [Entry] = model.bundledExamples.isEmpty
            ? [.placeholder("No Examples Found")]
            : model.bundledExamples.map { .item(Item(title: $0.menuTitle, shortcut: nil, action: .example($0), isChecked: nil)) }
        menus = [
            Menu(title: "Examples", entries: examples),
            Menu(title: "Console", entries: [
                .item(Item(title: "Overwrite Mode", shortcut: Shortcut(key: "i", modifiers: [.control]), action: .overwriteMode, isChecked: Self.isChecked(.overwriteMode, in: model))),
                .item(Item(title: "Show Graphics", shortcut: Shortcut(key: "g", modifiers: [.command, .shift]), action: .showGraphics, isChecked: Self.isChecked(.showGraphics, in: model))),
            ]),
            Menu(title: "Debug", entries: [
                .item(Item(title: "Show Debugger", shortcut: Shortcut(key: "d", modifiers: [.command, .shift]), action: .showDebugger, isChecked: nil)),
            ]),
        ]
    }

    /// A toggle's state, read live; nil for a command.
    @MainActor
    static func isChecked(_ action: Action, in model: StudioModel) -> Bool? {
        switch action {
        case .overwriteMode: return model.isConsoleOverwriteMode
        case .showGraphics: return model.areGraphicsLayersVisible
        default: return nil
        }
    }

    /// Does what the menu item does. A toggle flips its current state.
    @MainActor
    static func perform(_ action: Action, on model: StudioModel) {
        switch action {
        case .about: StudioAbout.show()
        case .newProgram: model.newProgramFromMenu()
        case .newProject: model.newProjectFromMenu()
        case .load: model.loadProgramFromMenu()
        case .save: model.saveProgramFromMenu()
        case .saveAs: model.saveProgramAsFromMenu()
        case .setWorkingDirectory: model.setWorkingDirectoryFromMenu()
        case .example(let example): model.loadBundledExample(example)
        case .find: model.showFind()
        case .findAndReplace: model.showFindAndReplace()
        case .overwriteMode: model.setConsoleOverwriteMode(!model.isConsoleOverwriteMode)
        case .showGraphics: model.setGraphicsLayersVisible(!model.areGraphicsLayersVisible)
        case .showDebugger: model.openDebugger()
        }
    }
}
