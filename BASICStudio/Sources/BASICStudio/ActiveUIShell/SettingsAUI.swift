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
        // Stepped by the point, with the ticks SwiftUI's stepped slider shows.
        sizeSlider.tickMarks = Int(SettingsViewModel.fontSizeRange.upperBound - SettingsViewModel.fontSizeRange.lowerBound) + 1
        sizeSlider.snapsToTickMarks = true
        sizeLabel = AUILabel("")
        sizeLabel.usesMonospacedDigits = true
        sizeLabel.minimumSize = CGSize(width: 32, height: 0)
        sizeLabel.alignment = .trailing
        let fontForm = AUIForm()
        fontForm.addSection(SettingsViewModel.fontSectionTitle, isFirst: true)
        fontForm.addRow("Font", fontPicker)
        fontForm.addRow("Size", LogPaneAUI.row([sizeSlider.stretches(), sizeLabel]))
        fontPage = PromptEditorAUI.column([fontForm, Self.note(SettingsViewModel.fontNote)])
        fontPage.padding = .zero

        let range = SettingsViewModel.scrollbackRange
        let bounds = Double(range.lowerBound)...Double(range.upperBound)
        let step = Double(SettingsViewModel.scrollbackStep)
        scrollbackSlider = AUISlider(value: Double(model.consoleScrollbackLines), in: bounds)
        scrollbackSlider.tickMarks = (range.upperBound - range.lowerBound) / SettingsViewModel.scrollbackStep + 1
        scrollbackSlider.snapsToTickMarks = true
        scrollbackStepper = AUIStepper("", value: Double(model.consoleScrollbackLines), in: bounds, step: step)
        scrollbackLabel = AUILabel("")
        scrollbackLabel.usesMonospacedDigits = true
        scrollbackLabel.minimumSize = CGSize(width: 56, height: 0)
        scrollbackLabel.alignment = .trailing
        let consoleForm = AUIForm()
        consoleForm.addSection(SettingsViewModel.scrollbackSectionTitle, isFirst: true)
        // The value, then its stepper: a SwiftUI Stepper draws its label first.
        consoleForm.addRow("Lines", LogPaneAUI.row([scrollbackSlider.stretches(), scrollbackLabel, scrollbackStepper]))
        consolePage = PromptEditorAUI.column([consoleForm, Self.note(SettingsViewModel.scrollbackNote)])
        consolePage.padding = .zero

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

    /// How far the Settings window insets a page on each side: its 20-point
    /// window margin, then 16 around the page's scroll view. A page adds no
    /// padding of its own; SwiftUI's Settings pads by 16 in all.
    static let pageInset: CGFloat = 36

    /// How much shorter than its page the legacy Settings window comes out.
    ///
    /// ActiveUI's legacy resize sets the window's height to the page's plus
    /// the icon strip's, but the window then insets its root by the 20-point
    /// window margin, top and bottom, and the page loses those 40 points to
    /// clipping. Padding the page's foot by as much gives them back. Remove
    /// it once `resizeForPaneIfLegacy` counts the margin.
    static let legacyResizeShortfall: CGFloat = 40

    /// A page's width inside the Settings window.
    static var pageWidth: CGFloat { SettingsViewModel.windowSize.width - 2 * pageInset }

    /// A page's explanation, under its form. `AUIForm.addFooter` would span
    /// the form's two columns, and a spanning label is measured unwrapped,
    /// so a long note ran off the page; the page's column wraps it.
    static func note(_ text: String) -> AUILabel {
        let label = PromptEditorAUI.caption(text)
        label.wraps = true
        label.lineLimit = nil
        return label
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
        // The icon strip across the top, as SwiftUI's Settings scene draws
        // it; it also sizes the window to each page, so none is clipped.
        window.style = .legacy
        window.title = "Settings"
        window.contentSize = CGSize(width: SettingsViewModel.windowSize.width, height: SettingsViewModel.windowSize.height)
        let tabs = SettingsViewModel.tabs
        let pages = [promptEditor.root, fontPage, consolePage]
        for (tab, page) in zip(tabs, pages) {
            page.padding = AUIEdgeInsets(top: 0, leading: 0, bottom: Self.legacyResizeShortfall, trailing: 0)
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
