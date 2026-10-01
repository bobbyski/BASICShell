//
//  ActiveUISettingsTests.swift
//  BASICStudioTests
//
//  Level 3 for P3.3 and P3.5: the Settings window and its prompt editor.
//

import ActiveUI
import AppKit
import BASICCore
import Foundation
import Testing
@testable import BASICStudio

@Suite("ActiveUI settings", .serialized)
@MainActor
struct ActiveUISettingsTests {
    @Test("S2 · The font picker lists the preferred families first, and picking one sets the model")
    func fontPicker() {
        let model = StudioHarness().model
        let settings = SettingsAUI(model: model, installedFamilies: ["Zapfino", "Menlo"])
        #expect(settings.families == SettingsViewModel.fontFamilies(installed: ["Zapfino", "Menlo"]))
        #expect(settings.fontPicker.options == settings.families)
        let zapfino = settings.families.firstIndex(of: "Zapfino")!
        settings.fontPicker.onSelectionChange?(zapfino)
        #expect(model.fontFamily == "Zapfino")
        settings.refresh()
        #expect(settings.fontPicker.selectedIndex == zapfino)
    }

    @Test("S3 S4 · The sliders snap to their steps, and the labels follow")
    func sliders() {
        let model = StudioHarness().model
        let settings = SettingsAUI(model: model, installedFamilies: [])
        settings.sizeSlider.onChange?(13.4)
        #expect(model.fontSize == 13)
        settings.scrollbackSlider.onChange?(2_549)
        #expect(model.consoleScrollbackLines == 2_500)
        settings.refresh()
        #expect(settings.sizeLabel.text == "13")
        #expect(settings.scrollbackLabel.text == "2500")
        #expect(SettingsAUI.snapped(262, step: 100, from: 200) == 300)
    }

    @Test("S1 · Settings is the modern, resizable window: a sidebar of four pages, Editor among them")
    func modernWindow() {
        let settings = SettingsAUI(model: StudioHarness().model, installedFamilies: [])
        let window = AUIPreferencesWindow.shared
        settings.install(in: window)
        #expect(window.style == .modern)
        #expect(window.allowsResizing == true)
        #expect(window.pages.map(\.title) == ["General", "Editor", "Font", "Console", "Storage"])
        // Wide enough that the prompt editor, which needs a page's full
        // width, opens unclipped beside the widest sidebar.
        #expect(window.contentSize.width >= SettingsAUI.pageWidth + 2 * 16 + 280)
    }

    @Test("S7 · The Editor page sets the model, and follows changes made elsewhere")
    func editorPage() {
        let model = StudioHarness().model
        let settings = SettingsAUI(model: model, installedFamilies: [])
        #expect(settings.tabIndentSwitch.isOn && settings.newLineIndentSwitch.isOn)
        #expect(settings.indentPicker.selectedIndex == 2, "four spaces, as the demos are written")

        settings.tabIndentSwitch.onChange?(false)
        settings.newLineIndentSwitch.onChange?(false)
        settings.indentPicker.onSelectionChange?(0)
        settings.lineNumbersSwitch.onChange?(true)
        settings.themePicker.onSelectionChange?(StudioAppTheme.names.firstIndex(of: "Blue")!)
        #expect(!model.editorIndentsSelectionWithTab && !model.editorIndentsNewLines)
        #expect(model.editorIndentUnit == "\t" && model.isEditorGutterVisible && model.appTheme == "Blue")
        let input = EditorRenderInput.mainEditor(model)
        #expect(!input.indentsSelectionWithTab && !input.indentsNewLines && input.indentUnit == "\t")

        // The toolbar changes them too; the page shows it.
        model.isEditorGutterVisible = false
        model.appTheme = "Slate"
        settings.refresh()
        #expect(!settings.lineNumbersSwitch.isOn)
        #expect(settings.themePicker.selectedIndex == StudioAppTheme.names.firstIndex(of: "Slate"))
    }

    @Test("S4 · The Console page's note wraps inside the page, and the value sits before its stepper")
    func consolePageFits() {
        let settings = SettingsAUI(model: StudioHarness().model, installedFamilies: [])
        let width = SettingsAUI.pageWidth
        let page = settings.consolePage
        page.place(in: CGRect(x: 0, y: 0, width: width, height: page.layoutSize(fitting: CGSize(width: width, height: 10_000)).height))
        page.nativeView.layoutSubtreeIfNeeded()
        func frame(_ view: AUIView) -> CGRect { view.nativeView.convert(view.nativeView.bounds, to: page.nativeView) }
        let note = frame(page.children.last!)
        #expect(note.maxX <= width + 0.5, "\(note)")
        // Two lines of caption at this width, not one clipped one.
        #expect(note.height >= 24, "\(note)")
        #expect(frame(settings.scrollbackLabel).maxX <= frame(settings.scrollbackStepper).minX + 0.5)
        #expect(settings.scrollbackSlider.tickMarks == 499)
    }

