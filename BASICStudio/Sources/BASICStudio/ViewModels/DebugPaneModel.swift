//
//  DebugPaneModel.swift
//  BASICStudio
//
//  What the Debug inspector shows, for either shell.
//

import BASICCore
import CoreGraphics
import Foundation

/// The Debug inspector as values: its buttons, its task, call-stack,
/// variable and file lists, and the code view's layout arithmetic.
///
/// A projection like ``LogPaneModel``: built from ``StudioModel`` on demand,
/// owning nothing, importing no UI framework. Every piece of text the pane
/// shows is decided here, so the SwiftUI pane and the ActiveUI pane cannot
/// drift apart. Actions go straight to the model through ``perform(_:on:)``.
///
/// ```text
///   ▶ ⏭ ⏸ ⤓ ↪ ⤒ ⊗  [x] Live Line                buttons, showsLiveExecutionLine
///   ┌ code (read-only, numbered) ──────────┐   executionLine, breakpointLines
///   ├══════════ drag ══════════════════════┤   resolvedCodePaneHeight
///   │ ▾ Tasks        #1 Program RUNNING    │   tasks, selectedTask
///   │ ▾ Call Stack   function F  on B   12 │   callStack
///   │ ▸ Local Variables / ▸ Globals        │   locals, globals
///   │ ▾ Files        #1 Open  I / text     │   files
///   └──────────────────────────────────────┘
/// ```
struct DebugPaneModel: Equatable {
    // MARK: Buttons

    enum Command: CaseIterable, Equatable {
        case run, continueExecution, pause, step, stepOver, stepOut, cancelTask
    }

    struct Button: Equatable {
        let command: Command
        /// The button's help tag; the button itself is only its symbol.
        let title: String
        /// An SF Symbol name.
        let symbol: String
        let isEnabled: Bool
    }

    // MARK: Tasks

    /// What a task's state capsule says. Each shell maps these to colors:
    /// yellow, accent, orange, green, gray and red, in order.
    enum StateKind: Equatable {
        case ready, running, suspended, completed, cancelled, failed

        init(_ state: BASICTaskState) {
            switch state {
            case .ready: self = .ready
            case .running: self = .running
            case .suspended: self = .suspended
            case .completed: self = .completed
            case .cancelled: self = .cancelled
            case .failed: self = .failed
            }
        }
    }

    struct TaskRow: Identifiable, Equatable {
        let id: Int
        /// `#3`.
        let idText: String
        let name: String
        /// The state, uppercased: `RUNNING`.
        let stateText: String
        let stateKind: StateKind
        /// Small gray facts, in order: parent, children, waiters, yields, line.
        let metadata: [String]
        let suspensionText: String?
        /// `result: …`, when there is a result.
        let resultText: String?
        let errorText: String?
        let isSelected: Bool
    }

    /// One label and value in the selected task's grid.
    struct DetailField: Equatable {
        let label: String
        let value: String
        /// Drawn in red.
        let isError: Bool
    }

    struct SuspendedFrameRow: Equatable {
        let index: Int
        let kind: String
        let name: String
        let locationText: String?
        let locals: [BASICVariableSnapshot]
    }

    struct TaskDetail: Equatable {
        let idText: String
        let fields: [DetailField]
        let frames: [SuspendedFrameRow]
        let capturedGlobals: [BASICVariableSnapshot]
    }

    // MARK: Call stack and files

    struct FrameRow: Identifiable, Equatable {
        let id: String
        let index: Int
        let kind: String
        let name: String
        /// `override`, `on Receiver`, or both.
        let metadata: String?
        let lineText: String?
        let isSelected: Bool
    }

    struct FileRow: Identifiable, Equatable {
        let id: String
        let reference: String
        let isOpen: Bool
        /// `Open` or `Closed`.
        let statusText: String
        /// `access / type`, skipping either when empty.
        let accessText: String
        /// `position / size`.
        let positionText: String
        /// The path, or `No path`.
        let pathText: String
        let hasPath: Bool
        /// `EOF`, `Record length 128`: gray facts after the path.
        let flags: [String]
        let errorText: String?
    }

