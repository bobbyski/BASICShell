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
/// ```
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

    /// Selects the ActiveUI shell.
    static let activeUIFlag = "--activeui"
    /// Selects the SwiftUI shell, which is also the default.
    static let swiftUIFlag = "--swiftui"

    /// This process's options.
    static let current = parse(Array(CommandLine.arguments.dropFirst()))

    /// Default settings, nothing saved, no program: a model for a test.
    static let headless = StudioLaunchOptions(persistsSettings: false)

    /// Reads `arguments`, which do not include the executable's own path.
    /// The last shell flag wins.
    static func parse(_ arguments: [String]) -> StudioLaunchOptions {
        var options = StudioLaunchOptions()
        var remaining: [String] = []
        for argument in arguments {
            switch argument {
            case activeUIFlag: options.shell = .activeUI
            case swiftUIFlag: options.shell = .swiftUI
            default: remaining.append(argument)
            }
        }
        options.programPath = remaining.first
        return options
    }
}
