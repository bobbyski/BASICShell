//
//  DebugPaneAUI.swift
//  BASICStudio
//
//  The Debug inspector, in ActiveUI.
//

import ActiveUI
import AppKit
import BASICCore
import Foundation

/// The Debug inspector for the ActiveUI shell, drawn from ``DebugPaneModel``.
///
/// ```text
///   ▶ ⏭ ⏸ ⤓ ↪ ⤒ ⊗  [x] Live Line               buttons
///   ┌ code: a second editor, read-only ────┐   EditorRenderInput.debugCodeView
///   ├════════════ drag ════════════════════┤   DebugPaneModel's height rules
///   │ ▾ Tasks                              │   one scroll view of disclosure
///   │ ▾ Call Stack                         │   sections, as SwiftUI's
///   │ ▸ Local Variables  ▸ Globals         │   DisclosureGroups are
///   │ ▾ Files                              │
///   └──────────────────────────────────────┘
/// ```
///
/// **Rebuild, not re-pull** (C12). Rows here have conditional parts, such as a
/// task's error line or a variable's children, so a section whose rows changed
/// is rebuilt from the projection, not updated in place. Sections whose rows
/// did not change are left alone.
@MainActor
final class DebugPaneAUI {
    let model: StudioModel
    let root: AUIView
    let buttons: [DebugPaneModel.Command: AUIButton]
    let liveLine: AUIToggle
    let codeView = SourceEditorAUI()
    let codeHost: AUIView
    let sections: [DisclosureSection]
    private let body: DebugBodyLayout
    /// Open disclosure rows: variables with children, and the task detail's
    /// Locals and Captured Globals. Closed until clicked, as SwiftUI's are.
    private var openRows: Set<String> = []
    private(set) var drawn: DebugPaneModel?

    init(model: StudioModel) {
        self.model = model
        var buttons: [DebugPaneModel.Command: AUIButton] = [:]
        var controls: [AUIView] = []
        for command in DebugPaneModel.Command.allCases {
            let button = AUIButton("") { [weak model] in
                guard let model else { return }
                DebugPaneModel.perform(command, on: model)
            }
            button.isBordered = false
            button.imagePosition = .imageOnly
            buttons[command] = button
            controls.append(button)
        }
        self.buttons = buttons
        liveLine = AUIToggle(DebugPaneModel.liveLineTitle) { [weak model] in model?.showsLiveExecutionLine = $0 }
        liveLine.tooltip = DebugPaneModel.liveLineHelp
        controls += [liveLine, AUISpacer()]
        let controlRow = LogPaneAUI.row(controls, spacing: 10)
        controlRow.padding = AUIEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)

        codeView.onToggleBreakpoint = { [weak model] line in model?.toggleDebuggerBreakpoint(atSourceLine: line) }
        codeHost = codeView.editor
        codeHost.cornerRadius = 6

        sections = DebugPaneModel.sections.map { DisclosureSection(title: $0.title, isOpen: $0.isExpandedByDefault) }
        let list = PromptEditorAUI.column(sections.map(\.root), spacing: 10)
        list.padding = AUIEdgeInsets(top: 0, leading: 12, bottom: 12, trailing: 12)
        let scroll = AUIScrollView(.vertical)
        scroll.addChild(list)
        body = DebugBodyLayout(code: codeHost, list: scroll)

