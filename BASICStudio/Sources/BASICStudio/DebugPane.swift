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

struct DebugPane: View {
    @ObservedObject var model: StudioModel
    @State private var isTasksExpanded = DebugPaneModel.sections[0].isExpandedByDefault
    @State private var isCallStackExpanded = DebugPaneModel.sections[1].isExpandedByDefault
    @State private var isLocalsExpanded = DebugPaneModel.sections[2].isExpandedByDefault
    @State private var isGlobalsExpanded = DebugPaneModel.sections[3].isExpandedByDefault
    @State private var isFilesExpanded = DebugPaneModel.sections[4].isExpandedByDefault
    @State private var codePaneHeight: CGFloat?
    @State private var dragStartCodePaneHeight: CGFloat?

    var body: some View {
        // Everything drawn comes from the projection the ActiveUI pane reads
        // too; the expansion and the divider are this view's own state.
        let pane = DebugPaneModel(model)
        VStack(spacing: 0) {
            debuggerControls(pane)
                .padding(10)

            Divider()

            GeometryReader { geometry in
                let codeHeight = DebugPaneModel.resolvedCodePaneHeight(totalHeight: geometry.size.height, dragged: codePaneHeight)

                VStack(spacing: 0) {
                    MonacoEditor(
                        text: .constant(pane.programText),
                        input: .debugCodeView(model),
                        breakpointToggle: { lineNumber in
                            model.toggleDebuggerBreakpoint(atSourceLine: lineNumber)
                        }
                    )
                    .frame(height: codeHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding([.top, .horizontal], 12)

                    DebugHorizontalDivider(
                        codePaneHeight: $codePaneHeight,
                        dragStartHeight: $dragStartCodePaneHeight,
                        availableHeight: geometry.size.height
                    )

                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            DisclosureGroup(DebugPaneModel.sections[0].title, isExpanded: $isTasksExpanded) {
                                taskList(pane.tasks)
                                if let selectedTask = pane.selectedTask {
                                    selectedTaskDetail(selectedTask)
                                }
                            }

                            DisclosureGroup(DebugPaneModel.sections[1].title, isExpanded: $isCallStackExpanded) {
                                callStackList(pane.callStack)
                            }

                            DisclosureGroup(DebugPaneModel.sections[2].title, isExpanded: $isLocalsExpanded) {
                                variableList(pane.locals, emptyText: DebugPaneModel.noLocalsText)
                            }

                            DisclosureGroup(DebugPaneModel.sections[3].title, isExpanded: $isGlobalsExpanded) {
                                variableList(pane.globals, emptyText: DebugPaneModel.noGlobalsText)
                            }

                            DisclosureGroup(DebugPaneModel.sections[4].title, isExpanded: $isFilesExpanded) {
                                fileList(pane.files)
                            }
                        }
                        .padding([.horizontal, .bottom], 12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func debuggerControls(_ pane: DebugPaneModel) -> some View {
        HStack(spacing: 10) {
            ForEach(pane.buttons, id: \.command) { button in
                debugButton(button)
            }
            Toggle(DebugPaneModel.liveLineTitle, isOn: $model.showsLiveExecutionLine)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help(DebugPaneModel.liveLineHelp)

            Spacer(minLength: 0)
        }
    }

    private func debugButton(_ button: DebugPaneModel.Button) -> some View {
        Button {
            DebugPaneModel.perform(button.command, on: model)
        } label: {
            Image(systemName: button.symbol)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .disabled(!button.isEnabled)
        .foregroundStyle(button.isEnabled ? Color.primary : Color.secondary)
        .help(button.title)
    }

    @ViewBuilder
    private func taskList(_ tasks: [DebugPaneModel.TaskRow]) -> some View {
        if tasks.isEmpty {
            Text(DebugPaneModel.noTasksText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 0) {
                ForEach(tasks) { task in
                    Button {
                        DebugPaneModel.selectTask(id: task.id, on: model)
                    } label: {
                        taskRow(task)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func taskRow(_ task: DebugPaneModel.TaskRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(task.idText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
                Text(task.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(task.stateText)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(stateColor(task.stateKind).opacity(0.18), in: Capsule())
                    .foregroundStyle(stateColor(task.stateKind))
            }

            HStack(spacing: 10) {
                ForEach(task.metadata, id: \.self) { fact in
                    taskMetadata(fact)
                }
            }

            if let reason = task.suspensionText {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let result = task.resultText {
                Text(result)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let error = task.errorText {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .font(.caption)
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(task.isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }

    private func selectedTaskDetail(_ task: DebugPaneModel.TaskDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Selected Task")
                    .fontWeight(.semibold)
                Spacer(minLength: 0)
                Text(task.idText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(task.fields, id: \.label) { field in
                    GridRow {
                        taskDetailLabel(field.label)
                        taskDetailValue(field.value, color: field.isError ? .red : .primary)
                    }
                }
            }
            if !task.frames.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Suspended Frames")
                        .font(.caption.weight(.semibold))
                    ForEach(task.frames, id: \.index) { frame in
                        suspendedFrameRow(frame)
                    }
                }
            } else {
                Text(DebugPaneModel.noSuspendedFramesText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !task.capturedGlobals.isEmpty {
                DisclosureGroup("Captured Globals") {
                    VStack(spacing: 0) {
                        ForEach(task.capturedGlobals) { variable in
                            variableNode(variable, indent: 12)
                            Divider()
                        }
                    }
                }
                .font(.caption2)
            }
        }
        .font(.caption)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.48))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .padding(.top, 4)
    }

    private func suspendedFrameRow(_ frame: DebugPaneModel.SuspendedFrameRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(frame.index)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .leading)
                Text(frame.kind)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                Text(frame.name)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let location = frame.locationText {
                    Text(location)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if !frame.locals.isEmpty {
                DisclosureGroup("Locals") {
                    VStack(spacing: 0) {
                        ForEach(frame.locals) { variable in
                            variableNode(variable, indent: 12)
                            Divider()
                        }
                    }
                }
                .font(.caption2)
                .padding(.leading, 26)
            }
        }
        .font(.caption2)
        .padding(.vertical, 3)
    }

    private func taskDetailLabel(_ value: String) -> some View {
        Text(value)
            .foregroundStyle(.secondary)
            .frame(width: 62, alignment: .leading)
    }

    private func taskDetailValue(_ value: String, color: SwiftUI.Color = .primary) -> some View {
        Text(value)
            .foregroundStyle(color)
            .lineLimit(2)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func taskMetadata(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func stateColor(_ kind: DebugPaneModel.StateKind) -> SwiftUI.Color {
        switch kind {
        case .ready: return .yellow
        case .running: return .accentColor
        case .suspended: return .orange
        case .completed: return .green
        case .cancelled: return .secondary
        case .failed: return .red
        }
    }

    @ViewBuilder
    private func callStackList(_ frames: [DebugPaneModel.FrameRow]) -> some View {
        if frames.isEmpty {
            Text(DebugPaneModel.noFramesText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 0) {
                ForEach(frames) { frame in
                    Button {
                        DebugPaneModel.selectFrame(index: frame.index, on: model)
                    } label: {
                        HStack(spacing: 8) {
                            Text(frame.kind)
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .leading)
                            Text(frame.name)
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let metadata = frame.metadata {
                                Text(metadata)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if let line = frame.lineText {
                                Text(line)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(frame.isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)

                    Divider()
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func variableList(_ variables: [BASICVariableSnapshot], emptyText: String) -> some View {
        if variables.isEmpty {
            Text(emptyText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 0) {
                ForEach(variables) { variable in
                    variableNode(variable, indent: 0)
                    Divider()
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func fileList(_ files: [DebugPaneModel.FileRow]) -> some View {
        if files.isEmpty {
            Text(DebugPaneModel.noFilesText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 0) {
                ForEach(files) { file in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(file.reference)
                                .font(.system(.callout, design: .monospaced).weight(.semibold))
                            Text(file.statusText)
                                .font(.caption)
                                .foregroundStyle(file.isOpen ? Color.green : Color.secondary)
                            Text(file.accessText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Text(file.positionText)
                                .font(.system(.caption, design: .monospaced))
                        }
                        Text(file.pathText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(file.hasPath ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 8) {
                            ForEach(file.flags, id: \.self) { flag in
                                Text(flag)
                            }
                            if let error = file.errorText {
                                Text(error)
                                    .foregroundStyle(.red)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
    }

    private func variableNode(_ variable: BASICVariableSnapshot, indent: CGFloat) -> AnyView {
        if variable.children.isEmpty {
            return AnyView(variableRow(variable, indent: indent))
        } else {
            return AnyView(DisclosureGroup {
                VStack(spacing: 0) {
                    ForEach(variable.children) { child in
                        variableNode(child, indent: indent + 14)
                        Divider()
                    }
                }
            } label: {
                variableRow(variable, indent: indent)
            }
            .disclosureGroupStyle(.automatic))
        }
    }

    private func variableRow(_ variable: BASICVariableSnapshot, indent: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(variable.name)
                .fontWeight(.medium)
                .padding(.leading, indent)
                .frame(minWidth: 70 + indent, alignment: .leading)
            Text(variable.typeName)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(variable.value)
                .monospaced()
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .padding(.vertical, 5)
    }
}

struct DebugHorizontalDivider: View {
    @Binding var codePaneHeight: CGFloat?
    @Binding var dragStartHeight: CGFloat?
    let availableHeight: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 44, height: 3)
            Color.clear
                .frame(height: 12)
        }
        .frame(height: 12)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartHeight == nil {
                        dragStartHeight = codePaneHeight ?? defaultCodeHeight
                    }
                    codePaneHeight = DebugPaneModel.draggedCodePaneHeight(
                        startHeight: dragStartHeight ?? defaultCodeHeight,
                        translation: value.translation.height,
                        availableHeight: availableHeight
                    )
                }
                .onEnded { _ in
                    dragStartHeight = nil
                }
        )
        .help("Resize debugger panes")
    }

    private var defaultCodeHeight: CGFloat {
        DebugPaneModel.resolvedCodePaneHeight(totalHeight: availableHeight, dragged: nil)
    }
}
