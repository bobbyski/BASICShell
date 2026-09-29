//
//  StudioShellModel.swift
//  BASICStudio
//
//  The window around the panes, for either shell: toolbar, command bar,
//  pane routing and the inspector's width.
//

import CoreGraphics
import Foundation

/// The window's chrome as values.
///
/// Every toolbar button's symbol, help, enabled state and tint; the two
/// toolbar menus; which pane and inspector show; and the inspector width's
/// limits. ``perform(_:on:)`` is the one place a command becomes a model call,
/// so both shells' buttons do exactly the same thing.
///
/// ```text
///   ▶ ⚡ ■ │ ⌨︎ ✎ 🐞 📖 ☰ ⌨ 👁 # 🔍 🎨Theme▾ ▭Size▾      toolbar, themeMenu, screenSizeMenu
///   ┌──────── main pane ────────┐║┌─ inspector ─┐      mainPane, inspector
///   │  (min 420)                │║│ (min 260)   │      clampedInspectorWidth
///   └───────────────────────────┘║└─────────────┘
///   Run JIT List New [ immediate command ] Submit      showsCommandBar
/// ```
struct StudioShellModel: Equatable {
    /// A toolbar command. The order here is the toolbar's order.
    enum Command: CaseIterable, Equatable {
        case run, jit, stop
        case console, editor, debug, docs, logs, commandBar, graphics, gutter, find
    }

    /// What a button's color says. Each shell maps these to its own colors.
    enum Tint: Equatable {
        /// The ordinary label color.
        case normal
        /// Grayed: this command's work is already underway.
        case dimmed
        /// Blue: this pane, inspector or option is showing.
        case selected
        /// Red: Stop while something runs; the graphics layers hidden.
        case alert
        /// Green: the graphics layers showing.
        case on
    }

    struct Button: Equatable {
        let command: Command
        /// An SF Symbol name.
        let symbol: String
        let help: String
        let isEnabled: Bool
        let tint: Tint
    }

    /// A toolbar pull-down: a label, and one checkable item per choice.
    struct Menu: Equatable {
        let label: String
        let symbol: String
        let help: String
        let items: [Item]
    }

    struct Item: Equatable {
        let title: String
        let isChecked: Bool
    }

    static let minimumMainWidth: CGFloat = 420
    static let minimumInspectorWidth: CGFloat = 260
    static let defaultInspectorWidth: CGFloat = 360
    /// The window's smallest size.
    static let minimumWindowSize = CGSize(width: 760, height: 520)

    let toolbar: [Button]
    /// A divider follows this command in the toolbar.
    static let dividerAfter: Command = .stop
    let themeMenu: Menu
    let screenSizeMenu: Menu
    let mainPane: StudioPane
    let inspector: InspectorPane?
    let showsCommandBar: Bool
    /// The command bar's JIT button; Run, List, New and Submit are always on.
    let isCommandBarJITEnabled: Bool