    /// A disclosure section and whether it starts open.
    struct Section: Equatable {
        let title: String
        let isExpandedByDefault: Bool
    }

    // MARK: Constants

    static let sections = [
        Section(title: "Tasks", isExpandedByDefault: true),
        Section(title: "Call Stack", isExpandedByDefault: true),
        Section(title: "Local Variables", isExpandedByDefault: false),
        Section(title: "Globals", isExpandedByDefault: false),
        Section(title: "Files", isExpandedByDefault: true),
    ]
    static let noTasksText = "No tasks are available."
    static let noFramesText = "No active stack frames."
    static let noLocalsText = "No local variables are available."
    static let noGlobalsText = "No globals are available."
    static let noFilesText = "No file handles are available."
    static let noSuspendedFramesText = "No suspended frames are captured for this task."
    static let liveLineTitle = "Live Line"
    static let liveLineHelp = "Show the current execution line while the program is running."

    static let minimumCodeHeight: CGFloat = 160
    static let minimumVariablesHeight: CGFloat = 140

    // MARK: Values

    let buttons: [Button]
    let showsLiveExecutionLine: Bool
    /// The code view: the program, read-only, with the paused line marked.
    let programText: String
    let executionLine: Int?
    let errorLine: Int?
    let breakpointLines: Set<Int>
    let tasks: [TaskRow]
    let selectedTask: TaskDetail?
    let callStack: [FrameRow]
    /// The selected frame's locals, or the innermost frame's.
    let locals: [BASICVariableSnapshot]
    let globals: [BASICVariableSnapshot]
    let files: [FileRow]

    @MainActor
    init(_ model: StudioModel) {
        let running = model.isProgramRunning
        let paused = model.isProgramPaused
        let canCancel = Self.canCancel(model.debuggerSelectedTask?.state)
        buttons = Command.allCases.map { command in
            switch command {
            case .run: Button(command: command, title: "Run", symbol: "play.fill", isEnabled: !running)
            case .continueExecution: Button(command: command, title: "Continue", symbol: "forward.frame.fill", isEnabled: paused && !running)
            case .pause: Button(command: command, title: "Pause", symbol: "pause.fill", isEnabled: running)
            case .step: Button(command: command, title: "Step", symbol: "arrow.down.to.line", isEnabled: !running)
            case .stepOver: Button(command: command, title: "Step Over", symbol: "arrow.turn.down.right", isEnabled: !running)
            case .stepOut: Button(command: command, title: "Step Out", symbol: "arrow.up.to.line", isEnabled: paused && !running)
            case .cancelTask: Button(command: command, title: "Cancel Task", symbol: "xmark.circle", isEnabled: canCancel)
            }
        }
        showsLiveExecutionLine = model.showsLiveExecutionLine
        programText = model.programText
        executionLine = model.debuggerExecutionLine
        errorLine = model.editorErrorLine
        breakpointLines = model.debuggerBreakpointLines
        let selectedTaskID = model.debuggerSelectedTaskID
        tasks = model.debuggerTasks.map { Self.taskRow($0, isSelected: $0.id == selectedTaskID) }
        selectedTask = model.debuggerSelectedTask.map(Self.taskDetail)
        let selectedFrame = model.debuggerSelectedCallStackFrameIndex
        callStack = model.debuggerCallStack.map { frame in
            FrameRow(
                id: frame.id,
                index: frame.index,
                kind: frame.kind,
                name: frame.name,
                metadata: Self.callStackMetadata(
                    isOverride: frame.isOverride,
                    receiverClassName: frame.receiverClassName,
                    declaringClassName: frame.declaringClassName
                ),
                lineText: frame.location.map { "\($0.lineNumber)" },
                isSelected: frame.index == selectedFrame
            )
        }
        locals = model.debuggerSelectedLocalVariables
        globals = model.debuggerGlobalVariables
        files = model.debuggerFiles.map(Self.fileRow)
    }

