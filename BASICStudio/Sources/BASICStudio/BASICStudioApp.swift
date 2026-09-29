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
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
