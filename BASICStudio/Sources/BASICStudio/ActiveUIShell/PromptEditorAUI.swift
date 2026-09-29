//
//  PromptEditorAUI.swift
//  BASICStudio
//
//  Settings ▸ General, the prompt editor, in ActiveUI.
//

import ActiveUI
import AppKit
import Foundation

/// The prompt editor for the ActiveUI shell. It holds a ``PromptEditorModel``
/// as its state, as `NerdPromptEditorView` does, and writes each edit's
/// template back to the model's prompt template.
///
/// ```text
///   Preview   [ os ][ ~/src ][ git ][ Ready ]
///   Segments                        │ Add Segment  or  Edit Segment
///   ▸ Current Directory   ●         │ Type ▾  Text ▾  Fill ▾  Left ▾  Right ▾
///   (drag to reorder;               │ Presets: Shell Style · Plain · Classic
///    right-click: Edit, Delete)     │ Generated Template [ … ]
///   [+ New Segment]                 │
/// ```
@MainActor
final class PromptEditorAUI {
    let model: StudioModel
    let root: AUIView
    private(set) var editor = PromptEditorModel()
    let preview: AUIStack
    let segmentTable: AUITable
    let addForm: SegmentForm
    let editForm: SegmentForm
    let editButtons: AUIStack
    let noSelectionLabel: AUILabel
    let templateField: AUITextField
    private let segments = SegmentStore()
    private var isWritingTemplate = false
    private var drawnEditor: PromptEditorModel?
    private var drawnTemplate: String?

    @MainActor
    private final class SegmentStore {
        var segments: [NerdPromptSegment] = []
    }

    init(model: StudioModel) {
        self.model = model

        preview = AUIStack(.horizontal, spacing: 0, alignment: .center)
        preview.wraps = false
        let previewScroll = AUIScrollView(.horizontal)
        previewScroll.addChild(preview)
        previewScroll.minimumSize = CGSize(width: 0, height: 40)
        previewScroll.backgroundColor = .textBackground
        previewScroll.cornerRadius = 8

        let segments = segments
        segmentTable = AUITable(rowCount: { segments.segments.count }) { index in
            Self.segmentRow(segments.segments[index])
        }
        segmentTable.minimumSize = CGSize(width: 260, height: 180)
        segmentTable.allowsReordering = true
        let newSegment = AUIButton("New Segment")
        newSegment.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        let segmentHelp = Self.caption(PromptEditorModel.segmentListHelp)
        segmentHelp.wraps = true
        segmentHelp.lineLimit = nil

        addForm = SegmentForm(title: "Add Segment", editsSelection: false)
        editForm = SegmentForm(title: "Edit Segment", editsSelection: true)
        noSelectionLabel = Self.caption(PromptEditorModel.noSelectionHelp)
        let done = AUIButton("Done")
        let duplicate = AUIButton("Duplicate")
        let delete = AUIButton("Delete")
        editButtons = LogPaneAUI.row([done, duplicate, delete])

        let shellStyle = AUIButton("Shell Style")
        let plain = AUIButton("Plain Default")
        let classic = AUIButton("Classic BASIC")
        templateField = AUITextField("", placeholder: "Prompt template")
        templateField.maximumNumberOfLines = 7
        templateField.holdsCode = true
        // AUITextField has no font of its own; the template reads best monospaced.
        (templateField.nativeView as? NSTextField)?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        templateField.flexibility = .horizontal()

        let left = Self.column([
            Self.caption("Segments", bold: true), segmentTable, newSegment, segmentHelp,
        ])
        left.minimumSize = CGSize(width: 260, height: 0)
        let right = Self.column([
            addForm.root, editForm.root, noSelectionLabel, editButtons,
            Self.caption("Presets", bold: true), LogPaneAUI.row([shellStyle, plain, classic]),
            Self.caption("Generated Template", bold: true), templateField,
            Self.caption(PromptEditorModel.tokenHelp),
        ])
        right.minimumSize = CGSize(width: 260, height: 0)
        let columns = AUIStack(.horizontal, spacing: 14, alignment: .leading)
        columns.wraps = false
        columns.addChild(left.stretches())
        columns.addChild(right.stretches())

        root = Self.column([Self.caption("Preview", bold: true), previewScroll, columns], spacing: 14)
        root.padding = AUIEdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)

