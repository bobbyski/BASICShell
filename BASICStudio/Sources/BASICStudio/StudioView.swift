import BASICCore
import AppKit
import CoreText
import GameController
import MarkdownUI
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import VectorTerminalSDK
import WebKit

struct StudioView: View {
    @ObservedObject var model: StudioModel
    @State private var inspectorWidth: CGFloat = 360

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    mainPane
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

                    if let inspectorPane = model.inspectorPane {
                        InspectorDivider(
                            width: $inspectorWidth,
                            availableWidth: geometry.size.width,
                            minimumMainWidth: 420,
                            minimumInspectorWidth: 260
                        )

                        inspectorView(for: inspectorPane)
                            .frame(width: clampedInspectorWidth(availableWidth: geometry.size.width))
                            .frame(maxHeight: .infinity)
                    }
                }
            }

            if model.isCommandBarVisible {
                Divider()

                HStack {
                    Button("Run") { model.runEditorProgram() }
                        .keyboardShortcut("r", modifiers: [.command])
                    Button("List") { model.listProgram() }
                    Button("New") { model.clearProgram() }
                    TextField("Immediate command", text: $model.command)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.submitCommand() }
                    Button("Submit") { model.submitCommand() }
                }
                .padding()
            }
        }
        .onAppear {
            model.runStartupProgramIfNeeded()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.runEditorProgram()
                } label: {
                    Image(systemName: "play.fill")
                        .foregroundStyle(model.isProgramRunning ? Color.secondary : Color.primary)
                }
                .disabled(model.isProgramRunning)
                .help("Run")

                Button {
                    model.stopProgram()
                } label: {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(model.isProgramRunning ? Color.red : Color.secondary)
                }
                .disabled(!model.isProgramRunning)
                .help("Stop")

                Divider()

                Button {
                    model.selectedPane = .console
                } label: {
                    Image(systemName: "terminal")
                        .foregroundStyle(model.selectedPane == .console ? Color.blue : Color.primary)
                }
                .help("Console")

                Button {
                    model.selectedPane = .editor
                } label: {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(model.selectedPane == .editor ? Color.blue : Color.primary)
                }
                .help("Editor")

                Button {
                    model.toggleInspector(.debug)
                } label: {
                    Image(systemName: "ladybug")
                        .foregroundStyle(model.inspectorPane == .debug ? Color.blue : Color.primary)
                }
                .help("Debug")

                Button {
                    model.toggleInspector(.docs)
                } label: {
                    Image(systemName: "book")
                        .foregroundStyle(model.inspectorPane == .docs ? Color.blue : Color.primary)
                }
                .help("Documentation")

                Button {
                    model.toggleInspector(.logs)
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundStyle(model.inspectorPane == .logs ? Color.blue : Color.primary)
                }
                .help("Log")

                Button {
                    model.isCommandBarVisible.toggle()
                } label: {
                    Image(systemName: "keyboard")
                        .foregroundStyle(model.isCommandBarVisible ? Color.blue : Color.primary)
                }
                .help("Command Bar")

                Button {
                    model.isEditorGutterVisible.toggle()
                } label: {
                    Image(systemName: "list.number")
                        .foregroundStyle(model.isEditorGutterVisible ? Color.blue : Color.primary)
                }
                .help("Editor Line Numbers")

                Button {
                    model.showFind()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Find")

                Menu {
                    ForEach(EditorTheme.allCases, id: \.self) { theme in
                        Button {
                            model.editorTheme = theme
                        } label: {
                            HStack {
                                Text(theme.label)
                                if model.editorTheme == theme {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label(model.editorTheme.label, systemImage: "paintpalette")
                }
                .help("Editor Theme")

                Menu {
                    ForEach(TerminalScreenSize.allCases, id: \.self) { size in
                        Button {
                            model.terminalScreenSize = size
                        } label: {
                            HStack {
                                Text(size.label)
                                if model.terminalScreenSize == size {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label(model.terminalScreenSize.label, systemImage: "rectangle.inset.filled")
                }
                .help("Screen Size")
            }
        }
    }

    @ViewBuilder
    private var mainPane: some View {
        switch model.selectedPane {
        case .editor:
            VStack(spacing: 0) {
                MonacoEditor(
                    text: $model.programText,
                    showsLineNumbers: model.isEditorGutterVisible,
                    theme: model.editorTheme,
                    errorLine: model.editorErrorLine,
                    diagnostics: model.editorDiagnostics,
                    executionLine: nil,
                    breakpointLines: [],
                    isReadOnly: false,
                    fontFamily: model.fontFamily,
                    fontSize: model.fontSize,
                    findRequest: model.editorFindRequest,
                    replaceRequest: model.editorReplaceRequest,
                    breakpointToggle: nil
                )
            }
            .padding()
        case .console:
            VStack(spacing: 0) {
                SwiftTermGraphicsConsole(model: model)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func inspectorView(for pane: InspectorPane) -> some View {
        switch pane {
        case .debug:
            DebugPane(model: model)
        case .docs:
            UserDocumentationPane()
        case .logs:
            LogPane(model: model)
        }
    }

    private func clampedInspectorWidth(availableWidth: CGFloat) -> CGFloat {
        min(max(inspectorWidth, 260), max(260, availableWidth - 420))
    }
}

struct InspectorDivider: View {
    @Binding var width: CGFloat
    let availableWidth: CGFloat
    let minimumMainWidth: CGFloat
    let minimumInspectorWidth: CGFloat
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 3, height: 44)
            Color.clear
                .frame(width: 12)
        }
        .frame(width: 12)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = width
                    }

                    let maximumWidth = max(minimumInspectorWidth, availableWidth - minimumMainWidth)
                    let proposedWidth = (dragStartWidth ?? width) - value.translation.width
                    width = min(max(proposedWidth, minimumInspectorWidth), maximumWidth)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
        .help("Resize side pane")
    }
}
