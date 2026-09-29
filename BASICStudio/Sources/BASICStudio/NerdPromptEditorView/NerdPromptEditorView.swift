import BASICCore
import SwiftUI

struct NerdPromptEditorView: View {
    @Binding var promptTemplate: String

    /// The segments, the selection and the Add form. Every edit goes through
    /// it, and then its template is written back (``commit(_:)``).
    @State private var editor = PromptEditorModel()
    @State private var isSyncingFromTemplate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            promptPreview

            HStack(alignment: .top, spacing: 14) {
                segmentList
                    .frame(minWidth: 260)

                VStack(alignment: .leading, spacing: 12) {
                    if !editor.isEditing {
                        addSegmentControls
                    } else {
                        segmentInspector
                    }
                    presetControls
                    rawTemplateEditor
                }
                .frame(minWidth: 260)
            }
        }
        .onAppear {
            syncFromTemplateIfNeeded()
        }
        .onChange(of: promptTemplate) { _, _ in
            syncFromTemplateIfNeeded()
        }
    }

    private var promptPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(editor.segments.enumerated()), id: \.element.id) { index, segment in
                        NerdPromptSegmentPreview(
                            previousSegment: editor.segments[safe: index - 1],
                            segment: segment,
                            nextSegment: editor.segments[safe: index + 1]
                        )
                    }
                    Text(" ")
                        .font(.custom(StudioFonts.defaultFamily, size: 14))
                        .foregroundStyle(.primary)
                }
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.25))
            )
        }
    }

    private var segmentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Segments")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            List {
                ForEach(editor.segments) { segment in
                    Button {
                        editor.toggleSelection(segment.id)
                    } label: {
                        HStack(spacing: 8) {
                            Text(segment.kind.icon)
                                .font(.custom(StudioFonts.defaultFamily, size: 13))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(segment.title)
                                Text(segment.templateSource)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Circle()
                                .fill(segment.background.color)
                                .frame(width: 12, height: 12)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(segment.id == editor.selectedSegmentID ? Color.accentColor.opacity(0.18) : Color.clear)
                    .contextMenu {
                        Button("Edit") {
                            editor.select(segment.id)
                        }
                        Button("Delete") {
                            commit { $0.delete(segment.id) }
                        }
                    }
                }
                .onMove { source, destination in
                    commit { $0.move(fromOffsets: source, toOffset: destination) }
                }
                .onDelete { offsets in
                    commit { $0.delete(atOffsets: offsets) }
                }
            }
            .frame(minHeight: 180)

            Button {
                editor.deselect()
            } label: {
                Label("New Segment", systemImage: "plus")
            }
            .buttonStyle(.bordered)

            Text(PromptEditorModel.segmentListHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var segmentInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Edit Segment")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let selectedIndex = editor.selectedIndex {
                Picker("Type", selection: selectedBinding(\.selectedKind) { $0.setSelectedKind($1) }) {
                    ForEach(NerdPromptSegment.Kind.allCases, id: \.self) { kind in
                        Label(kind.title, systemImage: kind.systemImage).tag(kind)
                    }
                }
                .pickerStyle(.menu)

                if editor.segments[selectedIndex].kind == .literal {
                    TextField("Text", text: selectedBinding(\.selectedLiteral) { $0.setSelectedLiteral($1) })
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Picker("Text", selection: selectedBinding(\.selectedForeground) { $0.setSelectedForeground($1) }) {
                        ForEach(NerdPromptColor.allCases, id: \.self) { color in
                            Text(color.title).tag(color)
                        }
                    }

                    Picker("Fill", selection: selectedBinding(\.selectedBackground) { $0.setSelectedBackground($1) }) {
                        ForEach(NerdPromptColor.allCases, id: \.self) { color in
                            Text(color.title).tag(color)
                        }
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Picker("Left", selection: selectedBinding(\.selectedLeftEdge) { $0.setSelectedLeftEdge($1) }) {
                        ForEach(NerdPromptSegmentEdge.leftChoices, id: \.self) { edge in
                            Text(edge.title).tag(edge)
                        }
                    }

                    Picker("Right", selection: selectedBinding(\.selectedRightEdge) { $0.setSelectedRightEdge($1) }) {
                        ForEach(NerdPromptSegmentEdge.rightChoices, id: \.self) { edge in
                            Text(edge.title).tag(edge)
                        }
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Button {
                        editor.deselect()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }

                    Button {
                        commit { $0.duplicateSelected() }
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }

                    Button(role: .destructive) {
                        commit { $0.deleteSelected() }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } else {
                Text(PromptEditorModel.noSelectionHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
        }
    }

    private var addSegmentControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Segment")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Type", selection: $editor.newKind) {
                ForEach(NerdPromptSegment.Kind.allCases, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.systemImage).tag(kind)
                }
            }
            .pickerStyle(.menu)

            if editor.newKind == .literal {
                TextField("Text", text: $editor.newLiteral)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Picker("Text", selection: $editor.newForeground) {
                    ForEach(NerdPromptColor.allCases, id: \.self) { color in
                        Text(color.title).tag(color)
                    }
                }

                Picker("Fill", selection: $editor.newBackground) {
                    ForEach(NerdPromptColor.allCases, id: \.self) { color in
                        Text(color.title).tag(color)
                    }
                }
            }
            .pickerStyle(.menu)

            HStack {
                Picker("Left", selection: $editor.newLeftEdge) {
                    ForEach(NerdPromptSegmentEdge.leftChoices, id: \.self) { edge in
                        Text(edge.title).tag(edge)
                    }
                }

                Picker("Right", selection: $editor.newRightEdge) {
                    ForEach(NerdPromptSegmentEdge.rightChoices, id: \.self) { edge in
                        Text(edge.title).tag(edge)
                    }
                }
            }
            .pickerStyle(.menu)

            Button {
                commit { $0.addNewSegment() }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }

    private var presetControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Presets")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack {
                Button("Shell Style") {
                    commit { $0.applyShellStylePreset() }
                }

                Button("Plain Default") {
                    promptTemplate = PromptEditorModel.plainDefaultTemplate
                }

                Button("Classic BASIC") {
                    promptTemplate = PromptEditorModel.classicBASICTemplate
                }
            }
        }
    }

    private var rawTemplateEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Generated Template")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("Prompt template", text: $promptTemplate, axis: .vertical)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(4...7)
                .textFieldStyle(.roundedBorder)

            Text(PromptEditorModel.tokenHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A picker's binding to one field of the selected segment.
    private func selectedBinding<Value>(
        _ field: KeyPath<PromptEditorModel, Value>,
        set: @escaping (inout PromptEditorModel, Value) -> Void
    ) -> Binding<Value> {
        Binding {
            editor[keyPath: field]
        } set: { newValue in
            commit { set(&$0, newValue) }
        }
    }

    /// Makes an edit, then writes the segments' template back, without the
    /// write coming back around as an outside change.
    private func commit(_ edit: (inout PromptEditorModel) -> Void) {
        edit(&editor)
        isSyncingFromTemplate = true
        promptTemplate = editor.template
        isSyncingFromTemplate = false
    }

    private func syncFromTemplateIfNeeded() {
        guard !isSyncingFromTemplate else { return }
        editor.sync(fromTemplate: promptTemplate)
    }
}

