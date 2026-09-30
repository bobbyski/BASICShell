//
//  StudioLaunchOptions.swift
//  BASICStudio
//
//  What Studio was asked to do at launch: which shell, and which program.
//

import Foundation

/// The command line, read once.
///
/// ```text
///   BASICStudio [--activeui | --swiftui] [program.bas]
///   BASICStudio --walk [--pane console|editor] [--inspector debug|docs|logs]
///               [--command-bar] [--breakpoint N]… [--settings general|font|console]
///               [--project DIR] [--theme NAME] [program.bas]
/// ```
///
/// `--walk` is for the side-by-side parity walk (STUDIO_FEATURES.md, Level 4):
/// it opens either shell in a stated state, on default settings, saving
/// nothing and leaving the focus alone, so the same flags photograph both
/// shells alike. Its program may come from `BASICSTUDIO_PROGRAM` instead of
/// the command line: given a file path there, AppKit takes it as a document
/// to open, and the SwiftUI shell then opens no window at all (found
/// 2026-09-29; STUDIO_FEATURES.md W3).
///
/// The shell flags are removed first, and what is left is read exactly as it
/// always was: the first argument, if it names a readable file, is loaded and
/// run. Any other argument (Xcode's `-NSDocumentRevisionsDebugMode YES`, say)
/// is tried as a path, fails to load, and is ignored, as before.
///
/// Tests build a model from ``headless`` instead, which neither reads nor
/// writes the saved settings in Application Support.
struct StudioLaunchOptions: Equatable, Sendable {
    /// The two front ends over the one ``StudioModel``, during the ActiveUI
    /// transition (Documents/ACTIVEUI_TRANSITION.md, P2).
    enum Shell: Equatable, Sendable {
        case swiftUI
        case activeUI
    }

    /// Which front end to put up.
    var shell: Shell = .swiftUI
    /// A program to load into the editor and run once the window is up.
    var programPath: String?
    /// Whether settings come from, and go back to, Application Support.
    var persistsSettings = true
    /// The state to open in, for the parity walk; nil normally.
    var walk: Walk?

    /// What `--walk` and its flags ask for.
    struct Walk: Equatable, Sendable {
        var pane: StudioPane?
        var inspector: InspectorPane?
        var showsCommandBar = false
        /// Source lines to break on before the program runs.
        var breakpoints: [Int] = []
        /// A Settings tab to open: general, font or console.
        var settingsTab: String?
        var projectPath: String?
        /// An app theme for the ActiveUI shell (`StudioAppTheme`), by name.
        var theme: String?

        /// The Settings tab's position: general 0, font 1, console 2.
        var settingsTabIndex: Int? {
            switch settingsTab {
            case "general": 0
            case "font": 1
            case "console": 2
            default: nil
            }
        }
    }

    /// Selects the ActiveUI shell.
    static let activeUIFlag = "--activeui"
    /// Selects the SwiftUI shell, which is also the default.
    static let swiftUIFlag = "--swiftui"

    /// This process's options.
    static let current = parse(Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment)

    /// Default settings, nothing saved, no program: a model for a test.
    static let headless = StudioLaunchOptions(persistsSettings: false)

    /// Reads `arguments`, which do not include the executable's own path.
    /// The last shell flag wins.
    static func parse(_ arguments: [String], environment: [String: String] = [:]) -> StudioLaunchOptions {
        var options = StudioLaunchOptions()
        var remaining: [String] = []
        var walk = Walk()
        var isWalking = false
        var index = 0
        /// The flag's value, which is the next argument.
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case activeUIFlag: options.shell = .activeUI
            case swiftUIFlag: options.shell = .swiftUI
            case "--walk": isWalking = true
            case "--pane":
                switch value()?.lowercased() {
                case "editor": walk.pane = .editor
                case "console": walk.pane = .console
                default: break
                }
            case "--inspector":
                switch value()?.lowercased() {
                case "debug": walk.inspector = .debug
                case "docs": walk.inspector = .docs
                case "logs": walk.inspector = .logs
                default: break
                }
            case "--command-bar": walk.showsCommandBar = true
            case "--breakpoint": if let line = value().flatMap(Int.init) { walk.breakpoints.append(line) }
            case "--settings": walk.settingsTab = value()?.lowercased()
            case "--project": walk.projectPath = value()
            case "--theme": walk.theme = value()
            default: remaining.append(argument)
            }
            index += 1
        }
        options.programPath = remaining.first
        if isWalking {
            options.programPath = options.programPath ?? environment["BASICSTUDIO_PROGRAM"]
            options.walk = walk
            options.persistsSettings = false
        }
        return options
    }
}
