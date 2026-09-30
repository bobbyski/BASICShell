//
//  SettingsAUI.swift
//  BASICStudio
//
//  The Settings window, in ActiveUI.
//

import ActiveUI
import AppKit
import Foundation

/// The Settings window for the ActiveUI shell: `AUIPreferencesWindow` in its
/// modern chrome, a sidebar of pages beside a resizable page. General, Font
/// and Console are ``SettingsViewModel``'s tabs, ranges, steps and notes, the
/// same ones the SwiftUI `SettingsView` shows. Editor is this shell's own.
///
/// ```text
///   General   the prompt editor (PromptEditorAUI)
///   Editor    Appearance: the app theme
///             Typing: Tab indents, new-line indent, indent width
///             Display: line numbers
///   Font      Font ▾ (preferred first)   Size ──●── 13
///   Console   Lines ──●── [−|+] 10000    the scrollback note
/// ```
///
/// A slider snaps to its step when moved, as SwiftUI's `step:` does.
@MainActor
final class SettingsAUI {
    let model: StudioModel
    let promptEditor: PromptEditorAUI
    let editorPage: AUIView
    let fontPage: AUIView
    let consolePage: AUIView
    let tabIndentSwitch: AUISwitch
    let newLineIndentSwitch: AUISwitch
    let indentPicker: AUIPicker
    let themePicker: AUIPicker
    let lineNumbersSwitch: AUISwitch
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
        let fontGroup = AUISettingsGroup(title: SettingsViewModel.fontSectionTitle)
        fontGroup.addRow("Font", accessory: fontPicker)
        fontGroup.addRow(Self.row("Size", [sizeSlider.stretches(), sizeLabel]))
        fontPage = Self.page([fontGroup, Self.note(SettingsViewModel.fontNote)])

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
        let scrollbackGroup = AUISettingsGroup(title: SettingsViewModel.scrollbackSectionTitle)
        // The value, then its stepper: a SwiftUI Stepper draws its label first.
        scrollbackGroup.addRow(Self.row("Lines", [scrollbackSlider.stretches(), scrollbackLabel, scrollbackStepper]))
        consolePage = Self.page([scrollbackGroup, Self.note(SettingsViewModel.scrollbackNote)])