    @MainActor
    init(_ model: StudioModel) {
        let running = model.isProgramRunning
        let anyRunning = model.isProgramRunning || model.isJITRunning
        func showing(_ isShowing: Bool) -> Tint { isShowing ? .selected : .normal }
        toolbar = Command.allCases.map { command in
            switch command {
            case .run:
                return Button(command: command, symbol: "play.fill", help: "Run", isEnabled: !anyRunning, tint: running ? .dimmed : .normal)
            case .jit:
                return Button(command: command, symbol: "bolt.fill", help: "Compile, then run — no debugger on this path", isEnabled: !anyRunning, tint: anyRunning ? .dimmed : .normal)
            case .stop:
                return Button(command: command, symbol: "stop.fill", help: "Stop", isEnabled: anyRunning, tint: anyRunning ? .alert : .dimmed)
            case .console:
                return Button(command: command, symbol: "terminal", help: "Console", isEnabled: true, tint: showing(model.selectedPane == .console))
            case .editor:
                return Button(command: command, symbol: "square.and.pencil", help: "Editor", isEnabled: true, tint: showing(model.selectedPane == .editor))
            case .debug:
                return Button(command: command, symbol: "ladybug", help: "Debug", isEnabled: true, tint: showing(model.inspectorPane == .debug))
            case .docs:
                return Button(command: command, symbol: "book", help: "Documentation", isEnabled: true, tint: showing(model.inspectorPane == .docs))
            case .logs:
                return Button(command: command, symbol: "list.bullet.rectangle", help: "Log", isEnabled: true, tint: showing(model.inspectorPane == .logs))
            case .commandBar:
                return Button(command: command, symbol: "keyboard", help: "Command Bar", isEnabled: true, tint: showing(model.isCommandBarVisible))
            case .graphics:
                let visible = model.areGraphicsLayersVisible
                return Button(command: command, symbol: visible ? "eye.fill" : "eye.slash.fill", help: visible ? "Graphics Visible" : "Graphics Hidden", isEnabled: true, tint: visible ? .on : .alert)
            case .gutter:
                return Button(command: command, symbol: "list.number", help: "Editor Line Numbers", isEnabled: true, tint: showing(model.isEditorGutterVisible))
            case .find:
                return Button(command: command, symbol: "magnifyingglass", help: "Find", isEnabled: true, tint: .normal)
            }
        }
        themeMenu = Menu(
            label: model.editorTheme.label,
            symbol: "paintpalette",
            help: "Editor Theme",
            items: EditorTheme.allCases.map { Item(title: $0.label, isChecked: $0 == model.editorTheme) }
        )
        screenSizeMenu = Menu(
            label: model.terminalScreenSize.label,
            symbol: "rectangle.inset.filled",
            help: "Screen Size",
            items: TerminalScreenSize.allCases.map { Item(title: $0.label, isChecked: $0 == model.terminalScreenSize) }
        )
        mainPane = model.selectedPane
        inspector = model.inspectorPane
        showsCommandBar = model.isCommandBarVisible
        isCommandBarJITEnabled = !anyRunning
    }

    /// The button for `command`.
    func button(_ command: Command) -> Button {
        toolbar.first { $0.command == command }!
    }

    /// Does what the toolbar button does.
    @MainActor
    static func perform(_ command: Command, on model: StudioModel) {
        switch command {
        case .run: model.runEditorProgram()
        case .jit: model.jitEditorProgram()
        case .stop: model.stopProgram()
        case .console: model.selectedPane = .console
        case .editor: model.selectedPane = .editor
        case .debug: model.toggleInspector(.debug)
        case .docs: model.toggleInspector(.docs)
        case .logs: model.toggleInspector(.logs)
        case .commandBar: model.isCommandBarVisible.toggle()
        case .graphics: model.toggleGraphicsLayersVisible()
        case .gutter: model.isEditorGutterVisible.toggle()
        case .find: model.showFind()
        }
    }

    /// Picks the theme menu's `index`th item.
    @MainActor
    static func chooseTheme(_ index: Int, on model: StudioModel) {
        model.editorTheme = EditorTheme.allCases[index]
    }

    /// Picks the screen-size menu's `index`th item.
    @MainActor
    static func chooseScreenSize(_ index: Int, on model: StudioModel) {
        model.terminalScreenSize = TerminalScreenSize.allCases[index]
    }

    /// The inspector's width as drawn: at least 260, and never so wide the
    /// main pane drops under 420.
    static func clampedInspectorWidth(_ width: CGFloat, availableWidth: CGFloat) -> CGFloat {
        min(max(width, minimumInspectorWidth), max(minimumInspectorWidth, availableWidth - minimumMainWidth))
    }

    /// The width after dragging the divider `translation` points from where a
    /// drag began at `startWidth`. Dragging left widens the inspector.
    static func draggedInspectorWidth(startWidth: CGFloat, translation: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let maximumWidth = max(minimumInspectorWidth, availableWidth - minimumMainWidth)
        return min(max(startWidth - translation, minimumInspectorWidth), maximumWidth)
    }
}
