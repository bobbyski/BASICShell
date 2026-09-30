//
//  PromptEditorModel.swift
//  BASICStudio
//
//  The prompt editor's working state and edits, for either shell.
//

import BASICCore
import Foundation

/// The prompt editor (Settings ▸ General) as a value: the segment list, the
/// selection, the Add Segment form, and every edit the pane can make.
///
/// Unlike the other projections this one holds state, because the editor
/// always has: the segments being built are the editor's own, not
/// ``StudioModel``'s. Each shell keeps one of these as its state and, after
/// every edit, writes ``template`` back to the model's prompt template. The
/// logic moved here unchanged from `NerdPromptEditorView`.
///
/// ```text
///   Preview    [ os ][ ~/src ][ git main ][ Ready ]     segments
///   Segments   ▸ Current Directory       ●              selection toggles on click
///   Add Segment | Edit Segment           Type ▾ Text ▾ Fill ▾ Left ▾ Right ▾
///   Presets    Shell Style · Plain Default · Classic BASIC
///   Generated Template  [ … ]                           template
/// ```
struct PromptEditorModel: Equatable {
    var segments = NerdPromptSegment.shellStylePreset
    var selectedSegmentID: NerdPromptSegment.ID?

    // The Add Segment form.
    var newKind: NerdPromptSegment.Kind = .currentDirectory
    var newForeground: NerdPromptColor = .white
    var newBackground: NerdPromptColor = .blue
    var newLeftEdge: NerdPromptSegmentEdge = .match
    var newRightEdge: NerdPromptSegmentEdge = .angled
    var newLiteral = "BASIC"

    static let plainDefaultTemplate = BASICSession.plainPromptTemplate
    static let classicBASICTemplate = "READY%nl> "
    static let tokenHelp = "Tokens: ${user}, ${currentdir}, ${gitstatus}, ${gitchanges}, %cwd, %git, %gitSegment, %nl"
    static let segmentListHelp = "Select a segment to edit it. Select it again or use New Segment to return to adding. Drag to reorder."
    static let noSelectionHelp = "Select a segment on the left to edit its type, text, and colors."

    /// The template these segments build.
    var template: String {
        NerdPromptTemplateBuilder.template(for: segments)
    }

    /// Editing a segment, rather than adding one.
    var isEditing: Bool {
        selectedSegmentID != nil
    }

    var selectedIndex: Int? {
        guard let selectedSegmentID else { return nil }
        return segments.firstIndex { $0.id == selectedSegmentID }
    }

    // MARK: Selection

    /// A click on a row: selects it, or deselects it if selected.
    mutating func toggleSelection(_ id: NerdPromptSegment.ID) {
        selectedSegmentID = selectedSegmentID == id ? nil : id
    }

    /// The row's Edit menu item.
    mutating func select(_ id: NerdPromptSegment.ID) {
        selectedSegmentID = id
    }

    /// New Segment, or Done: back to adding.
    mutating func deselect() {
        selectedSegmentID = nil
    }

    // MARK: Edits

    /// Adds a segment from the form and selects it.
    mutating func addNewSegment() {
        let segment = NerdPromptSegment(
            kind: newKind,
            literal: newKind == .literal ? newLiteral : "",
            foreground: newForeground,
            background: newBackground,
            leftEdge: newLeftEdge,
            rightEdge: newRightEdge
        )
        segments.append(segment)
        selectedSegmentID = segment.id
    }

