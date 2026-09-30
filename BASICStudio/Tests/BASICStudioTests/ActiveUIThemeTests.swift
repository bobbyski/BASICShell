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
        #expect(StudioAppTheme.names == ["Native", "NC State", "Blue", "moneyBags", "Slate", "Freebird"])
        #expect(StudioAppTheme.stylesheet(for: "Native") == nil)
        for name in StudioAppTheme.names where name != StudioAppTheme.native {
            #expect(StudioAppTheme.css(for: name)?.contains(".window") == true, "\(name)")
            #expect(StudioAppTheme.stylesheet(for: name) != nil, "\(name)")
        }
        #expect(StudioAppTheme.validated("High Contrast") == "Native", "an old or unknown name falls back")
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
    }
}