    @Test("N5 · Laid out at the Settings window's page width, nothing on the prompt editor ends past it")
    func promptEditorFits() {
        let editor = SettingsAUI(model: StudioHarness().model, installedFamilies: []).promptEditor
        let width = SettingsAUI.pageWidth
        #expect(width == 688)
        let root = editor.root
        root.place(in: CGRect(x: 0, y: 0, width: width, height: 600))
        root.nativeView.layoutSubtreeIfNeeded()
        // Every view's right edge, except what a scroll view holds (the
        // preview scrolls sideways by design).
        var overflowing: [String] = []
        func visit(_ view: AUIView) {
            guard !view.isHidden else { return }
            let frame = view.nativeView.convert(view.nativeView.bounds, to: root.nativeView)
            if frame.maxX > width + 0.5 { overflowing.append("\(type(of: view)) \(frame)") }
            guard !(view is AUIScrollView) else { return }
            view.children.forEach(visit)
        }
        visit(root)
        #expect(overflowing.isEmpty, "\(overflowing)")
    }

    @Test("N6 · On the preset's template it opens on the preset's segments, editing the first, as SwiftUI's does on appear")
    func promptEditorStarts() {
        let model = StudioHarness().model
        let pane = PromptEditorAUI(model: model)
        #expect(pane.editor.segments.count == 5)
        #expect(pane.segmentTable.rowCount() == 5)
        #expect(pane.templateField.text == model.promptTemplate)
        #expect(pane.editor.selectedIndex == 0)
        #expect(pane.addForm.root.isHidden && !pane.editForm.root.isHidden)
        #expect(!pane.preview.children.isEmpty)
    }

    @Test("N1 N2 · Selecting a row edits it; a field change rewrites the model's template")
    func editASegment() {
        let model = StudioHarness().model
        let pane = PromptEditorAUI(model: model)
        pane.segmentTable.onSelectionChange?([1])
        #expect(pane.editor.selectedIndex == 1)
        #expect(pane.addForm.root.isHidden && !pane.editForm.root.isHidden)
        pane.editForm.onChange?(.foreground(.red))
        #expect(pane.editor.segments[1].foreground == .red)
        #expect(model.promptTemplate == pane.editor.template)
        #expect(pane.templateField.text == model.promptTemplate)
    }

    @Test("N1 · Dragging a row down lands it where the table says")
    func reorder() {
        let model = StudioHarness().model
        let pane = PromptEditorAUI(model: model)
        let first = pane.editor.segments[0].kind
        pane.segmentTable.onReorder?(0, 2)
        #expect(pane.editor.segments[2].kind == first)
        #expect(model.promptTemplate == pane.editor.template)
    }

    @Test("N1 · A row's right-click menu: Edit selects it, Delete removes it")
    func rowMenu() throws {
        let model = StudioHarness().model
        let pane = PromptEditorAUI(model: model)
        let second = pane.editor.segments[2].id
        let row = pane.segmentTable.rowContent(2)
        let menu = try #require(row.contextMenu)
        #expect(menu.items.map(\.title) == ["Edit", "Delete"])
        menu.items[0].perform()
        #expect(pane.editor.selectedSegmentID == second)
        menu.items[1].perform()
        #expect(pane.editor.segments.count == 4)
        #expect(!pane.editor.segments.contains { $0.id == second })
        #expect(model.promptTemplate == pane.editor.template)
    }

    @Test("N3 · Add appends from the form and selects it")
    func add() {
        let model = StudioHarness().model
        let pane = PromptEditorAUI(model: model)
        pane.addForm.onChange?(.kind(.user))
        pane.addForm.onAdd?()
        #expect(pane.editor.segments.count == 6)
        #expect(pane.editor.segments.last?.kind == .user)
        #expect(pane.editor.selectedIndex == 5)
    }

    @Test("N4 · Classic BASIC sets the template directly; the segments stay")
    func classicPreset() {
        let model = StudioHarness().model
        let pane = PromptEditorAUI(model: model)
        model.promptTemplate = PromptEditorModel.classicBASICTemplate
        pane.refresh()
        #expect(pane.templateField.text == "READY%nl> ")
        #expect(pane.editor.segments.count == 5)
    }
}
