//
//  LogPaneAUI.swift
//  BASICStudio
//
//  The Log inspector, in ActiveUI.
//

import ActiveUI
import AppKit
import Foundation

/// The Log inspector for the ActiveUI shell, drawn from ``LogPaneModel``, the
/// projection the SwiftUI `LogPane` draws from.
///
/// ```text
///   [x] Enabled                            Clear
///   [x] User [ ] BASIC [ ] Trace  (TRON)   Levels ▾
///   ─────────────────────────────────────────────
///   12:00:01.250 U INFO BASIC                     one table row per
///   hello                                         entry, tinted by level
/// ```
///
/// ``refresh()`` compares the projection with the one it last drew and does
/// nothing when they match. The rows reload only when the rows changed.
@MainActor
final class LogPaneAUI {
    let model: StudioModel
    let root: AUIView
    let enabled: AUIToggle
    let clear: AUIButton
    let user: AUIToggle
    let basic: AUIToggle
    let trace: AUIToggle
    let traceButton: AUIButton
    let levels: AUIMenuButton
    let table: AUITable
    private(set) var drawn: LogPaneModel?
    /// The rows the table shows; its closures read them from here.
    private let rows = RowStore()

    @MainActor
    private final class RowStore {
        var rows: [LogPaneModel.Row] = []
    }

    init(model: StudioModel) {
        self.model = model
        enabled = AUIToggle("Enabled") { [weak model] in model?.isLoggingEnabled = $0 }
        clear = AUIButton("Clear") { [weak model] in model?.clearLogs() }
        user = AUIToggle("User") { [weak model] in model?.showUserLogs = $0 }
        basic = AUIToggle("BASIC") { [weak model] in model?.showBasicLogs = $0 }
        trace = AUIToggle("Trace") { [weak model] in model?.isTraceLoggingEnabled = $0 }
        traceButton = AUIButton("TRON") { [weak model] in model?.toggleTraceLogging() }
        levels = AUIMenuButton("Levels", menu: Self.levelsMenu(model: model))

        let firstRow = Self.row([enabled, AUISpacer(), clear])
        let secondRow = Self.row([user, basic, trace, traceButton, AUISpacer(), levels])
        let header = AUIStack(.vertical, spacing: 8, alignment: .fill)
        header.wraps = false
        header.addChild(firstRow)
        header.addChild(secondRow)
        header.padding = AUIEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)

        let rows = rows
        table = AUITable(rowCount: { rows.rows.count }) { index in
            Self.rowView(rows.rows[index])
        }
        table.flexibility = .both()

        let body = AUIStack(.vertical, spacing: 0, alignment: .fill)
        body.wraps = false
        body.addChild(header)
        body.addChild(AUIDivider())
        body.addChild(table)
        body.backgroundColor = .controlBackground
        root = body
        refresh()
    }

    /// Brings the pane up to the model; nothing happens if nothing changed.
    func refresh() {
        let pane = LogPaneModel(model)
        guard pane != drawn else { return }
        enabled.isOn = pane.isLoggingEnabled
        user.isOn = pane.showsUserLogs
        basic.isOn = pane.showsBasicLogs
        trace.isOn = pane.isTraceLoggingEnabled
        traceButton.title = pane.traceButtonTitle
        clear.isEnabled = pane.canClear
        if pane.rows != drawn?.rows {
            rows.rows = pane.rows
            table.reloadData()
        }
        drawn = pane
    }

    /// The Levels menu, rebuilt from the projection each time it opens.
    private static func levelsMenu(model: StudioModel) -> AUIMenu {
        AUIMenu("Levels", items: []).dynamicItems { [weak model] in
            MainActor.assumeIsolated {
                guard let model else { return [] }
                let pane = LogPaneModel(model)
                guard let header = pane.levelsMenuHeader else {
                    let empty = AUIMenuItem(LogPaneModel.noLevelsTitle, action: {})
                    empty.isEnabled = false
                    return [empty]
                }
                var items = [
                    AUIMenuItem(header, action: { [weak model] in model?.selectedLogLevels.removeAll() }),
                    AUIMenuItem.separator(),
                ]
                for level in pane.levelsMenu {
                    items.append(AUIMenuItem(level.level, action: { [weak model] in
                        model?.toggleLogLevel(level.level)
                    }).checked { level.isChecked })
                }
                return items
            }
        }
    }

    /// One entry: a line of facts, then the text, on its level's tint.
    static func rowView(_ row: LogPaneModel.Row) -> AUIView {
        let tint = color(for: row.levelKind)
        let time = label(row.time, color: .secondary)
        let issuer = label(row.issuer)
        issuer.isBold = true
        let level = label(row.level, color: tint)
        level.isBold = true
        let module = label(row.module, color: .secondary)
        let facts = Self.row([time, issuer, level, module, AUISpacer()], spacing: 6)

        let text = AUILabel(row.text)
        text.font = .monospaced(size: 11)
        text.wraps = true
        text.lineLimit = nil
        text.isSelectable = true

        let box = AUIStack(.vertical, spacing: 3, alignment: .fill)
        box.wraps = false
        box.addChild(facts)
        box.addChild(text)
        box.padding = AUIEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        box.backgroundColor = tint.opacity(0.12)
        box.cornerRadius = 6
        return box
    }

    /// The level tints `LogPane` uses.
    static func color(for kind: LogPaneModel.LevelKind) -> AUIColor {
        switch kind {
        case .error: .red
        case .warning: .yellow
        case .debug: .blue
        case .target: AUIColor(red: 0.95, green: 0.15, blue: 0.85)
        case .run: .green
        case .pause: .orange
        case .plain: .primary
        }
    }

    private static func label(_ text: String, color: AUIColor? = nil) -> AUILabel {
        let label = AUILabel(text)
        label.font = .monospaced(size: 10)
        label.textColor = color
        return label
    }

    static func row(_ views: [AUIView], spacing: CGFloat = 8) -> AUIStack {
        let stack = AUIStack(.horizontal, spacing: spacing, alignment: .center)
        stack.wraps = false
        views.forEach(stack.addChild)
        return stack
    }
}
