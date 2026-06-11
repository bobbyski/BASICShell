import BASICCore
import AppKit
import GameController
import MarkdownUI
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import VectorTerminalSDK
import WebKit

@main
struct BASICStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = StudioModel()

    init() {
        StudioFonts.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup("AIBasic Studio") {
            StudioView(model: model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Load...") {
                    model.loadProgramFromMenu()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    model.saveProgramFromMenu()
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button("Save As...") {
                    model.saveProgramAsFromMenu()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("Set Working Directory...") {
                    model.setWorkingDirectoryFromMenu()
                }
            }

            CommandMenu("Examples") {
                if model.bundledExamples.isEmpty {
                    Text("No Examples Found")
                } else {
                    ForEach(model.bundledExamples) { example in
                        Button(example.menuTitle) {
                            model.loadBundledExample(example)
                        }
                    }
                }
            }

            CommandGroup(after: .textEditing) {
                Divider()

                Button("Find") {
                    model.showFind()
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("Find and Replace") {
                    model.showFindAndReplace()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
            }

            CommandMenu("Console") {
                Toggle("Overwrite Mode", isOn: Binding(
                    get: { model.isConsoleOverwriteMode },
                    set: { model.setConsoleOverwriteMode($0) }
                ))
                .keyboardShortcut("i", modifiers: [.control])
            }

            CommandMenu("Debug") {
                Button("Show Debugger") {
                    model.openDebugger()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(model: model)
                .frame(width: 760, height: 520)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