    func button(_ command: Command) -> Button {
        buttons.first { $0.command == command }!
    }

    // MARK: Actions

    /// Does what the button does. Pause stops at the next statement, in the
    /// debugger (STUDIO_FEATURES.md D21, ruled 2026-09-29).
    @MainActor
    static func perform(_ command: Command, on model: StudioModel) {
        switch command {
        case .run: model.runEditorProgram()
        case .continueExecution: model.continueDebugging()
        case .pause: model.pauseProgram()
        case .step: model.stepDebugging()
        case .stepOver: model.stepOverDebugging()
        case .stepOut: model.stepOutDebugging()
        case .cancelTask: model.cancelSelectedDebuggerTask()
        }
    }

    /// Clicks the task row `id`: selects it, or deselects it if selected.
    @MainActor
    static func selectTask(id: Int, on model: StudioModel) {
        guard let task = model.debuggerTasks.first(where: { $0.id == id }) else { return }
        model.selectDebuggerTask(task)
    }

    /// Clicks the call-stack row `index`.
    @MainActor
    static func selectFrame(index: Int, on model: StudioModel) {
        guard let frame = model.debuggerCallStack.first(where: { $0.index == index }) else { return }
        model.selectDebuggerCallStackFrame(frame)
    }

    // MARK: Rules

    /// A task can be cancelled while it is ready, running or suspended.
    static func canCancel(_ state: BASICTaskState?) -> Bool {
        guard let state else { return false }
        return state == .ready || state == .running || state == .suspended
    }

    static func taskRow(_ task: BASICTaskSnapshot, isSelected: Bool) -> TaskRow {
        TaskRow(
            id: task.id,
            idText: "#\(task.id)",
            name: task.name,
            stateText: task.state.rawValue.uppercased(),
            stateKind: StateKind(task.state),
            metadata: taskMetadata(
                parentID: task.parentID,
                childCount: task.childCount,
                waiterCount: task.waiterCount,
                yieldCount: task.yieldCount,
                location: task.location
            ),
            suspensionText: suspensionText(task.suspensionReason),
            resultText: task.resultDescription.flatMap { $0.isEmpty ? nil : "result: \($0)" },
            errorText: task.errorDescription.flatMap { $0.isEmpty ? nil : $0 },
            isSelected: isSelected
        )
    }

    /// The gray facts under a task's name, each only when it says something.
    static func taskMetadata(parentID: Int?, childCount: Int, waiterCount: Int, yieldCount: Int, location: BASICBreakpointLocation?) -> [String] {
        var parts: [String] = []
        if let parentID { parts.append("parent #\(parentID)") }
        if childCount > 0 { parts.append("\(childCount) child\(childCount == 1 ? "" : "ren")") }
        if waiterCount > 0 { parts.append("\(waiterCount) waiter\(waiterCount == 1 ? "" : "s")") }
        if yieldCount > 0 { parts.append("yields \(yieldCount)") }
        if let location { parts.append("line \(location.lineNumber)") }
        return parts
    }