        let whole = AUIStack(.vertical, spacing: 0, alignment: .fill)
        whole.wraps = false
        whole.addChild(controlRow)
        whole.addChild(AUIDivider())
        whole.addChild(body)
        whole.backgroundColor = .controlBackground
        root = whole
        refresh()
    }

    /// Brings the pane up to the model; parts that did not change are left alone.
    func refresh() {
        codeView.sync(StudioAppTheme.themed(.debugCodeView(model), model))
        let pane = DebugPaneModel(model)
        guard pane != drawn else { return }
        for button in pane.buttons where drawn?.button(button.command) != button {
            guard let view = buttons[button.command] else { continue }
            view.image = NSImage(systemSymbolName: button.symbol, accessibilityDescription: button.title)
            view.tooltip = button.title
            view.isEnabled = button.isEnabled
        }
        liveLine.isOn = pane.showsLiveExecutionLine
        if pane.tasks != drawn?.tasks || pane.selectedTask != drawn?.selectedTask {
            sections[0].setContent(taskViews(pane))
        }
        if pane.callStack != drawn?.callStack {
            sections[1].setContent(frameViews(pane.callStack))
        }
        if pane.locals != drawn?.locals {
            sections[2].setContent(variableViews(pane.locals, emptyText: DebugPaneModel.noLocalsText))
        }
        if pane.globals != drawn?.globals {
            sections[3].setContent(variableViews(pane.globals, emptyText: DebugPaneModel.noGlobalsText))
        }
        if pane.files != drawn?.files {
            sections[4].setContent(fileViews(pane.files))
        }
        drawn = pane
        root.invalidateLayout()
    }

    /// Redraws every section, after a disclosure row opens or closes.
    private func rebuild() {
        drawn = nil
        refresh()
    }

    // MARK: Tasks

    private func taskViews(_ pane: DebugPaneModel) -> [AUIView] {
        guard !pane.tasks.isEmpty else { return [Self.emptyText(DebugPaneModel.noTasksText)] }
        var views: [AUIView] = []
        for task in pane.tasks {
            let row = taskRow(task)
            Click.on(row) { [weak self] in
                guard let self else { return }
                DebugPaneModel.selectTask(id: task.id, on: self.model)
            }
            views += [row, AUIDivider()]
        }
        if let detail = pane.selectedTask {
            views.append(taskDetail(detail))
        }
        return views
    }

    private func taskRow(_ task: DebugPaneModel.TaskRow) -> AUIView {
        let id = Self.label(task.idText, color: .secondary)
        id.usesMonospacedDigits = true
        id.minimumSize = CGSize(width: 34, height: 0)
        let name = Self.label(task.name)
        name.isBold = true
        let tint = Self.color(for: task.stateKind)
        let state = Self.label(task.stateText, color: tint, size: 9)
        state.isBold = true
        state.padding = AUIEdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
        let badge = LogPaneAUI.card(state, color: tint.opacity(0.18), cornerRadius: 7)
        var lines: [AUIView] = [LogPaneAUI.row([id, name.stretches(), badge])]
        if !task.metadata.isEmpty {
            lines.append(LogPaneAUI.row(task.metadata.map { Self.label($0, color: .secondary, size: 10) }, spacing: 10))
        }
        if let text = task.suspensionText { lines.append(Self.label(text, color: .secondary, size: 10)) }
        if let text = task.resultText { lines.append(Self.label(text, color: .secondary, size: 10)) }
        if let text = task.errorText {
            let error = Self.label(text, color: .red, size: 10)
            error.lineLimit = 2
            lines.append(error)
        }
        let content = PromptEditorAUI.column(lines, spacing: 4)
        content.padding = AUIEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        return LogPaneAUI.card(content, color: task.isSelected ? AUIColor.accent.opacity(0.18) : nil, cornerRadius: 5)
    }

    private func taskDetail(_ detail: DebugPaneModel.TaskDetail) -> AUIView {
        let heading = Self.label("Selected Task")
        heading.isBold = true
        var lines: [AUIView] = [LogPaneAUI.row([heading, AUISpacer(), Self.label(detail.idText, color: .secondary)])]
        let grid = AUIGrid(columns: 2, columnSpacing: 12, rowSpacing: 4)
        for field in detail.fields {
            let label = Self.label(field.label, color: .secondary)
            label.minimumSize = CGSize(width: 62, height: 0)
            let value = Self.label(field.value, color: field.isError ? .red : nil)
            value.lineLimit = 2
            value.truncationMode = .middle
            grid.addChild(label)
            grid.addChild(value)
        }
        lines.append(grid)
        if detail.frames.isEmpty {
            lines.append(Self.label(DebugPaneModel.noSuspendedFramesText, color: .secondary, size: 10))
        } else {
            let title = Self.label("Suspended Frames", size: 10)
            title.isBold = true
            lines.append(title)
            for frame in detail.frames {
                var parts: [AUIView] = [
                    Self.label("\(frame.index)", color: .secondary, size: 10).minimumSize(width: 18, height: 0),
                    Self.label(frame.kind, color: .secondary, size: 10).minimumSize(width: 70, height: 0),
                    Self.label(frame.name, size: 10).stretches(),
                ]
                if let location = frame.locationText {
                    parts.append(Self.label(location, color: .secondary, size: 10))
                }
                lines.append(LogPaneAUI.row(parts))
                if !frame.locals.isEmpty {
                    lines.append(disclosure("frame-\(detail.idText)-\(frame.index)", title: "Locals", indent: 26) {
                        frame.locals.flatMap { self.variableNode($0, indent: 12) }
                    })
                }
            }
        }
        if !detail.capturedGlobals.isEmpty {
            lines.append(disclosure("globals-\(detail.idText)", title: "Captured Globals", indent: 0) {
                detail.capturedGlobals.flatMap { self.variableNode($0, indent: 12) }
            })
        }
        let content = PromptEditorAUI.column(lines, spacing: 8)
        content.padding = AUIEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        let box = LogPaneAUI.card(content, color: AUIColor.textBackground.opacity(0.48), cornerRadius: 6)
        // The separator-colored outline `DebugPane` strokes around it.
        box.borderWidth = 1
        box.borderColor = .separator
        return box
    }

    // MARK: Call stack, variables, files

    private func frameViews(_ frames: [DebugPaneModel.FrameRow]) -> [AUIView] {
        guard !frames.isEmpty else { return [Self.emptyText(DebugPaneModel.noFramesText)] }
        return frames.flatMap { frame -> [AUIView] in
            var parts: [AUIView] = [
                Self.label(frame.kind, color: .secondary).minimumSize(width: 72, height: 0),
                Self.label(frame.name).stretches(),
            ]
            if let metadata = frame.metadata { parts.append(Self.label(metadata, color: .secondary)) }
            if let line = frame.lineText { parts.append(Self.label(line, color: .secondary)) }
            let content = LogPaneAUI.row(parts)
            content.padding = AUIEdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 6)
            let row = LogPaneAUI.card(content, color: frame.isSelected ? AUIColor.accent.opacity(0.18) : nil, cornerRadius: 5)
            Click.on(row) { [weak self] in
                guard let self else { return }
                DebugPaneModel.selectFrame(index: frame.index, on: self.model)
            }
            return [row, AUIDivider()]
        }
    }

    private func variableViews(_ variables: [BASICVariableSnapshot], emptyText: String) -> [AUIView] {
        guard !variables.isEmpty else { return [Self.emptyText(emptyText)] }
        return variables.flatMap { variableNode($0, indent: 0) + [AUIDivider()] }
    }

    /// A variable's row, then, when it is open, its children's, indented 14.
    private func variableNode(_ variable: BASICVariableSnapshot, indent: CGFloat) -> [AUIView] {
        let hasChildren = !variable.children.isEmpty
        let isOpen = openRows.contains(variable.id)
        let marker = AUIImageView(hasChildren ? DisclosureSection.chevron(isOpen: isOpen) : nil)
        marker.contentTint = .secondary
        marker.minimumSize = CGSize(width: 12, height: 12)
        marker.maximumSize = CGSize(width: 12, height: 12)
        let name = Self.label(variable.name)
        name.isBold = true
        name.minimumSize = CGSize(width: 70, height: 0)
        let type = Self.label(variable.typeName, color: .secondary)
        type.minimumSize = CGSize(width: 96, height: 0)
        let value = Self.label(variable.value)
        value.font = .monospaced(size: 11)
        value.truncationMode = .middle
        let row = LogPaneAUI.row([marker, name, type, value.stretches()])
        row.padding = AUIEdgeInsets(top: 5, leading: indent, bottom: 5, trailing: 0)
        guard hasChildren else { return [row] }
        Click.on(row) { [weak self] in self?.toggle(variable.id) }
        guard isOpen else { return [row] }
        return [row] + variable.children.flatMap { variableNode($0, indent: indent + 14) }
    }

    private func fileViews(_ files: [DebugPaneModel.FileRow]) -> [AUIView] {
        guard !files.isEmpty else { return [Self.emptyText(DebugPaneModel.noFilesText)] }
        return files.flatMap { file -> [AUIView] in
            let reference = Self.label(file.reference)
            reference.font = .monospaced(size: 12, weight: .semibold)
            let status = Self.label(file.statusText, color: file.isOpen ? .green : .secondary)
            let access = Self.label(file.accessText, color: .secondary)
            let position = Self.label(file.positionText)
            position.font = .monospaced(size: 10)
            let path = Self.label(file.pathText, color: file.hasPath ? nil : .secondary)
            path.font = .monospaced(size: 10)
            path.truncationMode = .middle
            var facts: [AUIView] = file.flags.map { Self.label($0, color: .secondary) }
            if let error = file.errorText { facts.append(Self.label(error, color: .red)) }
            var lines: [AUIView] = [LogPaneAUI.row([reference, status, access, AUISpacer(), position]), path]
            if !facts.isEmpty { lines.append(LogPaneAUI.row(facts)) }
            let row = PromptEditorAUI.column(lines, spacing: 3)
            row.padding = AUIEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
            return [row, AUIDivider()]
        }
    }

    // MARK: Pieces

    /// A closed-by-default disclosure row inside a section, such as a
    /// suspended frame's Locals.
    private func disclosure(_ key: String, title: String, indent: CGFloat, content: () -> [AUIView]) -> AUIView {
        let isOpen = openRows.contains(key)
        let chevron = AUIImageView(DisclosureSection.chevron(isOpen: isOpen))
        chevron.minimumSize = CGSize(width: 12, height: 12)
        chevron.maximumSize = CGSize(width: 12, height: 12)
        let header = LogPaneAUI.row([chevron, Self.label(title, size: 10), AUISpacer()], spacing: 4)
        header.padding = AUIEdgeInsets(top: 0, leading: indent, bottom: 0, trailing: 0)
        Click.on(header) { [weak self] in self?.toggle(key) }
        let views = isOpen ? content() : []
        let column = PromptEditorAUI.column([header] + views, spacing: 0)
        return column
    }

    private func toggle(_ key: String) {
        if openRows.contains(key) { openRows.remove(key) } else { openRows.insert(key) }
        rebuild()
    }

    /// The state capsule colors `DebugPane` uses.
    static func color(for kind: DebugPaneModel.StateKind) -> AUIColor {
        switch kind {
        case .ready: .yellow
        case .running: .accent
        case .suspended: .orange
        case .completed: .green
        case .cancelled: .secondary
        case .failed: .red
        }
    }

    static func label(_ text: String, color: AUIColor? = nil, size: CGFloat = 11) -> AUILabel {
        let label = AUILabel(text)
        label.font = .system(size: size)
        label.textColor = color
        return label
    }

    static func emptyText(_ text: String) -> AUILabel {
        let label = label(text, color: .secondary, size: 12)
        label.padding = AUIEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        return label
    }
}

