//
//  StudioActiveUIShell.swift
//  BASICStudio
//
//  The ActiveUI front end: `BASICStudio --activeui`.
//

import ActiveUI
import AppKit
import Combine
import Foundation

/// BASICStudio's second shell, over the same ``StudioModel`` as the SwiftUI
/// one (Documents/ACTIVEUI_TRANSITION.md, P2).
///
/// It draws nothing of its own. Its state comes from the P1 projections, and
/// the two native views are the SwiftUI shell's own: the console is
/// `AIBasicTerminalContainerView` and the editor is `MonacoEditorController`'s
/// web view, each wrapped in an `AUINativeHost`.
///
/// ```text
///   model.objectWillChange ─► scheduleRefresh ─► (next turn) refresh()
///                                                  │ each part compares with
///                                                  │ what it last drew, and
///                                                  ▼ redraws only that
///   toolbar · command bar · console · editor · window title
/// ```
///
/// **Retained, not reactive.** ActiveUI does not re-render, so the shell
/// subscribes to `objectWillChange`, the signal the SwiftUI shell also runs
/// on, and refreshes on the next turn of the main queue, when the change has
/// landed (C8). **The reader checks** (C11): each part keeps what it last drew
/// and compares, so a refresh from anywhere is safe and costs nothing when
/// nothing changed.
///
/// **Nothing here is `async`** (§9.4). Every entry point is a plain
/// main-actor call, so the interpreter's synchronous thread can reach it with
/// one main-queue hop when P6 needs to.
@MainActor
final class StudioActiveUIShell {
    let model: StudioModel
    /// The window's content.
    let root: AUIView
    let menuBar: AUIMenuBar
    let toolbar: AUIToolbar

    let console = AIBasicTerminalContainerView()
    let editor = MonacoEditorController()
    let consoleHost: AUINativeHost
    let editorHost: AUINativeHost
    let commandBar: AUIStack
    let commandField: AUITextField
    /// The main pane, the drag handle, and the inspector.
    let layout: InspectorLayout
    let logPane: LogPaneAUI
    let docsPane: DocsPaneAUI
    let debugPane: DebugPaneAUI
    let settings: SettingsAUI

    let toolbarItems: [StudioShellModel.Command: AUIToolbarItem]
    let themeItem: AUIToolbarItem
    let screenSizeItem: AUIToolbarItem
    private(set) var commandBarJIT: AUIButton!

    // What was last drawn. See the type's note on the reader checking.
    private var drawnShell: StudioShellModel?
    private var drawnTitle: String?
    private var observation: AnyCancellable?
    private var isRefreshScheduled = false
    /// How many refreshes have run; tests watch it.
    private(set) var refreshCount = 0

    init(model: StudioModel) {
        self.model = model

        console.attach(to: model)
        consoleHost = AUINativeHost(console)
        editorHost = AUINativeHost(editor.makeWebView())

        // Both panes stay alive, and switching shows one and hides the other.
        // The SwiftUI shell rebuilds the native view on every switch.
        let mainArea = AUIZStack(alignment: .fill)
        mainArea.addChild(consoleHost)
        mainArea.addChild(editorHost)
        mainArea.flexibility = .both()
        mainArea.padding = AUIEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)

