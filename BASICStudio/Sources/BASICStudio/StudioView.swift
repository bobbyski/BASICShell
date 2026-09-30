import BASICCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
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
    @State private var inspectorWidth: CGFloat = StudioShellModel.defaultInspectorWidth
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // The chrome's state comes from the projection the ActiveUI shell
        // reads too, and every button goes through StudioShellModel.perform.
        let shell = StudioShellModel(model)
        VStack(spacing: 0) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    mainPane
                        .frame(minWidth: StudioShellModel.minimumMainWidth, maxWidth: .infinity, maxHeight: .infinity)

                    if let inspectorPane = shell.inspector {
                        InspectorDivider(
                            width: $inspectorWidth,
                            availableWidth: geometry.size.width
                        )

                        inspectorView(for: inspectorPane)
                            .frame(width: StudioShellModel.clampedInspectorWidth(inspectorWidth, availableWidth: geometry.size.width))
                            .frame(maxHeight: .infinity)
                    }
                }
            }

            if shell.showsCommandBar {
                Divider()

                HStack {
                    Button("Run") { model.runEditorProgram() }
                        .keyboardShortcut("r", modifiers: [.command])
                    // Compiled rather than interpreted. The same program
                    // either way — the compiler is held to the interpreter's
                    // output — but no debugger, because a compiled program
                    // has no interpreter to step.
                    Button("JIT") { model.jitEditorProgram() }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                        .disabled(!shell.isCommandBarJITEnabled)
                        .help("Compile, then run")
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
            // The parity walk's --settings: open Settings on the asked tab.
            if StudioLaunchOptions.current.walk?.settingsTab != nil {
                openSettings()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(shell.toolbar, id: \.command) { button in
                    Button {
                        StudioShellModel.perform(button.command, on: model)
                    } label: {
                        Image(systemName: button.symbol)
                            .foregroundStyle(Self.color(for: button.tint))
                    }
                    .disabled(!button.isEnabled)
                    .help(button.help)

                    if button.command == StudioShellModel.dividerAfter {
                        Divider()
                    }
                }

                toolbarMenu(shell.themeMenu) { StudioShellModel.chooseTheme($0, on: model) }
                toolbarMenu(shell.screenSizeMenu) { StudioShellModel.chooseScreenSize($0, on: model) }
            }
        }
    }

    private func toolbarMenu(_ menu: StudioShellModel.Menu, choose: @escaping (Int) -> Void) -> some View {
        Menu {
            ForEach(Array(menu.items.enumerated()), id: \.offset) { index, item in
                Button {
                    choose(index)
                } label: {
                    HStack {
                        Text(item.title)
                        if item.isChecked {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label(menu.label, systemImage: menu.symbol)
        }
        .help(menu.help)
    }

    private static func color(for tint: StudioShellModel.Tint) -> SwiftUI.Color {
        switch tint {
        case .normal: return .primary
        case .dimmed: return .secondary
        case .selected: return .blue
        case .alert: return .red
        case .on: return .green
        }
    }

    @ViewBuilder
    private var mainPane: some View {
        switch model.selectedPane {
        case .editor:
            VStack(spacing: 0) {
                MonacoEditor(
                    text: $model.programText,
                    input: .mainEditor(model),
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
}

struct InspectorDivider: View {
    @Binding var width: CGFloat
    let availableWidth: CGFloat
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
                    width = StudioShellModel.draggedInspectorWidth(
                        startWidth: dragStartWidth ?? width,
                        translation: value.translation.width,
                        availableWidth: availableWidth
                    )
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
        .help("Resize side pane")
    }
}