        // Actions. Each edit goes through `commit`, as the SwiftUI view's do.
        segmentTable.onSelectionChange = { [weak self] rows in
            guard let self, let row = rows.first, self.editor.segments.indices.contains(row) else { return }
            self.editor.select(self.editor.segments[row].id)
            self.refresh()
        }
        segmentTable.onReorder = { [weak self] from, to in
            // The table reports where the row ends up; the model takes the
            // offset before the move, as SwiftUI's onMove does.
            self?.commit { $0.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to) }
        }
        newSegment.onClick = { [weak self] in self?.deselect() }
        done.onClick = { [weak self] in self?.deselect() }
        duplicate.onClick = { [weak self] in self?.commit { $0.duplicateSelected() } }
        delete.onClick = { [weak self] in self?.commit { $0.deleteSelected() } }
        shellStyle.onClick = { [weak self] in self?.commit { $0.applyShellStylePreset() } }
        plain.onClick = { [weak model] in model?.promptTemplate = PromptEditorModel.plainDefaultTemplate }
        classic.onClick = { [weak model] in model?.promptTemplate = PromptEditorModel.classicBASICTemplate }
        templateField.onChange = { [weak model] text in model?.promptTemplate = text }
        addForm.onChange = { [weak self] in self?.applyAddForm($0) }
        addForm.onAdd = { [weak self] in self?.commit { $0.addNewSegment() } }
        editForm.onChange = { [weak self] in self?.applyEditForm($0) }

        editor.sync(fromTemplate: model.promptTemplate)
        refresh()
    }

    // MARK: Edits

    /// Makes an edit and writes the segments' template back, without the
    /// write coming back around as an outside change.
    func commit(_ edit: (inout PromptEditorModel) -> Void) {
        edit(&editor)
        isWritingTemplate = true
        model.promptTemplate = editor.template
        isWritingTemplate = false
        refresh()
    }

    private func deselect() {
        editor.deselect()
        refresh()
    }

    private func applyAddForm(_ change: SegmentForm.Change) {
        switch change {
        case .kind(let kind): editor.newKind = kind
        case .literal(let text): editor.newLiteral = text
        case .foreground(let color): editor.newForeground = color
        case .background(let color): editor.newBackground = color
        case .leftEdge(let edge): editor.newLeftEdge = edge
        case .rightEdge(let edge): editor.newRightEdge = edge
        }
        refresh()
    }

    private func applyEditForm(_ change: SegmentForm.Change) {
        commit {
            switch change {
            case .kind(let kind): $0.setSelectedKind(kind)
            case .literal(let text): $0.setSelectedLiteral(text)
            case .foreground(let color): $0.setSelectedForeground(color)
            case .background(let color): $0.setSelectedBackground(color)
            case .leftEdge(let edge): $0.setSelectedLeftEdge(edge)
            case .rightEdge(let edge): $0.setSelectedRightEdge(edge)
            }
        }
    }

    // MARK: Drawing

    /// Brings the pane up to its editor and the model's template.
    func refresh() {
        if model.promptTemplate != drawnTemplate {
            if !isWritingTemplate {
                editor.sync(fromTemplate: model.promptTemplate)
            }
            if templateField.text != model.promptTemplate {
                templateField.text = model.promptTemplate
            }
            drawnTemplate = model.promptTemplate
        }
        guard editor != drawnEditor else { return }
        if editor.segments != drawnEditor?.segments {
            segments.segments = editor.segments
            segmentTable.reloadData()
            drawPreview()
        }
        segmentTable.selectedRows = editor.selectedIndex.map { [$0] } ?? []
        addForm.root.isHidden = editor.isEditing
        editForm.root.isHidden = !editor.isEditing || editor.selectedIndex == nil
        editButtons.isHidden = editForm.root.isHidden
        noSelectionLabel.isHidden = !editor.isEditing || editor.selectedIndex != nil
        addForm.show(kind: editor.newKind, literal: editor.newLiteral, foreground: editor.newForeground,
                     background: editor.newBackground, leftEdge: editor.newLeftEdge, rightEdge: editor.newRightEdge)
        editForm.show(kind: editor.selectedKind, literal: editor.selectedLiteral, foreground: editor.selectedForeground,
                      background: editor.selectedBackground, leftEdge: editor.selectedLeftEdge, rightEdge: editor.selectedRightEdge)
        drawnEditor = editor
        root.invalidateLayout()
    }

    /// The preview: each segment's glyphs and text in its colors, joined the
    /// way `NerdPromptSegmentPreview` joins them.
    private func drawPreview() {
        preview.removeAllChildren()
        let segments = editor.segments
        for (index, segment) in segments.enumerated() {
            let previous = segments[safe: index - 1]
            let next = segments[safe: index + 1]
            if let glyph = segment.leftEdge.matchedLeftGlyph(previousRightEdge: previous?.rightEdge), let previous {
                preview.addChild(Self.piece(glyph, foreground: previous.background, background: segment.background))
            } else if let glyph = segment.leftEdge.leftGlyph {
                preview.addChild(Self.piece(glyph, foreground: segment.background, background: .terminalBackground))
            }
            preview.addChild(Self.piece(" \(segment.previewText) ", foreground: segment.foreground, background: segment.background))
            if next?.leftEdge != .match, let glyph = segment.rightEdge.rightGlyph {
                preview.addChild(Self.piece(glyph, foreground: segment.background, background: next?.background ?? .terminalBackground))
            }
        }
        preview.addChild(Self.piece(" ", foreground: .white, background: .terminalBackground))
    }

    private static func piece(_ text: String, foreground: NerdPromptColor, background: NerdPromptColor) -> AUILabel {
        let label = AUILabel(text)
        label.font = promptFont(size: 14, bold: true)
        label.textColor = foreground.auiColor
        label.backgroundColor = background.auiColor
        return label
    }

    static func promptFont(size: CGFloat, bold: Bool) -> AUIFont {
        let base = NSFont(name: StudioFonts.defaultFamily, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        return AUIFont(bold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base)
    }

    /// One row of the segment list: icon, title over template source, color
    /// dot, and a right-click menu with Edit and Delete.
    private static func segmentRow(_ segment: NerdPromptSegment) -> AUIView {
        let icon = AUILabel(segment.kind.icon)
        icon.font = promptFont(size: 13, bold: false)
        icon.minimumSize = CGSize(width: 18, height: 0)
        let title = AUILabel(segment.title)
        let source = AUILabel(segment.templateSource)
        source.font = .monospaced(size: 10)
        source.textColor = .secondary
        let text = column([title, source], spacing: 2)
        let dot = AUIView()
        dot.backgroundColor = segment.background.auiColor
        dot.cornerRadius = 6
        dot.minimumSize = CGSize(width: 12, height: 12)
        dot.maximumSize = CGSize(width: 12, height: 12)
        let row = LogPaneAUI.row([icon, text, AUISpacer(), dot])
        row.padding = AUIEdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4)
        return row
    }

    static func caption(_ text: String, bold: Bool = false) -> AUILabel {
        let label = AUILabel(text)
        label.font = .caption
        label.textColor = .secondary
        label.isBold = bold
        return label
    }

    static func column(_ views: [AUIView], spacing: CGFloat = 8) -> AUIStack {
        let stack = AUIStack(.vertical, spacing: spacing, alignment: .fill)
        stack.wraps = false
        views.forEach(stack.addChild)
        return stack
    }
}

