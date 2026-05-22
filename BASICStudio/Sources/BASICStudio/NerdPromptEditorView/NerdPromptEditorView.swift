import BASICCore
import SwiftUI

struct NerdPromptEditorView: View {
    @Binding var promptTemplate: String

    @State private var segments = NerdPromptSegment.shellStylePreset
    @State private var selectedKind: NerdPromptSegment.Kind = .currentDirectory
    @State private var selectedForeground: NerdPromptColor = .white
    @State private var selectedBackground: NerdPromptColor = .blue
    @State private var selectedLeftEdge: NerdPromptSegmentEdge = .match
    @State private var selectedRightEdge: NerdPromptSegmentEdge = .angled
    @State private var selectedLiteral = "BASIC"
    @State private var selectedSegmentID: NerdPromptSegment.ID?
    @State private var isSyncingFromTemplate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            promptPreview

            HStack(alignment: .top, spacing: 14) {
                segmentList
                    .frame(minWidth: 260)

                VStack(alignment: .leading, spacing: 12) {
                    if selectedSegmentID == nil {
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
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        NerdPromptSegmentPreview(
                            previousSegment: segments[safe: index - 1],
                            segment: segment,
                            nextSegment: segments[safe: index + 1]
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
                ForEach(segments) { segment in
                    Button {
                        if selectedSegmentID == segment.id {
                            selectedSegmentID = nil
                        } else {
                            selectedSegmentID = segment.id
                        }
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
                    .listRowBackground(segment.id == selectedSegmentID ? Color.accentColor.opacity(0.18) : Color.clear)
                    .contextMenu {
                        Button("Edit") {
                            selectedSegmentID = segment.id
                        }
                        Button("Delete") {
                            delete(segment)
                        }
                    }
                }
                .onMove(perform: moveSegments)
                .onDelete(perform: deleteSegments)
            }
            .frame(minHeight: 180)

            Button {
                selectedSegmentID = nil
            } label: {
                Label("New Segment", systemImage: "plus")
            }
            .buttonStyle(.bordered)

            Text("Select a segment to edit it. Select it again or use New Segment to return to adding. Drag to reorder.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var segmentInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Edit Segment")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let selectedIndex {
                Picker("Type", selection: selectedKindBinding) {
                    ForEach(NerdPromptSegment.Kind.allCases, id: \.self) { kind in
                        Label(kind.title, systemImage: kind.systemImage).tag(kind)
                    }
                }
                .pickerStyle(.menu)

                if segments[selectedIndex].kind == .literal {
                    TextField("Text", text: selectedLiteralBinding)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Picker("Text", selection: selectedForegroundBinding) {
                        ForEach(NerdPromptColor.allCases, id: \.self) { color in
                            Text(color.title).tag(color)
                        }
                    }

                    Picker("Fill", selection: selectedBackgroundBinding) {
                        ForEach(NerdPromptColor.allCases, id: \.self) { color in
                            Text(color.title).tag(color)
                        }
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Picker("Left", selection: selectedLeftEdgeBinding) {
                        ForEach(NerdPromptSegmentEdge.leftChoices, id: \.self) { edge in
                            Text(edge.title).tag(edge)
                        }
                    }

                    Picker("Right", selection: selectedRightEdgeBinding) {
                        ForEach(NerdPromptSegmentEdge.rightChoices, id: \.self) { edge in
                            Text(edge.title).tag(edge)
                        }
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Button {
                        selectedSegmentID = nil
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }

                    Button {
                        duplicateSelectedSegment()
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }

                    Button(role: .destructive) {
                        deleteSelectedSegment()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } else {
                Text("Select a segment on the left to edit its type, text, and colors.")
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

            Picker("Type", selection: $selectedKind) {
                ForEach(NerdPromptSegment.Kind.allCases, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.systemImage).tag(kind)
                }
            }
            .pickerStyle(.menu)

            if selectedKind == .literal {
                TextField("Text", text: $selectedLiteral)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Picker("Text", selection: $selectedForeground) {
                    ForEach(NerdPromptColor.allCases, id: \.self) { color in
                        Text(color.title).tag(color)
                    }
                }

                Picker("Fill", selection: $selectedBackground) {
                    ForEach(NerdPromptColor.allCases, id: \.self) { color in
                        Text(color.title).tag(color)
                    }
                }
            }
            .pickerStyle(.menu)

            HStack {
                Picker("Left", selection: $selectedLeftEdge) {
                    ForEach(NerdPromptSegmentEdge.leftChoices, id: \.self) { edge in
                        Text(edge.title).tag(edge)
                    }
                }

                Picker("Right", selection: $selectedRightEdge) {
                    ForEach(NerdPromptSegmentEdge.rightChoices, id: \.self) { edge in
                        Text(edge.title).tag(edge)
                    }
                }
            }
            .pickerStyle(.menu)

            Button {
                addSelectedSegment()
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
                    segments = NerdPromptSegment.shellStylePreset
                    updateTemplateFromSegments()
                }

                Button("Plain Default") {
                    promptTemplate = BASICSession.plainPromptTemplate
                }

                Button("Classic BASIC") {
                    promptTemplate = "READY%nl> "
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

            Text("Tokens: ${user}, ${currentdir}, ${gitstatus}, %cwd, %git, %gitSegment, %nl")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addSelectedSegment() {
        let literal = selectedKind == .literal ? selectedLiteral : ""
        let segment = NerdPromptSegment(
            kind: selectedKind,
            literal: literal,
            foreground: selectedForeground,
            background: selectedBackground,
            leftEdge: selectedLeftEdge,
            rightEdge: selectedRightEdge
        )
        segments.append(segment)
        selectedSegmentID = segment.id
        updateTemplateFromSegments()
    }

    private func moveSegments(from source: IndexSet, to destination: Int) {
        segments.move(fromOffsets: source, toOffset: destination)
        updateTemplateFromSegments()
    }

    private func deleteSegments(at offsets: IndexSet) {
        let deletedIDs = offsets.map { segments[$0].id }
        segments.remove(atOffsets: offsets)
        if let selectedSegmentID, deletedIDs.contains(selectedSegmentID) {
            self.selectedSegmentID = segments.first?.id
        }
        updateTemplateFromSegments()
    }

    private func delete(_ segment: NerdPromptSegment) {
        segments.removeAll { $0.id == segment.id }
        if selectedSegmentID == segment.id {
            selectedSegmentID = segments.first?.id
        }
        updateTemplateFromSegments()
    }

    private func deleteSelectedSegment() {
        guard let selectedSegmentID,
              let index = segments.firstIndex(where: { $0.id == selectedSegmentID }) else { return }
        segments.remove(at: index)
        self.selectedSegmentID = segments[safe: min(index, segments.count - 1)]?.id ?? segments.last?.id
        updateTemplateFromSegments()
    }

    private func duplicateSelectedSegment() {
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
        updateTemplateFromSegments()
    }

    private var selectedIndex: Int? {
        guard let selectedSegmentID else { return nil }
        return segments.firstIndex { $0.id == selectedSegmentID }
    }

    private var selectedKindBinding: Binding<NerdPromptSegment.Kind> {
        Binding {
            selectedIndex.map { segments[$0].kind } ?? .literal
        } set: { newKind in
            updateSelectedSegment {
                $0.kind = newKind
                if newKind != .literal {
                    $0.literal = ""
                }
            }
        }
    }

    private var selectedLiteralBinding: Binding<String> {
        Binding {
            selectedIndex.map { segments[$0].literal } ?? ""
        } set: { newValue in
            updateSelectedSegment { $0.literal = newValue }
        }
    }

    private var selectedForegroundBinding: Binding<NerdPromptColor> {
        Binding {
            selectedIndex.map { segments[$0].foreground } ?? .white
        } set: { newColor in
            updateSelectedSegment { $0.foreground = newColor }
        }
    }

    private var selectedBackgroundBinding: Binding<NerdPromptColor> {
        Binding {
            selectedIndex.map { segments[$0].background } ?? .blue
        } set: { newColor in
            updateSelectedSegment { $0.background = newColor }
        }
    }

    private var selectedLeftEdgeBinding: Binding<NerdPromptSegmentEdge> {
        Binding {
            selectedIndex.map { segments[$0].leftEdge } ?? .match
        } set: { newEdge in
            updateSelectedSegment { $0.leftEdge = newEdge }
        }
    }

    private var selectedRightEdgeBinding: Binding<NerdPromptSegmentEdge> {
        Binding {
            guard let edge = selectedIndex.map({ segments[$0].rightEdge }) else { return .angled }
            return edge == .match ? .angled : edge
        } set: { newEdge in
            updateSelectedSegment { $0.rightEdge = newEdge == .match ? .angled : newEdge }
        }
    }

    private func updateSelectedSegment(_ update: (inout NerdPromptSegment) -> Void) {
        guard let selectedIndex else { return }
        update(&segments[selectedIndex])
        updateTemplateFromSegments()
    }

    private func updateTemplateFromSegments() {
        isSyncingFromTemplate = true
        promptTemplate = NerdPromptTemplateBuilder.template(for: segments)
        isSyncingFromTemplate = false
    }

    private func syncFromTemplateIfNeeded() {
        guard !isSyncingFromTemplate else { return }
        if promptTemplate == NerdPromptTemplateBuilder.template(for: NerdPromptSegment.shellStylePreset) {
            segments = NerdPromptSegment.shellStylePreset
            selectedSegmentID = segments.first?.id
        }
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

private struct NerdPromptSegment: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case os
        case home
        case currentDirectory
        case gitBranch
        case gitStatus
        case user
        case literal
        case newline

        var title: String {
            switch self {
            case .os: return "macOS Icon"
            case .home: return "Home"
            case .currentDirectory: return "Current Directory"
            case .gitBranch: return "Git Branch"
            case .gitStatus: return "Git Status"
            case .user: return "User"
            case .literal: return "Text"
            case .newline: return "New Line"
            }
        }

        var icon: String {
            switch self {
            case .os: return ""
            case .home: return ""
            case .currentDirectory: return ""
            case .gitBranch: return ""
            case .gitStatus: return "!"
            case .user: return ""
            case .literal: return "T"
            case .newline: return "↵"
            }
        }

        var systemImage: String {
            switch self {
            case .os: return "desktopcomputer"
            case .home: return "house"
            case .currentDirectory: return "folder"
            case .gitBranch: return "point.3.connected.trianglepath.dotted"
            case .gitStatus: return "exclamationmark.triangle"
            case .user: return "person"
            case .literal: return "textformat"
            case .newline: return "return"
            }
        }
    }

    let id = UUID()
    var kind: Kind
    var literal: String = ""
    var foreground: NerdPromptColor
    var background: NerdPromptColor
    var leftEdge: NerdPromptSegmentEdge = .match
    var rightEdge: NerdPromptSegmentEdge = .angled

    var title: String {
        kind == .literal ? "Text: \(literal)" : kind.title
    }

    var previewText: String {
        switch kind {
        case .os: return ""
        case .home: return " ~"
        case .currentDirectory: return " ~/src/AIBasic/Code"
        case .gitBranch: return "git  feature/classes"
        case .gitStatus: return "!1 ⇡2"
        case .user: return "bobby"
        case .literal: return literal.isEmpty ? "Text" : literal
        case .newline: return "↵"
        }
    }

    var templateSource: String {
        switch kind {
        case .os: return ""
        case .home: return " ~"
        case .currentDirectory: return " ${currentdir}"
        case .gitBranch: return "git  ${gitstatus}"
        case .gitStatus: return "!1"
        case .user: return "${user}"
        case .literal: return literal
        case .newline: return "%nl"
        }
    }

    static let shellStylePreset: [NerdPromptSegment] = [
        NerdPromptSegment(kind: .os, foreground: .black, background: .silver),
        NerdPromptSegment(kind: .currentDirectory, foreground: .white, background: .purple),
        NerdPromptSegment(kind: .gitBranch, foreground: .black, background: .gold),
        NerdPromptSegment(kind: .gitStatus, literal: "!1", foreground: .black, background: .gold),
        NerdPromptSegment(kind: .literal, literal: "Ready", foreground: .black, background: .green)
    ]
}

private enum NerdPromptColor: String, CaseIterable {
    case terminalBackground
    case black
    case white
    case silver
    case blue
    case purple
    case gold
    case green
    case red

    var title: String {
        switch self {
        case .terminalBackground: return "Terminal"
        case .black: return "Black"
        case .white: return "White"
        case .silver: return "Silver"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .gold: return "Gold"
        case .green: return "Green"
        case .red: return "Red"
        }
    }

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

    var ansiCode: Int {
        switch self {
        case .terminalBackground: return 0
        case .black: return 16
        case .white: return 15
        case .silver: return 250
        case .blue: return 57
        case .purple: return 99
        case .gold: return 142
        case .green: return 40
        case .red: return 196
        }
    }
}

private enum NerdPromptSegmentEdge: String, CaseIterable {
    case match
    case rounded
    case angled
    case flat

    var title: String {
        switch self {
        case .match: return "Match"
        case .rounded: return "Rounded"
        case .angled: return "Angled"
        case .flat: return "Flat"
        }
    }

    static let leftChoices: [NerdPromptSegmentEdge] = [.match, .rounded, .angled, .flat]
    static let rightChoices: [NerdPromptSegmentEdge] = [.rounded, .angled, .flat]

    var leftGlyph: String? {
        switch self {
        case .match: return nil
        case .rounded: return ""
        case .angled: return ""
        case .flat: return nil
        }
    }

    var rightGlyph: String? {
        switch self {
        case .match: return nil
        case .rounded: return ""
        case .angled: return ""
        case .flat: return nil
        }
    }

    func matchedLeftGlyph(previousRightEdge: NerdPromptSegmentEdge?) -> String? {
        guard self == .match else { return nil }
        return previousRightEdge?.rightGlyph
    }
}

private enum NerdPromptTemplateBuilder {
    static func template(for segments: [NerdPromptSegment]) -> String {
        guard !segments.isEmpty else { return BASICSession.defaultPromptTemplate }
        var output = ""
        for index in segments.indices {
            let segment = segments[index]
            if segment.kind == .newline {
                output += "%nl"
                continue
            }

            let previousSegment = segments[safe: index - 1]
            if let matchedGlyph = segment.leftEdge.matchedLeftGlyph(previousRightEdge: previousSegment?.rightEdge),
               let previousSegment {
                output += sgr(foreground: previousSegment.background, background: segment.background)
                output += matchedGlyph
            } else if let leftGlyph = segment.leftEdge.leftGlyph {
                let leftBackground = segment.leftEdge == .match ? previousSegment?.background : nil
                output += sgr(foreground: segment.background, background: leftBackground)
                output += leftGlyph
            }

            output += sgr(foreground: segment.foreground, background: segment.background)
            output += " \(segment.templateSource) "

            let nextSegment = segments[safe: index + 1]
            let hasAdjacentSegment = nextSegment?.kind != nil && nextSegment?.kind != .newline

            if nextSegment?.leftEdge != .match,
               let rightGlyph = segment.rightEdge.rightGlyph,
               let next = nextSegment,
               next.kind != .newline {
                output += sgr(foreground: segment.background, background: next.background)
                output += rightGlyph
            } else if nextSegment?.leftEdge != .match,
                      let rightGlyph = segment.rightEdge.rightGlyph {
                output += sgr(foreground: segment.background, background: nil)
                output += rightGlyph
            }

            if !hasAdjacentSegment {
                output += reset
                output += " "
            }
        }
        return output
    }

    private static var reset: String {
        "\u{001B}[0m"
    }

    private static func sgr(foreground: NerdPromptColor, background: NerdPromptColor?) -> String {
        var parts = ["38;5;\(foreground.ansiCode)"]
        if let background, background != .terminalBackground {
            parts.append("48;5;\(background.ansiCode)")
        } else {
            parts.append("49")
        }
        return "\u{001B}[\(parts.joined(separator: ";"))m"
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
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
