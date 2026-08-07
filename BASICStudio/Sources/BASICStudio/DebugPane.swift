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
    @State private var isTasksExpanded = true
    @State private var isCallStackExpanded = true
    @State private var isLocalsExpanded = false
    @State private var isGlobalsExpanded = false
    @State private var isFilesExpanded = true
    @State private var codePaneHeight: CGFloat?
    @State private var dragStartCodePaneHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            debuggerControls
                .padding(10)

            Divider()

            GeometryReader { geometry in
                let codeHeight = resolvedCodePaneHeight(totalHeight: geometry.size.height)

                VStack(spacing: 0) {
                    MonacoEditor(
                        text: .constant(model.programText),
                        showsLineNumbers: true,
                        theme: model.editorTheme,
                        errorLine: model.editorErrorLine,
                        diagnostics: [],
                        executionLine: model.debuggerExecutionLine,
                        breakpointLines: model.debuggerBreakpointLines,
                        isReadOnly: true,
                        fontFamily: model.fontFamily,
                        fontSize: model.fontSize,
                        findRequest: 0,
                        replaceRequest: 0,
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
                        availableHeight: geometry.size.height,
                        minimumCodeHeight: 160,
                        minimumVariablesHeight: 140
                    )

                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            DisclosureGroup("Tasks", isExpanded: $isTasksExpanded) {
                                taskList(
                                    model.debuggerTasks,
                                    selectedTaskID: model.debuggerSelectedTaskID,
                                    selectTask: model.selectDebuggerTask
                                )
                                if let selectedTask = model.debuggerSelectedTask {
                                    selectedTaskDetail(selectedTask)
                                }
                            }

                            DisclosureGroup("Call Stack", isExpanded: $isCallStackExpanded) {
                                callStackList(
                                    model.debuggerCallStack,
                                    selectedIndex: model.debuggerSelectedCallStackFrameIndex,
                                    selectFrame: model.selectDebuggerCallStackFrame
                                )
                            }

                            DisclosureGroup("Local Variables", isExpanded: $isLocalsExpanded) {
                                variableList(model.debuggerSelectedLocalVariables, emptyText: "No local variables are available.")
                            }

                            DisclosureGroup("Globals", isExpanded: $isGlobalsExpanded) {
                                variableList(model.debuggerGlobalVariables, emptyText: "No globals are available.")
                            }

                            DisclosureGroup("Files", isExpanded: $isFilesExpanded) {
                                fileList(model.debuggerFiles)
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

    private var debuggerControls: some View {
        HStack(spacing: 10) {
            debugButton("Run", systemImage: "play.fill", isEnabled: !model.isProgramRunning) {
                model.runEditorProgram()
            }
            debugButton("Continue", systemImage: "forward.frame.fill", isEnabled: model.isProgramPaused && !model.isProgramRunning) {
                model.continueDebugging()
            }
            debugButton("Pause", systemImage: "pause.fill", isEnabled: model.isProgramRunning) {
                model.stopProgram()
            }
            debugButton("Step", systemImage: "arrow.down.to.line", isEnabled: !model.isProgramRunning) {
                model.stepDebugging()
            }
            debugButton("Step Over", systemImage: "arrow.turn.down.right", isEnabled: !model.isProgramRunning) {
                model.stepOverDebugging()
            }
            debugButton("Step Out", systemImage: "arrow.up.to.line", isEnabled: model.isProgramPaused && !model.isProgramRunning) {
                model.stepOutDebugging()
            }
            debugButton("Cancel Task", systemImage: "xmark.circle", isEnabled: canCancelSelectedTask) {
                model.cancelSelectedDebuggerTask()
            }
            Toggle("Live Line", isOn: $model.showsLiveExecutionLine)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Show the current execution line while the program is running.")

            Spacer(minLength: 0)
        }
    }

    private var canCancelSelectedTask: Bool {
        guard let task = model.debuggerSelectedTask else { return false }
        return task.state == .ready || task.state == .running || task.state == .suspended
    }

    private func debugButton(_ title: String, systemImage: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
        .help(title)
    }

    private func resolvedCodePaneHeight(totalHeight: CGFloat) -> CGFloat {
        let minimumCodeHeight: CGFloat = 160
        let minimumVariablesHeight: CGFloat = 140
        let maximumCodeHeight = max(minimumCodeHeight, totalHeight - minimumVariablesHeight)
        let preferredHeight = codePaneHeight ?? max(260, totalHeight * 0.62)
        return min(max(preferredHeight, minimumCodeHeight), maximumCodeHeight)
    }

    @ViewBuilder
    private func taskList(
        _ tasks: [BASICTaskSnapshot],
        selectedTaskID: Int?,
        selectTask: @escaping (BASICTaskSnapshot) -> Void
    ) -> some View {
        if tasks.isEmpty {
            Text("No tasks are available.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 0) {
                ForEach(tasks) { task in
                    Button {
                        selectTask(task)
                    } label: {
                        taskRow(task, isSelected: task.id == selectedTaskID)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func taskRow(_ task: BASICTaskSnapshot, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("#\(task.id)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
                Text(task.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(task.state.rawValue.uppercased())
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(taskStateColor(task.state).opacity(0.18), in: Capsule())
                    .foregroundStyle(taskStateColor(task.state))
            }

            HStack(spacing: 10) {
                if let parentID = task.parentID {
                    taskMetadata("parent #\(parentID)")
                }
                if task.childCount > 0 {
                    taskMetadata("\(task.childCount) child\(task.childCount == 1 ? "" : "ren")")
                }
                if task.waiterCount > 0 {
                    taskMetadata("\(task.waiterCount) waiter\(task.waiterCount == 1 ? "" : "s")")
                }
                if task.yieldCount > 0 {
                    taskMetadata("yields \(task.yieldCount)")
                }
                if let location = task.location {
                    taskMetadata("line \(location.lineNumber)")
                }
            }

            if let reason = taskSuspensionText(task.suspensionReason) {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let result = task.resultDescription, !result.isEmpty {
                Text("result: \(result)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let error = task.errorDescription, !error.isEmpty {
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
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }

    private func selectedTaskDetail(_ task: BASICTaskSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Selected Task")
                    .fontWeight(.semibold)
                Spacer(minLength: 0)
                Text("#\(task.id)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            taskDetailGrid(task)
            if !task.suspendedFrames.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Suspended Frames")
                        .font(.caption.weight(.semibold))
                    ForEach(Array(task.suspendedFrames.enumerated()), id: \.offset) { index, frame in
                        suspendedFrameRow(frame, index: index)
                    }
                }
            } else {
                Text("No suspended frames are captured for this task.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !task.suspendedGlobalVariables.isEmpty {
                DisclosureGroup("Captured Globals") {
                    VStack(spacing: 0) {
                        ForEach(task.suspendedGlobalVariables) { variable in
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

    private func taskDetailGrid(_ task: BASICTaskSnapshot) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                taskDetailLabel("Name")
                taskDetailValue(task.name)
            }
            GridRow {
                taskDetailLabel("State")
                taskDetailValue(task.state.rawValue.uppercased())
            }
            if let parentID = task.parentID {
                GridRow {
                    taskDetailLabel("Parent")
                    taskDetailValue("#\(parentID)")
                }
            }
            GridRow {
                taskDetailLabel("Children")
                taskDetailValue("\(task.childCount)")
            }
            GridRow {
                taskDetailLabel("Waiters")
                taskDetailValue("\(task.waiterCount)")
            }
            GridRow {
                taskDetailLabel("Yields")
                taskDetailValue("\(task.yieldCount)")
            }
            if let location = task.location {
                GridRow {
                    taskDetailLabel("Location")
                    taskDetailValue(taskLocationText(location))
                }
            }
            if let reason = taskSuspensionText(task.suspensionReason) {
                GridRow {
                    taskDetailLabel("Waiting")
                    taskDetailValue(reason)
                }
            }
            if let result = task.resultDescription, !result.isEmpty {
                GridRow {
                    taskDetailLabel("Result")
                    taskDetailValue(result)
                }
            }
            if let error = task.errorDescription, !error.isEmpty {
                GridRow {
                    taskDetailLabel("Error")
                    taskDetailValue(error, color: .red)
                }
            }
        }
    }

    private func suspendedFrameRow(_ frame: BASICSuspendedFrame, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(index)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .leading)
                Text(frame.kind)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                Text(frame.name)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let location = frame.resumeLocation {
                    Text(taskLocationText(location))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if !frame.localVariables.isEmpty {
                DisclosureGroup("Locals") {
                    VStack(spacing: 0) {
                        ForEach(frame.localVariables) { variable in
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

    private func taskLocationText(_ location: BASICBreakpointLocation) -> String {
        var text = "line \(location.lineNumber)"
        if location.statementNumber > 0 {
            text += " stmt \(location.statementNumber)"
        }
        if let fileName = location.fileName,
           !fileName.isEmpty {
            text += " \(URL(fileURLWithPath: fileName).lastPathComponent)"
        }
        return text
    }

    private func taskMetadata(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func taskStateColor(_ state: BASICTaskState) -> SwiftUI.Color {
        switch state {
        case .ready:
            return .yellow
        case .running:
            return .accentColor
        case .suspended:
            return .orange
        case .completed:
            return .green
        case .cancelled:
            return .secondary
        case .failed:
            return .red
        }
    }

    private func taskSuspensionText(_ reason: BASICTaskSuspensionReason?) -> String? {
        guard let reason else { return nil }
        switch reason {
        case .debugger:
            return "paused in debugger"
        case .hostOperation(let operation):
            return "waiting for host operation: \(operation)"
        case .join(let taskID):
            return "waiting for task #\(taskID)"
        }
    }

    @ViewBuilder
    private func callStackList(
        _ frames: [BASICCallStackFrame],
        selectedIndex: Int?,
        selectFrame: @escaping (BASICCallStackFrame) -> Void
    ) -> some View {
        if frames.isEmpty {
            Text("No active stack frames.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 0) {
                ForEach(frames) { frame in
                    Button {
                        selectFrame(frame)
                    } label: {
                        HStack(spacing: 8) {
                            Text(frame.kind)
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .leading)
                            Text(frame.name)
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let metadata = callStackMetadata(for: frame) {
                                Text(metadata)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if let location = frame.location {
                                Text("\(location.lineNumber)")
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
                                .fill(frame.index == selectedIndex ? Color.accentColor.opacity(0.18) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)

                    Divider()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func callStackMetadata(for frame: BASICCallStackFrame) -> String? {
        var parts: [String] = []
        if frame.isOverride {
            parts.append("override")
        }
        if let receiverClassName = frame.receiverClassName,
           let declaringClassName = frame.declaringClassName,
           receiverClassName.caseInsensitiveCompare(declaringClassName) != .orderedSame {
            parts.append("on \(receiverClassName)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
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
    private func fileList(_ files: [BASICFileSnapshot]) -> some View {
        if files.isEmpty {
            Text("No file handles are available.")
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
                            Text(file.isOpen ? "Open" : "Closed")
                                .font(.caption)
                                .foregroundStyle(file.isOpen ? Color.green : Color.secondary)
                            Text([file.access, file.type].filter { !$0.isEmpty }.joined(separator: " / "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Text("\(file.position) / \(file.size)")
                                .font(.system(.caption, design: .monospaced))
                        }
                        Text(file.path.isEmpty ? "No path" : file.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(file.path.isEmpty ? Color.secondary : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 8) {
                            if file.isAtEOF {
                                Text("EOF")
                            }
                            if let recordLength = file.recordLength {
                                Text("Record length \(recordLength)")
                            }
                            if let error = file.lastError, !error.isEmpty {
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
    let minimumCodeHeight: CGFloat
    let minimumVariablesHeight: CGFloat

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
                    let maximumHeight = max(minimumCodeHeight, availableHeight - minimumVariablesHeight)
                    let proposedHeight = (dragStartHeight ?? defaultCodeHeight) + value.translation.height
                    codePaneHeight = min(max(proposedHeight, minimumCodeHeight), maximumHeight)
                }
                .onEnded { _ in
                    dragStartHeight = nil
                }
        )
        .help("Resize debugger panes")
    }

    private var defaultCodeHeight: CGFloat {
        min(max(max(260, availableHeight * 0.62), minimumCodeHeight), max(minimumCodeHeight, availableHeight - minimumVariablesHeight))
    }
}