/// The five pickers and the text field that describe one segment, used twice:
/// once to add, once to edit the selection.
@MainActor
final class SegmentForm {
    enum Change {
        case kind(NerdPromptSegment.Kind)
        case literal(String)
        case foreground(NerdPromptColor)
        case background(NerdPromptColor)
        case leftEdge(NerdPromptSegmentEdge)
        case rightEdge(NerdPromptSegmentEdge)
    }

    let root: AUIStack
    let kind = AUIPicker(NerdPromptSegment.Kind.allCases.map(\.title))
    let literal = AUITextField("", placeholder: "Text")
    let foreground = AUIPicker(NerdPromptColor.allCases.map(\.title))
    let background = AUIPicker(NerdPromptColor.allCases.map(\.title))
    let leftEdge = AUIPicker(NerdPromptSegmentEdge.leftChoices.map(\.title))
    let rightEdge = AUIPicker(NerdPromptSegmentEdge.rightChoices.map(\.title))
    let add = AUIButton("Add")
    var onChange: ((Change) -> Void)?
    var onAdd: (() -> Void)?

    init(title: String, editsSelection: Bool) {
        let form = AUIForm()
        form.addRow("Type", kind)
        form.addRow("Text", literal)
        form.addRow("Text color", foreground)
        form.addRow("Fill", background)
        form.addRow("Left", leftEdge)
        form.addRow("Right", rightEdge)
        var views: [AUIView] = [PromptEditorAUI.caption(title, bold: true), form]
        if !editsSelection {
            add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            views.append(add)
        }
        root = PromptEditorAUI.column(views)

        kind.onSelectionChange = { [weak self] in self?.onChange?(.kind(NerdPromptSegment.Kind.allCases[$0])) }
        literal.onChange = { [weak self] in self?.onChange?(.literal($0)) }
        foreground.onSelectionChange = { [weak self] in self?.onChange?(.foreground(NerdPromptColor.allCases[$0])) }
        background.onSelectionChange = { [weak self] in self?.onChange?(.background(NerdPromptColor.allCases[$0])) }
        leftEdge.onSelectionChange = { [weak self] in self?.onChange?(.leftEdge(NerdPromptSegmentEdge.leftChoices[$0])) }
        rightEdge.onSelectionChange = { [weak self] in self?.onChange?(.rightEdge(NerdPromptSegmentEdge.rightChoices[$0])) }
        add.onClick = { [weak self] in self?.onAdd?() }
    }