    /// Drag to reorder: the rows at `source` land before `destination`,
    /// counted in the list as it was before the move.
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { segments[$0] }
        let insertion = destination - source.filter { $0 < destination }.count
        for index in source.reversed() {
            segments.remove(at: index)
        }
        segments.insert(contentsOf: moving, at: insertion)
    }

    /// Swipe to delete. When the selected row goes, the first row is
    /// selected.
    mutating func delete(atOffsets offsets: IndexSet) {
        let deletedIDs = offsets.map { segments[$0].id }
        for index in offsets.reversed() {
            segments.remove(at: index)
        }
        if let selectedSegmentID, deletedIDs.contains(selectedSegmentID) {
            self.selectedSegmentID = segments.first?.id
        }
    }

    /// The row's Delete menu item.
    mutating func delete(_ id: NerdPromptSegment.ID) {
        segments.removeAll { $0.id == id }
        if selectedSegmentID == id {
            selectedSegmentID = segments.first?.id
        }
    }

    /// The editor's Delete button: the next row takes the selection, or the
    /// last one when the deleted row was last.
    mutating func deleteSelected() {
        guard let selectedSegmentID,
              let index = segments.firstIndex(where: { $0.id == selectedSegmentID }) else { return }
        segments.remove(at: index)
        self.selectedSegmentID = segments[safe: min(index, segments.count - 1)]?.id ?? segments.last?.id
    }

    /// A copy after the selected segment, selected.
    mutating func duplicateSelected() {
        guard let selectedIndex else { return }
        let original = segments[selectedIndex]
        let duplicate = NerdPromptSegment(
            kind: original.kind,
            literal: original.literal,
            foreground: original.foreground,
            background: original.background,
            leftEdge: original.leftEdge,
            rightEdge: original.rightEdge
        )
        segments.insert(duplicate, at: selectedIndex + 1)
        selectedSegmentID = duplicate.id
    }

    /// Shell Style: the preset segments.
    mutating func applyShellStylePreset() {
        segments = NerdPromptSegment.shellStylePreset
    }

    /// Called when the template changed from outside the editor: a template
    /// that is exactly the preset's reloads the preset's segments.
    mutating func sync(fromTemplate template: String) {
        if template == NerdPromptTemplateBuilder.template(for: NerdPromptSegment.shellStylePreset) {
            segments = NerdPromptSegment.shellStylePreset
            selectedSegmentID = segments.first?.id
        }
    }

    // MARK: The selected segment

    /// The selected segment's fields, as the editor's pickers show them, and
    /// their defaults when nothing is selected.
    var selectedKind: NerdPromptSegment.Kind { selectedIndex.map { segments[$0].kind } ?? .literal }
    var selectedLiteral: String { selectedIndex.map { segments[$0].literal } ?? "" }
    var selectedForeground: NerdPromptColor { selectedIndex.map { segments[$0].foreground } ?? .white }
    var selectedBackground: NerdPromptColor { selectedIndex.map { segments[$0].background } ?? .blue }
    var selectedLeftEdge: NerdPromptSegmentEdge { selectedIndex.map { segments[$0].leftEdge } ?? .match }
    /// A right edge cannot match, so a stored `.match` shows as angled.
    var selectedRightEdge: NerdPromptSegmentEdge {
        guard let edge = selectedIndex.map({ segments[$0].rightEdge }) else { return .angled }
        return edge == .match ? .angled : edge
    }

    /// Changing the kind away from text clears the text.
    mutating func setSelectedKind(_ kind: NerdPromptSegment.Kind) {
        updateSelected {
            $0.kind = kind
            if kind != .literal {
                $0.literal = ""
            }
        }
    }

    mutating func setSelectedLiteral(_ literal: String) { updateSelected { $0.literal = literal } }
    mutating func setSelectedForeground(_ color: NerdPromptColor) { updateSelected { $0.foreground = color } }
    mutating func setSelectedBackground(_ color: NerdPromptColor) { updateSelected { $0.background = color } }
    mutating func setSelectedLeftEdge(_ edge: NerdPromptSegmentEdge) { updateSelected { $0.leftEdge = edge } }
    mutating func setSelectedRightEdge(_ edge: NerdPromptSegmentEdge) {
        updateSelected { $0.rightEdge = edge == .match ? .angled : edge }
    }

    private mutating func updateSelected(_ update: (inout NerdPromptSegment) -> Void) {
        guard let selectedIndex else { return }
        update(&segments[selectedIndex])
    }
}
