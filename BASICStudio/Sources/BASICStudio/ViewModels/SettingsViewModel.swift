//
//  SettingsViewModel.swift
//  BASICStudio
//
//  What the Settings window shows, for either shell.
//

import Foundation

/// The Settings window as values: its tabs, its ranges and its wording.
///
/// Almost all of Settings is already data, which is ActiveUI's point that
/// such screens "convert almost free": the ranges, the steps and the notes are
/// constants, and the values are the model's. The General tab is the prompt
/// editor, which has its own projection (P1 unit 7).
///
/// ```text
///   [ General ] [ Font ] [ Console ]             tabs
///   Font:  Font ▾ fontFamilies    Size ──●── 13   fontSizeRange, fontSizeText
///   Console:  Lines ──●── [−][+] 10000            scrollbackRange/Step, scrollbackText
/// ```
struct SettingsViewModel: Equatable {
    /// One tab of the window.
    struct Tab: Equatable {
        let title: String
        /// An SF Symbol name.
        let symbol: String
    }

    static let tabs = [
        Tab(title: "General", symbol: "gearshape"),
        Tab(title: "Font", symbol: "textformat"),
        Tab(title: "Console", symbol: "terminal"),
    ]

    /// The window's size in the SwiftUI shell's `Settings` scene.
    static let windowSize = (width: 760.0, height: 520.0)

    static let fontSectionTitle = "Editor And Console Font"
    static let fontSizeRange: ClosedRange<Double> = 10...24
    static let fontSizeStep = 1.0
    static let fontNote = "The selected font is used by Monaco and the SwiftTerm console. Prompt symbols need a Nerd Font or a font with matching glyph coverage."

    static let scrollbackSectionTitle = "Scrollback"
    static let graphicsSectionTitle = "Graphics"
    static let hidesGraphicsOnStopTitle = "Hide graphics when a program stops on a break or an error"
    static let showsGraphicsHiddenNoticeTitle = "Say so when they are hidden"
    static let hidesGraphicsOnStopNote = "So the error and the prompt can be read. RUN or CLS shows the graphics again; graphics you hid yourself stay hidden."
    static let scrollbackRange = StudioSettings.consoleScrollbackRange
    static let scrollbackStep = 100
    static let scrollbackNote = "Older console lines are discarded once the console passes this many lines. Lowering it reduces memory use and speeds up programs that print heavily, because the console re-reads its buffer on every update."

    /// Families offered first, in this order, whether installed or not.
    static let preferredFontFamilies = [StudioFonts.defaultFamily, "SF Mono", "Hack Nerd Font", "JetBrains Mono", "Menlo", "Monaco"]

    let fontFamily: String
    let fontSize: Double
    /// The size as the label beside the slider shows it: whole points.
    let fontSizeText: String
    let scrollbackLines: Int
    let scrollbackText: String

    @MainActor
    init(_ model: StudioModel) {
        fontFamily = model.fontFamily
        fontSize = model.fontSize
        fontSizeText = "\(Int(model.fontSize))"
        scrollbackLines = model.consoleScrollbackLines
        scrollbackText = "\(model.consoleScrollbackLines)"
    }

    /// The font picker's list: the preferred families first, then every
    /// installed family in Finder order, each once. `installed` is what the
    /// shell's font manager reports.
    static func fontFamilies(installed: [String]) -> [String] {
        let sorted = installed.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var result: [String] = []
        for family in preferredFontFamilies + sorted where !result.contains(family) {
            result.append(family)
        }
        return result
    }
}