/// A title that opens and closes the rows under it, like SwiftUI's
/// `DisclosureGroup`: a chevron down when open, right when closed.
@MainActor
final class DisclosureSection {
    let root: AUIStack
    let header: AUIButton
    let content: AUIStack
    let title: String
    private(set) var isOpen: Bool

    init(title: String, isOpen: Bool) {
        self.title = title
        self.isOpen = isOpen
        header = AUIButton("")
        header.isBordered = false
        content = PromptEditorAUI.column([], spacing: 0)
        content.padding = AUIEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        // The title sits at the leading edge, as a DisclosureGroup's does.
        root = PromptEditorAUI.column([LogPaneAUI.row([header, AUISpacer()]), content], spacing: 0)
        header.onClick = { [weak self] in self?.toggle() }
        applyOpenState()
    }

    func toggle() {
        isOpen.toggle()
        applyOpenState()
    }

    /// Replaces the rows under the title.
    func setContent(_ views: [AUIView]) {
        content.removeAllChildren()
        views.forEach(content.addChild)
    }

    /// The chevron a `DisclosureGroup` draws before its title.
    static func chevron(isOpen: Bool) -> NSImage? {
        NSImage(systemSymbolName: chevronSymbol(isOpen: isOpen), accessibilityDescription: isOpen ? "Collapse" : "Expand")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
    }

