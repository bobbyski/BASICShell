//
//  ActiveUIThemeTests.swift
//  BASICStudioTests
//
//  The ActiveUI shell's app themes.
//

import ActiveUI
import Foundation
import Testing
@testable import BASICStudio

@Suite("ActiveUI app themes", .serialized)
@MainActor
struct ActiveUIThemeTests {
    @Test("T13 · The themes are FreebirdStudio's, and every one but Native has a stylesheet that loads")
    func themesLoad() {
        #expect(StudioAppTheme.names == ["Native", "Light", "Dark", "High Contrast", "NC State", "Blue", "moneyBags", "Slate", "Freebird"])
        #expect(StudioAppTheme.stylesheet(for: "Native") == nil)
        for name in StudioAppTheme.names where name != StudioAppTheme.native {
            #expect(StudioAppTheme.css(for: name)?.contains(".window") == true, "\(name)")
            #expect(StudioAppTheme.stylesheet(for: name) != nil, "\(name)")
        }
        #expect(StudioAppTheme.validated("Solarized") == "Native", "an unknown name falls back")
    }

    @Test("T13 · The toolbar menu and the editor follow the theme")
    func menuAndEditorFollow() {
        let model = StudioHarness().model
        #expect(StudioAppTheme.menu(model).label == "Native")
        StudioAppTheme.choose(StudioAppTheme.names.firstIndex(of: "Blue")!, on: model)
        #expect(model.appTheme == "Blue")
        #expect(StudioAppTheme.menu(model).items.filter(\.isChecked).map(\.title) == ["Blue"])
        // Every theme but Native is dark, and so is the editor under it.
        #expect(StudioAppTheme.themed(.mainEditor(model), model).theme == .dark)
        #expect(StudioAppTheme.themed(.debugCodeView(model), model).theme == .dark)
        // Light and High Contrast carry the editor's own light and
        // high-contrast colors with them.
        model.appTheme = "Light"
        #expect(StudioAppTheme.themed(.mainEditor(model), model).theme == .light)
        model.appTheme = "High Contrast"
        #expect(StudioAppTheme.themed(.mainEditor(model), model).theme == .highContrast)
    }

    @Test("T13 · Choosing a theme restyles the shell and relabels the palette button")
    func shellFollows() {
        let studio = StudioActiveUIShell(model: StudioHarness().model)
        defer { StudioAppTheme.install(StudioAppTheme.native) }
        studio.refresh()
        #expect(studio.themeItem.label == "Native")
        studio.model.appTheme = "Slate"
        studio.refresh()
        #expect(studio.themeItem.label == "Slate")
        #expect(AUIApplication.appearance == .dark)
        studio.model.appTheme = "Light"
        studio.refresh()
        #expect(AUIApplication.appearance == .light, "Light is the one light theme")
    }
}