    /// Shows a segment's fields. The text field shows only for a Text segment.
    func show(kind: NerdPromptSegment.Kind, literal: String, foreground: NerdPromptColor,
              background: NerdPromptColor, leftEdge: NerdPromptSegmentEdge, rightEdge: NerdPromptSegmentEdge) {
        self.kind.selectedIndex = NerdPromptSegment.Kind.allCases.firstIndex(of: kind)
        if self.literal.text != literal { self.literal.text = literal }
        self.literal.isHidden = kind != .literal
        self.foreground.selectedIndex = NerdPromptColor.allCases.firstIndex(of: foreground)
        self.background.selectedIndex = NerdPromptColor.allCases.firstIndex(of: background)
        self.leftEdge.selectedIndex = NerdPromptSegmentEdge.leftChoices.firstIndex(of: leftEdge)
        self.rightEdge.selectedIndex = NerdPromptSegmentEdge.rightChoices.firstIndex(of: rightEdge)
    }
}

extension NerdPromptColor {
    /// The same colors `NerdPromptColor.color` gives SwiftUI.
    var auiColor: AUIColor {
        switch self {
        case .terminalBackground: .textBackground
        case .black: .black
        case .white: .white
        case .silver: AUIColor(red: 0.78, green: 0.80, blue: 0.84)
        case .blue: AUIColor(red: 0.26, green: 0.18, blue: 0.90)
        case .purple: AUIColor(red: 0.42, green: 0.22, blue: 0.95)
        case .gold: AUIColor(red: 0.70, green: 0.68, blue: 0.18)
        case .green: AUIColor(red: 0.18, green: 0.78, blue: 0.22)
        case .red: AUIColor(red: 0.92, green: 0.18, blue: 0.16)
        }
    }
}