private struct NerdPromptSegmentPreview: View {
    let previousSegment: NerdPromptSegment?
    let segment: NerdPromptSegment
    let nextSegment: NerdPromptSegment?

    var body: some View {
        HStack(spacing: 0) {
            if let matchedGlyph = segment.leftEdge.matchedLeftGlyph(previousRightEdge: previousSegment?.rightEdge),
               let previousSegment {
                Text(matchedGlyph)
                    .font(.custom(StudioFonts.defaultFamily, size: 14).weight(.bold))
                    .foregroundStyle(previousSegment.background.color)
                    .background(segment.background.color)
            } else if let leftGlyph = segment.leftEdge.leftGlyph {
                Text(leftGlyph)
                    .font(.custom(StudioFonts.defaultFamily, size: 14).weight(.bold))
                    .foregroundStyle(segment.background.color)
                    .background(Color(nsColor: .textBackgroundColor))
            }

            Text(" \(segment.previewText) ")
                .font(.custom(StudioFonts.defaultFamily, size: 14).weight(.bold))
                .foregroundStyle(segment.foreground.color)
                .lineLimit(1)
                .padding(.vertical, 3)
                .background(segment.background.color)

            if nextSegment?.leftEdge != .match,
               let rightGlyph = segment.rightEdge.rightGlyph {
                Text(rightGlyph)
                    .font(.custom(StudioFonts.defaultFamily, size: 14).weight(.bold))
                    .foregroundStyle(segment.background.color)
                    .background((nextSegment?.background ?? .terminalBackground).color)
            }
        }
    }
}

extension NerdPromptColor {
    var color: Color {
        switch self {
        case .terminalBackground: return Color(nsColor: .textBackgroundColor)
        case .black: return .black
        case .white: return .white
        case .silver: return Color(red: 0.78, green: 0.80, blue: 0.84)
        case .blue: return Color(red: 0.26, green: 0.18, blue: 0.90)
        case .purple: return Color(red: 0.42, green: 0.22, blue: 0.95)
        case .gold: return Color(red: 0.70, green: 0.68, blue: 0.18)
        case .green: return Color(red: 0.18, green: 0.78, blue: 0.22)
        case .red: return Color(red: 0.92, green: 0.18, blue: 0.16)
        }
    }
}

#if DEBUG
private struct NerdPromptEditorView_Previews: PreviewProvider {
    private struct PreviewContainer: View {
        @State var prompt = BASICSession.nerdFontPromptTemplate

        var body: some View {
            NerdPromptEditorView(promptTemplate: $prompt)
                .frame(width: 720, height: 460)
                .padding()
        }
    }

    static var previews: some View {
        PreviewContainer()
    }
}
#endif
