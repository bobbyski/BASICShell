//
//  SettingsAUI.swift
//  BASICStudio
//
//  The Settings window, in ActiveUI.
//

import ActiveUI
import AppKit
import Foundation

/// The Settings window for the ActiveUI shell: three pages in
/// `AUIPreferencesWindow`, from ``SettingsViewModel``'s tabs, ranges, steps and
/// notes, the same ones the SwiftUI `SettingsView` shows.
///
/// ```text
///   General   the prompt editor (PromptEditorAUI)
///   Font      Font ▾ (preferred first)   Size ──●── 13
///   Console   Lines ──●── [−|+] 10000    the scrollback note
/// ```
///
/// A slider snaps to its step when moved, as SwiftUI's `step:` does.
@MainActor
final class SettingsAUI {
    let model: StudioModel
    let promptEditor: PromptEditorAUI
    let fontPage: AUIView
    let consolePage: AUIView
    let fontPicker: AUIPicker
    let sizeSlider: AUISlider
    let sizeLabel: AUILabel
    let scrollbackSlider: AUISlider
    let scrollbackStepper: AUIStepper
    let scrollbackLabel: AUILabel
    let families: [String]
    private var drawn: SettingsViewModel?

    init(model: StudioModel, installedFamilies: [String] = NSFontManager.shared.availableFontFamilies) {
        self.model = model
        promptEditor = PromptEditorAUI(model: model)
        families = SettingsViewModel.fontFamilies(installed: installedFamilies)

        fontPicker = AUIPicker(families)
        sizeSlider = AUISlider(value: model.fontSize, in: SettingsViewModel.fontSizeRange)
        sizeLabel = AUILabel("")
        sizeLabel.usesMonospacedDigits = true
        sizeLabel.minimumSize = CGSize(width: 32, height: 0)
        let fontForm = AUIForm()
        fontForm.addSection(SettingsViewModel.fontSectionTitle, isFirst: true)
        fontForm.addRow("Font", fontPicker)
        fontForm.addRow("Size", LogPaneAUI.row([sizeSlider.stretches(), sizeLabel]))
        fontForm.addFooter(SettingsViewModel.fontNote)
        fontPage = PromptEditorAUI.column([fontForm])
        fontPage.padding = AUIEdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)

        let range = SettingsViewModel.scrollbackRange
        let bounds = Double(range.lowerBound)...Double(range.upperBound)
        let step = Double(SettingsViewModel.scrollbackStep)
        scrollbackSlider = AUISlider(value: Double(model.consoleScrollbackLines), in: bounds)
        scrollbackStepper = AUIStepper("", value: Double(model.consoleScrollbackLines), in: bounds, step: step)
        scrollbackLabel = AUILabel("")
        scrollbackLabel.usesMonospacedDigits = true
        scrollbackLabel.minimumSize = CGSize(width: 56, height: 0)
        let consoleForm = AUIForm()
        consoleForm.addSection(SettingsViewModel.scrollbackSectionTitle, isFirst: true)
        consoleForm.addRow("Lines", LogPaneAUI.row([scrollbackSlider.stretches(), scrollbackStepper, scrollbackLabel]))
        consoleForm.addFooter(SettingsViewModel.scrollbackNote)
        consolePage = PromptEditorAUI.column([consoleForm])
        consolePage.padding = AUIEdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)

        fontPicker.onSelectionChange = { [weak self] index in
            guard let self else { return }
            self.model.fontFamily = self.families[index]
        }
        sizeSlider.onChange = { [weak model] value in
            model?.fontSize = Self.snapped(value, step: SettingsViewModel.fontSizeStep, from: SettingsViewModel.fontSizeRange.lowerBound)
        }
        scrollbackSlider.onChange = { [weak model] value in
            model?.consoleScrollbackLines = Int(Self.snapped(value, step: step, from: bounds.lowerBound))
        }
        scrollbackStepper.onChange = { [weak model] value in
            model?.consoleScrollbackLines = Int(value.rounded())
        }
        refresh()
    }

    private var isInstalled = false

    /// BASICStudio ▸ Settings…: puts the pages in the shared window the first
    /// time, then shows it.
    func show() {
        if !isInstalled {
            install()
            isInstalled = true
        }
        refresh()
        AUIPreferencesWindow.shared.show()
    }

    /// Adds the three pages to `window`, replacing any there.
    func install(in window: AUIPreferencesWindow = .shared) {
        window.removeAllPages()
        window.title = "Settings"
        window.contentSize = CGSize(width: SettingsViewModel.windowSize.width, height: SettingsViewModel.windowSize.height)
        let tabs = SettingsViewModel.tabs
        let pages = [promptEditor.root, fontPage, consolePage]
        for (tab, page) in zip(tabs, pages) {
            window.addPage(tab.title, symbol: tab.symbol) { page }
        }
    }

    /// Brings the pages up to the model; nothing happens if nothing changed.
    func refresh() {
        promptEditor.refresh()
        let settings = SettingsViewModel(model)
        guard settings != drawn else { return }
        fontPicker.selectedIndex = families.firstIndex(of: settings.fontFamily)
        sizeSlider.value = settings.fontSize
        sizeLabel.text = settings.fontSizeText
        scrollbackSlider.value = Double(settings.scrollbackLines)
        scrollbackStepper.value = Double(settings.scrollbackLines)
        scrollbackLabel.text = settings.scrollbackText
        drawn = settings
    }

    /// `value` on the nearest step up from `origin`, as a stepped slider gives.
    static func snapped(_ value: Double, step: Double, from origin: Double) -> Double {
        origin + ((value - origin) / step).rounded() * step
    }
}