    static func chevronSymbol(isOpen: Bool) -> String {
        isOpen ? "chevron.down" : "chevron.right"
    }

    private func applyOpenState() {
        header.title = title
        header.image = Self.chevron(isOpen: isOpen)
        content.isHidden = !isOpen
        root.invalidateLayout()
    }
}

/// The Debug pane's body: the code view at its resolved height, a handle
/// that drags it, and the section list under both.
@MainActor
final class DebugBodyLayout: AUIView {
    let code: AUIView
    let handle: AUINativeHost
    let list: AUIView
    /// The code view's dragged height, or nil until the handle is dragged.
    private(set) var draggedHeight: CGFloat?

    init(code: AUIView, list: AUIView) {
        self.code = code
        self.list = list
        let grip = DragHandleView(axis: .vertical)
        grip.toolTip = "Resize debugger panes"
        handle = AUINativeHost(grip, sizing: .fixed(CGSize(width: 44, height: 12)))
        super.init(nativeView: AUIView.makeContainerBacking())
        addChild(code)
        addChild(handle)
        addChild(list)
        flexibility = .both()
        var dragStart: CGFloat?
        grip.onDrag = { [weak self] travel, phase in
            guard let self else { return }
            let available = self.nativeView.bounds.height
            switch phase {
            case .began:
                dragStart = self.draggedHeight ?? DebugPaneModel.resolvedCodePaneHeight(totalHeight: available, dragged: nil)
            case .changed:
                self.draggedHeight = DebugPaneModel.draggedCodePaneHeight(
                    startHeight: dragStart ?? 0, translation: travel, availableHeight: available
                )
                self.invalidateLayout()
            case .ended:
                dragStart = nil
            }
        }
    }

