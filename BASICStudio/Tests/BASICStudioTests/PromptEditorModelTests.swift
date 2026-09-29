//
//  PromptEditorModelTests.swift
//  BASICStudioTests
//
//  P1 unit 7: the prompt editor's edits, moved out of NerdPromptEditorView.
//

import BASICCore
import Foundation
import Testing
@testable import BASICStudio

@Suite("PromptEditorModel")
struct PromptEditorModelTests {
    private func kinds(_ editor: PromptEditorModel) -> [NerdPromptSegment.Kind] {
        editor.segments.map(\.kind)
    }

    @Test("N6 · A new editor starts from the Shell Style preset, adding, not editing")
    func startsFromThePreset() {
        let editor = PromptEditorModel()
        #expect(kinds(editor) == [.os, .currentDirectory, .gitBranch, .gitStatus, .literal])
        #expect(!editor.isEditing)
        #expect(editor.template == NerdPromptTemplateBuilder.template(for: NerdPromptSegment.shellStylePreset))
    }

    @Test("The preset's template is the one BASICSession ships as its default")
    func presetIsTheSessionDefault() {
        #expect(PromptEditorModel().template == BASICSession.defaultPromptTemplate)
    }

    @Test("N1 · Clicking a row selects it; clicking it again goes back to adding")
    func selection() {
        var editor = PromptEditorModel()
        let id = editor.segments[1].id
        editor.toggleSelection(id)
        #expect(editor.isEditing && editor.selectedIndex == 1)
        editor.toggleSelection(id)
        #expect(!editor.isEditing)
        editor.select(id)
        editor.deselect()
        #expect(editor.selectedSegmentID == nil)
    }

    @Test("N3 · Add uses the form, keeps text only for a Text segment, and selects the new one")
    func add() {
        var editor = PromptEditorModel()
        editor.newKind = .user
        editor.newLiteral = "ignored"
        editor.newForeground = .black
        editor.newBackground = .gold
        editor.addNewSegment()
        let added = editor.segments.last!
        #expect(added.kind == .user && added.literal.isEmpty)
        #expect(added.foreground == .black && added.background == .gold)
        #expect(editor.selectedSegmentID == added.id)

        editor.newKind = .literal
        editor.addNewSegment()
        #expect(editor.segments.last?.literal == "ignored")
    }

    @Test("N1 · Drag to reorder: rows land before the destination, counted before the move")
    func move() {
        var editor = PromptEditorModel()
        editor.move(fromOffsets: [0], toOffset: 3)
        #expect(kinds(editor) == [.currentDirectory, .gitBranch, .os, .gitStatus, .literal])
        editor.move(fromOffsets: [3, 4], toOffset: 0)
        #expect(kinds(editor) == [.gitStatus, .literal, .currentDirectory, .gitBranch, .os])
        editor.move(fromOffsets: [1], toOffset: 5)
        #expect(kinds(editor) == [.gitStatus, .currentDirectory, .gitBranch, .os, .literal])
    }

    @Test("N1 · Swipe to delete: deleting the selected row selects the first")
    func swipeDelete() {
        var editor = PromptEditorModel()
        editor.select(editor.segments[2].id)
        editor.delete(atOffsets: [1, 2])
        #expect(kinds(editor) == [.os, .gitStatus, .literal])
        #expect(editor.selectedIndex == 0)

        editor.select(editor.segments[2].id)
        editor.delete(atOffsets: [0])
        #expect(editor.selectedIndex == 1)
    }

    @Test("N1 · The row's Delete: the first row takes a deleted selection")
    func menuDelete() {
        var editor = PromptEditorModel()
        let id = editor.segments[3].id
        editor.select(id)
        editor.delete(id)
        #expect(editor.segments.count == 4 && editor.selectedIndex == 0)
    }

    @Test("N2 · The editor's Delete: the next row takes the selection, or the last when it was last")
    func editorDelete() {
        var editor = PromptEditorModel()
        editor.select(editor.segments[1].id)
        editor.deleteSelected()
        #expect(kinds(editor) == [.os, .gitBranch, .gitStatus, .literal])
        #expect(editor.selectedIndex == 1)
        editor.select(editor.segments[3].id)
        editor.deleteSelected()
        #expect(editor.selectedIndex == 2)
    }

    @Test("N2 · Duplicate inserts a copy after the selection and selects it")
    func duplicate() {
        var editor = PromptEditorModel()
        let original = editor.segments[1]
        editor.select(original.id)
        editor.duplicateSelected()
        #expect(editor.segments.count == 6)
        let copy = editor.segments[2]
        #expect(copy.id != original.id && copy.kind == original.kind && copy.background == original.background)
        #expect(editor.selectedIndex == 2)
    }

    @Test("N2 · Field edits: leaving Text clears the text; a right edge never matches")
    func fieldEdits() {
        var editor = PromptEditorModel()
        editor.select(editor.segments[4].id)
        #expect(editor.selectedKind == .literal && editor.selectedLiteral == "Ready")
        editor.setSelectedLiteral("Go")
        #expect(editor.segments[4].literal == "Go")
        editor.setSelectedKind(.user)
        #expect(editor.segments[4].literal.isEmpty)
        editor.setSelectedForeground(.red)
        editor.setSelectedBackground(.silver)
        editor.setSelectedLeftEdge(.rounded)
        editor.setSelectedRightEdge(.match)
        let edited = editor.segments[4]
        #expect(edited.foreground == .red && edited.background == .silver)
        #expect(edited.leftEdge == .rounded && edited.rightEdge == .angled)
    }

    @Test("N2 · With nothing selected the pickers show their defaults, and edits do nothing")
    func noSelection() {
        var editor = PromptEditorModel()
        #expect(editor.selectedKind == .literal && editor.selectedLiteral.isEmpty)
        #expect(editor.selectedForeground == .white && editor.selectedBackground == .blue)
        #expect(editor.selectedLeftEdge == .match && editor.selectedRightEdge == .angled)
        let before = editor.segments
        editor.setSelectedForeground(.red)
        editor.deleteSelected()
        editor.duplicateSelected()
        #expect(editor.segments == before)
    }

    @Test("N4 · Presets: Shell Style restores the segments; the other two are fixed templates")
    func presets() {
        var editor = PromptEditorModel()
        editor.delete(atOffsets: [0, 1, 2])
        editor.applyShellStylePreset()
        #expect(kinds(editor) == [.os, .currentDirectory, .gitBranch, .gitStatus, .literal])
        #expect(PromptEditorModel.plainDefaultTemplate == BASICSession.plainPromptTemplate)
        #expect(PromptEditorModel.classicBASICTemplate == "READY%nl> ")
    }

    @Test("The preset's template, arriving from outside, reloads the preset and selects its first row")
    func syncFromTemplate() {
        var editor = PromptEditorModel()
        editor.delete(atOffsets: [0])
        editor.sync(fromTemplate: "READY%nl> ")
        #expect(editor.segments.count == 4)
        editor.sync(fromTemplate: BASICSession.defaultPromptTemplate)
        #expect(editor.segments.count == 5 && editor.selectedIndex == 0)
    }

    @Test("No segments build BASICSession's default template")
    func emptyTemplate() {
        var editor = PromptEditorModel()
        editor.delete(atOffsets: IndexSet(0..<5))
        #expect(editor.template == BASICSession.defaultPromptTemplate)
    }
}