    static func taskDetail(_ task: BASICTaskSnapshot) -> TaskDetail {
        var fields = [
            DetailField(label: "Name", value: task.name, isError: false),
            DetailField(label: "State", value: task.state.rawValue.uppercased(), isError: false),
        ]
        if let parentID = task.parentID {
            fields.append(DetailField(label: "Parent", value: "#\(parentID)", isError: false))
        }
        fields.append(DetailField(label: "Children", value: "\(task.childCount)", isError: false))
        fields.append(DetailField(label: "Waiters", value: "\(task.waiterCount)", isError: false))
        fields.append(DetailField(label: "Yields", value: "\(task.yieldCount)", isError: false))
        if let location = task.location {
            fields.append(DetailField(label: "Location", value: locationText(location), isError: false))
        }
        if let reason = suspensionText(task.suspensionReason) {
            fields.append(DetailField(label: "Waiting", value: reason, isError: false))
        }
        if let result = task.resultDescription, !result.isEmpty {
            fields.append(DetailField(label: "Result", value: result, isError: false))
        }
        if let error = task.errorDescription, !error.isEmpty {
            fields.append(DetailField(label: "Error", value: error, isError: true))
        }
        return TaskDetail(
            idText: "#\(task.id)",
            fields: fields,
            frames: task.suspendedFrames.enumerated().map { index, frame in
                SuspendedFrameRow(
                    index: index,
                    kind: frame.kind,
                    name: frame.name,
                    locationText: frame.resumeLocation.map(locationText),
                    locals: frame.localVariables
                )
            },
            capturedGlobals: task.suspendedGlobalVariables
        )
    }

    /// `line 12`, then ` stmt 2` past the first statement, then the file's
    /// name when there is one.
    static func locationText(_ location: BASICBreakpointLocation) -> String {
        var text = "line \(location.lineNumber)"
        if location.statementNumber > 0 {
            text += " stmt \(location.statementNumber)"
        }
        if let fileName = location.fileName, !fileName.isEmpty {
            text += " \(URL(fileURLWithPath: fileName).lastPathComponent)"
        }
        return text
    }

    static func suspensionText(_ reason: BASICTaskSuspensionReason?) -> String? {
        guard let reason else { return nil }
        switch reason {
        case .debugger: return "paused in debugger"
        case .hostOperation(let operation): return "waiting for host operation: \(operation)"
        case .join(let taskID): return "waiting for task #\(taskID)"
        }
    }

    /// `override` for an overriding method; `on Receiver` when the receiver's
    /// class is not the one that declares the method, ignoring case.
    static func callStackMetadata(isOverride: Bool, receiverClassName: String?, declaringClassName: String?) -> String? {
        var parts: [String] = []
        if isOverride {
            parts.append("override")
        }
        if let receiverClassName, let declaringClassName,
           receiverClassName.caseInsensitiveCompare(declaringClassName) != .orderedSame {
            parts.append("on \(receiverClassName)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func fileRow(_ file: BASICFileSnapshot) -> FileRow {
        var flags: [String] = []
        if file.isAtEOF { flags.append("EOF") }
        if let recordLength = file.recordLength { flags.append("Record length \(recordLength)") }
        return FileRow(
            id: file.id,
            reference: file.reference,
            isOpen: file.isOpen,
            statusText: file.isOpen ? "Open" : "Closed",
            accessText: [file.access, file.type].filter { !$0.isEmpty }.joined(separator: " / "),
            positionText: "\(file.position) / \(file.size)",
            pathText: file.path.isEmpty ? "No path" : file.path,
            hasPath: !file.path.isEmpty,
            flags: flags,
            errorText: file.lastError.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: Layout

    /// The code view's height in `totalHeight`: the dragged height, or 62%
    /// (at least 260) until dragged; never under 160, and always leaving the
    /// variables 140.
    static func resolvedCodePaneHeight(totalHeight: CGFloat, dragged: CGFloat?) -> CGFloat {
        let maximumCodeHeight = max(minimumCodeHeight, totalHeight - minimumVariablesHeight)
        let preferredHeight = dragged ?? max(260, totalHeight * 0.62)
        return min(max(preferredHeight, minimumCodeHeight), maximumCodeHeight)
    }

    /// The code view's height after dragging the divider `translation` points
    /// from `startHeight`, within the same limits.
    static func draggedCodePaneHeight(startHeight: CGFloat, translation: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let maximumHeight = max(minimumCodeHeight, availableHeight - minimumVariablesHeight)
        return min(max(startHeight + translation, minimumCodeHeight), maximumHeight)
    }
}