    override func preferredSize(fitting available: CGSize) -> CGSize {
        available
    }

    override func layoutChildren(in bounds: CGRect) {
        let codeHeight = DebugPaneModel.resolvedCodePaneHeight(totalHeight: bounds.height, dragged: draggedHeight)
        code.place(in: CGRect(x: bounds.minX + 12, y: bounds.minY + 12, width: max(0, bounds.width - 24), height: codeHeight))
        let handleTop = bounds.minY + 12 + codeHeight
        handle.place(in: CGRect(x: bounds.minX, y: handleTop, width: bounds.width, height: 12))
        let listTop = handleTop + 12
        list.place(in: CGRect(x: bounds.minX, y: listTop, width: bounds.width, height: max(0, bounds.maxY - listTop)))
    }
}

/// Clicks on views that are not controls: task and call-stack rows,
/// variables with children.
@MainActor
enum Click {
    /// Calls `action` when `view` is clicked. The handler lives as long as
    /// the view.
    static func on(_ view: AUIView, _ action: @escaping @MainActor () -> Void) {
        let target = Target(action)
        view.nativeView.addGestureRecognizer(NSClickGestureRecognizer(target: target, action: #selector(Target.clicked)))
        view.retainCancellation { _ = target }
    }

    /// Clicks `view` as the user would, for a test.
    static func simulate(_ view: AUIView) {
        for recognizer in view.nativeView.gestureRecognizers {
            (recognizer.target as? Target)?.clicked()
        }
    }

    /// The recognizer's target. A gesture recognizer fires on the main
    /// thread, so the target lives on the main actor.
    @MainActor
    final class Target: NSObject {
        let action: @MainActor () -> Void

        init(_ action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @objc func clicked() {
            action()
        }
    }
}