        commandField = AUITextField("", placeholder: "Immediate command")
        commandField.flexibility = .horizontal()
        commandBar = AUIStack(.horizontal, spacing: 8, alignment: .center)
        commandBar.wraps = false
        commandBar.padding = AUIEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)

        // The inspectors, one showing at a time. Each keeps its state while
        // hidden, as the SwiftUI shell's do not.
        logPane = LogPaneAUI(model: model)
        docsPane = DocsPaneAUI()
        debugPane = DebugPaneAUI(model: model)
        let inspectors = AUIZStack(alignment: .fill)
        inspectors.addChild(debugPane.root)
        inspectors.addChild(logPane.root)
        inspectors.addChild(docsPane.root)
        layout = InspectorLayout(main: mainArea, inspector: inspectors)

        let body = AUIStack(.vertical, spacing: 0, alignment: .fill)
        body.wraps = false
        body.addChild(layout)
        body.addChild(commandBar)
        body.minimumSize = StudioShellModel.minimumWindowSize
        root = body

        let settings = SettingsAUI(model: model)
        self.settings = settings
        menuBar = Self.makeMenuBar(model: model, onSettings: { [weak settings] in settings?.show() })
        let parts = Self.makeToolbar(model: model)
        toolbar = parts.toolbar
        toolbarItems = parts.buttons
        themeItem = parts.theme
        screenSizeItem = parts.screenSize

        buildCommandBar()
        editor.onTextChange = { [weak model] text in model?.programText = text }

        observation = model.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        refresh()
    }

    // MARK: Running

    /// Puts up the window and runs the app. Returns only when the app quits.
    static func run(launch: StudioLaunchOptions) {
        StudioFonts.registerBundledFonts()
        let shell = StudioActiveUIShell(model: StudioModel(launch: launch))
        // The app keeps the views; this keeps the shell, and with it the
        // subscription that refreshes them. `run` does not return, so a
        // local alone could be released as soon as it starts.
        running = shell
        AUIApplication.onLaunch = {
            shell.refresh()
            shell.model.runStartupProgramIfNeeded()
        }
        _ = AUIApplication.run(
            shell.root,
            placement: .fill,
            menuBar: shell.menuBar,
            toolbar: shell.toolbar,
            title: shell.model.windowTitle,
            contentSize: CGSize(width: 1100, height: 720)
        )
    }

    /// The shell `run` started, for the life of the process.
    private(set) static var running: StudioActiveUIShell?

    /// Runs `body` on the main thread and waits for it: how a synchronous
    /// caller on another thread, such as the interpreter's, reaches the shell
    /// (ACTIVEUI_TRANSITION.md §9.4). On the main thread it simply runs.
    ///
    /// The caller blocks until the main thread gets to it, so the main thread
    /// must never be waiting on that caller. That is the rule `StudioModel`'s
    /// `runOnMainSync` already lives by.
    nonisolated static func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(body)
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated(body)
        }
    }

    // MARK: Refreshing

    /// Asks for one refresh on the next turn of the main queue, however many
    /// changes arrive before then. The next turn is when a change announced by
    /// `objectWillChange` has actually landed.
    func scheduleRefresh() {
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isRefreshScheduled = false
                self.refresh()
            }
        }
    }

    /// Brings every part up to the model. Safe to call at any time.
    func refresh() {
        refreshCount += 1
        let shell = StudioShellModel(model)
        if shell != drawnShell {
            draw(shell, over: drawnShell)
            drawnShell = shell
        }
        // Both views compare with what they last drew, so these are cheap
        // when nothing changed.
        console.render(ConsoleRenderInput(model))
        editor.sync(.mainEditor(model))
        settings.refresh()
        // Only the inspector on screen reads the model.
        switch model.inspectorPane {
        case .logs: logPane.refresh()
        case .docs: docsPane.refresh()
        case .debug: debugPane.refresh()
        case nil: break
        }
        if commandField.text != model.command {
            commandField.text = model.command
        }
        if model.windowTitle != drawnTitle {
            AUIApplication.mainWindowTitle = model.windowTitle
            drawnTitle = model.windowTitle
        }
    }

    private func draw(_ shell: StudioShellModel, over old: StudioShellModel?) {
        for button in shell.toolbar where old?.button(button.command) != button {
            guard let item = toolbarItems[button.command] else { continue }
            item.isEnabled = button.isEnabled
            item.tooltip = button.help
            item.image = Self.glyph(button.symbol, tint: button.tint)
        }
        if shell.themeMenu.label != old?.themeMenu.label {
            themeItem.label = shell.themeMenu.label
        }
        if shell.screenSizeMenu.label != old?.screenSizeMenu.label {
            screenSizeItem.label = shell.screenSizeMenu.label
        }
        layout.showsInspector = shell.inspector != nil
        logPane.root.isHidden = shell.inspector != .logs
        docsPane.root.isHidden = shell.inspector != .docs
        debugPane.root.isHidden = shell.inspector != .debug
        consoleHost.isHidden = shell.mainPane != .console
        editorHost.isHidden = shell.mainPane != .editor
        commandBar.isHidden = !shell.showsCommandBar
        commandBarJIT.isEnabled = shell.isCommandBarJITEnabled
        root.invalidateLayout()
    }

    // MARK: Building

    /// The toolbar, from ``StudioShellModel``: its buttons in order, a space
    /// after Stop, then the theme and screen-size pull-downs. Every action
    /// goes through `StudioShellModel.perform`, as the SwiftUI shell's do.
    static func makeToolbar(model: StudioModel) -> (
        toolbar: AUIToolbar,
        buttons: [StudioShellModel.Command: AUIToolbarItem],
        theme: AUIToolbarItem,
        screenSize: AUIToolbarItem
    ) {
        let shell = StudioShellModel(model)
        var buttons: [StudioShellModel.Command: AUIToolbarItem] = [:]
        var items: [AUIToolbarItem] = []
        for button in shell.toolbar {
            let item = AUIToolbarItem(label: button.help) { [weak model] in
                guard let model else { return }
                StudioShellModel.perform(button.command, on: model)
            }
            buttons[button.command] = item
            items.append(item)
            if button.command == StudioShellModel.dividerAfter {
                items.append(.space())
            }
        }
        let theme = AUIToolbarItem(label: shell.themeMenu.label, systemSymbol: shell.themeMenu.symbol, menu: pullDown(model: model) {
            (StudioShellModel($0).themeMenu, StudioShellModel.chooseTheme)
        })
        theme.tooltip = shell.themeMenu.help
        let screenSize = AUIToolbarItem(label: shell.screenSizeMenu.label, systemSymbol: shell.screenSizeMenu.symbol, menu: pullDown(model: model) {
            (StudioShellModel($0).screenSizeMenu, StudioShellModel.chooseScreenSize)
        })
        screenSize.tooltip = shell.screenSizeMenu.help
        let toolbar = AUIToolbar(items: items + [theme, screenSize])
        toolbar.displayMode = .iconOnly
        return (toolbar, buttons, theme, screenSize)
    }

    /// A toolbar pull-down whose items are rebuilt each time it opens, from
    /// the projection, with the current choice checked.
    private static func pullDown(
        model: StudioModel,
        _ source: @escaping @MainActor (StudioModel) -> (StudioShellModel.Menu, @MainActor (Int, StudioModel) -> Void)
    ) -> AUIMenu {
        AUIMenu("", items: []).dynamicItems { [weak model] in
            MainActor.assumeIsolated {
                guard let model else { return [] }
                let (menu, choose) = source(model)
                return menu.items.enumerated().map { index, entry in
                    AUIMenuItem(entry.title, action: { [weak model] in
                        guard let model else { return }
                        choose(index, model)
                    }).checked { entry.isChecked }
                }
            }
        }
    }

    private func buildCommandBar() {
        let run = AUIButton("Run") { [weak self] in self?.model.runEditorProgram() }
        run.keyEquivalent = AUIKeyboardShortcut("r", modifiers: .command)
        commandBarJIT = AUIButton("JIT") { [weak self] in self?.model.jitEditorProgram() }
        commandBarJIT.keyEquivalent = AUIKeyboardShortcut("r", modifiers: [.command, .shift])
        commandBarJIT.tooltip = "Compile, then run"
        let list = AUIButton("List") { [weak self] in self?.model.listProgram() }
        let new = AUIButton("New") { [weak self] in self?.model.clearProgram() }
        let submit = AUIButton("Submit") { [weak self] in self?.submitCommand() }
        commandField.onChange = { [weak self] text in self?.model.command = text }
        commandField.onSubmit = { [weak self] _ in self?.submitCommand() }
        for view in [run, commandBarJIT!, list, new, commandField, submit] as [AUIView] {
            commandBar.addChild(view)
        }
    }

    private func submitCommand() {
        model.command = commandField.text
        model.submitCommand()
        commandField.text = model.command
    }

    /// An SF Symbol drawn in the tint's color, as the SwiftUI toolbar does.
    static func glyph(_ symbol: String, tint: StudioShellModel.Tint) -> NSImage? {
        let color: NSColor = switch tint {
        case .normal: .labelColor
        case .dimmed: .secondaryLabelColor
        case .selected: .systemBlue
        case .alert: .systemRed
        case .on: .systemGreen
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
    }

    // MARK: The menu bar

    /// The menu bar, from ``MenuCommandModel``, in the SwiftUI shell's order:
    /// the app, File, Edit, View, Examples, Console, Debug, Window, Help.
    static func makeMenuBar(model: StudioModel, onSettings: (() -> Void)? = nil) -> AUIMenuBar {
        let commands = MenuCommandModel(model)
        let file = AUIMenu("File", items: items(commands.fileOpen + commands.fileSave, model: model) + [
            .separator(),
            .command(.closeDocument, title: "Close", shortcut: .command("w")),
        ])
        let edit = AUIMenu("Edit", items: [
            .command(.undo),
            .command(.redo),
            .separator(),
            .command(.cut),
            .command(.copy),
            .command(.paste),
            .command(.delete),
            .command(.selectAll),
        ] + items(commands.editFind, model: model))
        var menus: [AUIMenu] = [
            AUIMenu.application(name: "BASICStudio", about: { MenuCommandModel.perform(.about, on: model) }, settings: onSettings),
            file,
            edit,
            AUIMenu.standardView(),
        ]
        menus += commands.menus.map { AUIMenu($0.title, items: items($0.entries, model: model)) }
        menus += [AUIMenu.standardWindow(), AUIMenu.standardHelp(appName: "BASICStudio")]
        return AUIMenuBar(menus: menus)
    }

    /// ActiveUI menu items for `entries`. A toggle's check is read live, each
    /// time its menu opens.
    static func items(_ entries: [MenuCommandModel.Entry], model: StudioModel) -> [AUIMenuItem] {
        entries.map { entry in
            switch entry {
            case .separator:
                return .separator()
            case .placeholder(let text):
                let item = AUIMenuItem(text, action: {})
                item.isEnabled = false
                return item
            case .item(let command):
                let item = AUIMenuItem(command.title, shortcut: command.shortcut.map(shortcut)) { [weak model] in
                    guard let model else { return }
                    MenuCommandModel.perform(command.action, on: model)
                }
                if command.isChecked != nil {
                    return item.checked { [weak model] in
                        guard let model else { return false }
                        return MainActor.assumeIsolated { MenuCommandModel.isChecked(command.action, in: model) ?? false }
                    }
                }
                return item
            }
        }
    }

    static func shortcut(_ shortcut: MenuCommandModel.Shortcut) -> AUIKeyboardShortcut {
        var modifiers: AUIKeyboardShortcut.Modifiers = []
        for modifier in shortcut.modifiers {
            switch modifier {
            case .command: modifiers.insert(.command)
            case .shift: modifiers.insert(.shift)
            case .option: modifiers.insert(.option)
            case .control: modifiers.insert(.control)
            }
        }
        return AUIKeyboardShortcut(shortcut.key, modifiers: modifiers)
    }
}
