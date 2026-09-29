//
//  SettingsViewModelTests.swift
//  BASICStudioTests
//
//  P1 unit 3: the Settings window's projection.
//

import Foundation
import Testing
@testable import BASICStudio

@Suite("SettingsViewModel")
@MainActor
struct SettingsViewModelTests {
    @Test("W6 · Three tabs: General, Font, Console")
    func tabs() {
        #expect(SettingsViewModel.tabs.map(\.title) == ["General", "Font", "Console"])
        #expect(SettingsViewModel.tabs.map(\.symbol) == ["gearshape", "textformat", "terminal"])
    }

    @Test("S2 · Preferred fonts come first, then the installed ones in Finder order, each once")
    func fontFamilies() {
        let families = SettingsViewModel.fontFamilies(installed: ["Zapfino", "Menlo", "Arial", "Font 10", "Font 9"])
        #expect(Array(families.prefix(6)) == SettingsViewModel.preferredFontFamilies)
        #expect(Array(families.dropFirst(6)) == ["Arial", "Font 9", "Font 10", "Zapfino"])
    }

    @Test("S3 · Font size: 10 to 24 in whole points, labeled whole")
    func fontSize() {
        let studio = StudioHarness().model
        studio.fontSize = 13.6
        #expect(SettingsViewModel(studio).fontSizeText == "13")
        #expect(SettingsViewModel.fontSizeRange == 10...24)
        #expect(SettingsViewModel.fontSizeStep == 1)
    }

    @Test("S4 · Scrollback: the stored range, in steps of 100")
    func scrollback() {
        let studio = StudioHarness().model
        studio.consoleScrollbackLines = 2_500
        let settings = SettingsViewModel(studio)
        #expect(settings.scrollbackLines == 2_500)
        #expect(settings.scrollbackText == "2500")
        #expect(SettingsViewModel.scrollbackRange == StudioSettings.consoleScrollbackRange)
        #expect(SettingsViewModel.scrollbackStep == 100)
    }

    @Test("S2 · The model's font family is the picker's selection")
    func family() {
        let studio = StudioHarness().model
        studio.fontFamily = "Menlo"
        #expect(SettingsViewModel(studio).fontFamily == "Menlo")
    }
}