        // Editor: what Studio takes from FreebirdStudio's Editing and Display
        // pages, which drive the same SwiftyCodeEditor. What it leaves out,
        // and why, is on `SourceEditorAUI.behavior(_:)`.
        tabIndentSwitch = AUISwitch(isOn: model.editorIndentsSelectionWithTab) { [weak model] in
            model?.editorIndentsSelectionWithTab = $0
        }
        newLineIndentSwitch = AUISwitch(isOn: model.editorIndentsNewLines) { [weak model] in
            model?.editorIndentsNewLines = $0
        }
        indentPicker = AUIPicker(Self.indentUnits.map(\.title))
        let typing = AUISettingsGroup(title: "Typing")
        typing.addRow("Indent selection with Tab",
                      description: "Tab and Shift-Tab indent or outdent the selected lines instead of replacing them.",
                      accessory: tabIndentSwitch)
        typing.addRow("Indent new lines",
                      description: "Return starts the new line at the same indentation as the line before it.",
                      accessory: newLineIndentSwitch)
        typing.addRow("Indent with",
                      description: "One level of indentation, for Tab and for new lines.",
                      accessory: indentPicker)
        themePicker = AUIPicker(StudioAppTheme.names)
        let appearance = AUISettingsGroup(title: "Appearance")
        appearance.addRow("Theme",
                          description: "Restyles the whole window. Native follows the system; the others are dark, and the editor follows. The toolbar's palette menu chooses it too.",
                          accessory: themePicker)
        lineNumbersSwitch = AUISwitch(isOn: model.isEditorGutterVisible) { [weak model] in
            model?.isEditorGutterVisible = $0
        }
        let display = AUISettingsGroup(title: "Display")
        display.addRow("Show line numbers",
                       description: "Numbers each line in the editor's gutter. The toolbar's line-number button sets it too.",
                       accessory: lineNumbersSwitch)
        editorPage = Self.page([appearance, typing, display])

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
        indentPicker.onSelectionChange = { [weak model] index in
            model?.editorIndentUnit = Self.indentUnits[index].unit
        }
        themePicker.onSelectionChange = { [weak model] index in
            guard let model else { return }
            StudioAppTheme.choose(index, on: model)
        }
        refresh()
    }

    /// How far the SwiftUI Settings window insets a page on each side.
    static let pageInset: CGFloat = 36

    /// The width a page is designed for: the SwiftUI Settings window's page.
    /// The prompt editor needs all of it, so it is the prompt editor's
    /// minimum, and the window opens wide enough to give it.
    static var pageWidth: CGFloat { SettingsViewModel.windowSize.width - 2 * pageInset }

    /// The window as it first opens: the sidebar at its widest, the page at
    /// ``pageWidth`` with the modern chrome's 16 points either side, and a
    /// margin. The user can make it any size from there.
    static let windowSize = CGSize(width: pageWidth + 2 * 16 + 280 + 20, height: 620)

    /// Settings ▸ Editor ▸ Indent with.
    static let indentUnits: [(title: String, unit: String)] = [
        ("Tab", "\t"), ("2 spaces", "  "), ("4 spaces", "    "),
    ]

    /// A page: its groups and notes stacked, no wider than reads well. No
    /// scroll view and no padding, as the window gives every page both.
    static func page(_ parts: [AUIView]) -> AUIView {
        let column = AUIStack(.vertical, spacing: 18, alignment: .fill)
        column.wraps = false
        column.maximumSize = CGSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        for part in parts {
            column.addChild(part)
        }
        return column
    }

    /// A settings row with a title and controls of its own, padded as a
    /// group's standard rows are.
    static func row(_ title: String, _ controls: [AUIView]) -> AUIView {
        let row = LogPaneAUI.row([AUILabel(title)] + controls)
        row.padding = AUIEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        return row
    }

    /// A page's explanation, under its group. A label of the page's own, so
    /// the page's column wraps it at the page's width.
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

    /// Adds the four pages to `window`, replacing any there.
    func install(in window: AUIPreferencesWindow = .shared) {
        window.removeAllPages()
        // The sidebar at the leading edge, as System Settings and
        // FreebirdStudio draw it, in a window the user can resize.
        window.style = .modern
        window.allowsResizing = true
        window.title = "Settings"
        window.contentSize = Self.windowSize
        let tabs = SettingsViewModel.tabs
        let pages: [(title: String, symbol: String, page: AUIView)] = [
            (tabs[0].title, tabs[0].symbol, promptEditor.root),
            ("Editor", "square.and.pencil", editorPage),
            (tabs[1].title, tabs[1].symbol, fontPage),
            (tabs[2].title, tabs[2].symbol, consolePage),
        ]
        for entry in pages {
            let page = entry.page
            window.addPage(entry.title, symbol: entry.symbol) { page }
        }
    }

    /// Brings the pages up to the model; nothing happens if nothing changed.
    func refresh() {
        promptEditor.refresh()
        refreshEditorPage()
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

    /// The Editor page's controls, set only where they differ, so a change
    /// made elsewhere (the toolbar's theme or line-number button) shows here.
    private func refreshEditorPage() {
        if tabIndentSwitch.isOn != model.editorIndentsSelectionWithTab {
            tabIndentSwitch.isOn = model.editorIndentsSelectionWithTab
        }
        if newLineIndentSwitch.isOn != model.editorIndentsNewLines {
            newLineIndentSwitch.isOn = model.editorIndentsNewLines
        }
        if lineNumbersSwitch.isOn != model.isEditorGutterVisible {
            lineNumbersSwitch.isOn = model.isEditorGutterVisible
        }
        let indent = Self.indentUnits.firstIndex { $0.unit == model.editorIndentUnit }
        if indentPicker.selectedIndex != indent {
            indentPicker.selectedIndex = indent
        }
        let theme = StudioAppTheme.names.firstIndex(of: StudioAppTheme.validated(model.appTheme))
        if themePicker.selectedIndex != theme {
            themePicker.selectedIndex = theme
        }
    }

    /// `value` on the nearest step up from `origin`, as a stepped slider gives.
    static func snapped(_ value: Double, step: Double, from origin: Double) -> Double {
        origin + ((value - origin) / step).rounded() * step
    }
}
