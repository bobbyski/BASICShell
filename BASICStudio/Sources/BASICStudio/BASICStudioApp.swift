import BASICCore
import AppKit
import GameController
import MarkdownUI
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import VectorTerminalSDK
import WebKit

/// The SwiftUI shell. ``StudioMain`` starts it unless `--activeui` is given.
struct BASICStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = StudioModel()

    init() {
        StudioFonts.registerBundledFonts()
    }

    var body: some Scene {
        // Studio's own items come from MenuCommandModel, which the ActiveUI
        // shell builds its menu bar from too; only the placement is SwiftUI's.
        let menu = MenuCommandModel(model)
        WindowGroup("BASICStudio") {
            StudioView(model: model)
                .frame(
                    minWidth: StudioShellModel.minimumWindowSize.width,
                    minHeight: StudioShellModel.minimumWindowSize.height
                )
                .navigationTitle(model.windowTitle)
        }
        .commands {
            // The stock item shows the app icon and nothing else; this one
            // shows the badge and says what BASICStudio is.
            CommandGroup(replacing: .appInfo) {
                menuItem(menu.about)
            }

            // ⌘N makes a new program, not a second window over this one.
            CommandGroup(replacing: .newItem) {
                menuEntries(menu.fileNew)
            }

            CommandGroup(after: .newItem) {
                menuEntries(menu.fileOpen)
            }

            CommandGroup(replacing: .saveItem) {
                menuEntries(menu.fileSave)
            }

            CommandMenu(menu.menus[0].title) {
                menuEntries(menu.menus[0].entries)
            }

            CommandGroup(after: .textEditing) {
                menuEntries(menu.editFind)
            }

            CommandMenu(menu.menus[1].title) {
                menuEntries(menu.menus[1].entries)
            }

            CommandMenu(menu.menus[2].title) {
                menuEntries(menu.menus[2].entries)
            }
        }

        Settings {
            SettingsView(model: model)
                .frame(width: SettingsViewModel.windowSize.width, height: SettingsViewModel.windowSize.height)
        }
    }

    @ViewBuilder
    private func menuEntries(_ entries: [MenuCommandModel.Entry]) -> some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .item(let item):
                menuItem(item)
            case .separator:
                Divider()
            case .placeholder(let text):
                Text(text)
            }
        }
    }

    @ViewBuilder
    private func menuItem(_ item: MenuCommandModel.Item) -> some View {
        if item.isChecked != nil {
            Toggle(item.title, isOn: Binding(
                get: { MenuCommandModel.isChecked(item.action, in: model) ?? false },
                set: { _ in MenuCommandModel.perform(item.action, on: model) }
            ))
            .menuShortcut(item.shortcut)
        } else {
            Button(item.title) {
                MenuCommandModel.perform(item.action, on: model)
            }
            .menuShortcut(item.shortcut)
        }
    }
}

private extension View {
    /// Applies a menu item's shortcut, if it has one.
    @ViewBuilder
    func menuShortcut(_ shortcut: MenuCommandModel.Shortcut?) -> some View {
        if let shortcut {
            keyboardShortcut(KeyEquivalent(shortcut.key), modifiers: EventModifiers(shortcut.modifiers))
        } else {
            self
        }
    }
}

private extension EventModifiers {
    init(_ modifiers: [MenuCommandModel.Modifier]) {
        self = []
        for modifier in modifiers {
            switch modifier {
            case .command: insert(.command)
            case .shift: insert(.shift)
            case .option: insert(.option)
            case .control: insert(.control)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let walk = StudioLaunchOptions.current.walk else {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        // The parity walk photographs the window and must not keep the focus.
        // SwiftUI opens no window for an app that never activates, so it
        // activates for a moment, then hands the focus back to whatever had
        // it; the window stays up behind.
        let previous = NSWorkspace.shared.frontmostApplication
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if walk.settingsTab != nil {
            // Opened while the app is still active; an inactive one ignores it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previous.activate()
            }
        }
        // Windows arrive over the first seconds; each is put up as it does.
        for delay in stride(from: 1.0, through: 6.0, by: 0.5) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApplication.shared.windows.filter(\.canBecomeMain).forEach { $0.orderFrontRegardless() }
            }
        }
    }
}
