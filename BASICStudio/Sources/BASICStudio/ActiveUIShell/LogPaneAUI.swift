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
    let header: AUIStack
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

        let firstRow = Self.ends(enabled, clear)
        // A checkbox's frame carries a couple of points past its title, so 6
        // between them looks like the 8 of `LogPane`'s HStack, and the row
        // fits the inspector's default width as that one does.
        let secondRow = Self.ends(Self.row([user, basic, trace, traceButton], spacing: 6), levels)
        header = AUIStack(.vertical, spacing: 8, alignment: .fill)
        header.wraps = false
        header.addChild(firstRow)
        header.addChild(secondRow)
        header.padding = AUIEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)

        let rows = rows
        table = AUITable(rowCount: { rows.rows.count }) { index in
            Self.rowView(rows.rows[index])
        }
        table.flexibility = .both()
        // `LogPane`'s list: 12 points in from the sides, 6 between entries
        // (the table adds 2 of its own between rows).
        table.rowHorizontalPadding = 0
        table.rowInsets = AUIEdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12)

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

        let content = AUIStack(.vertical, spacing: 3, alignment: .fill)
        content.wraps = false
        content.addChild(facts)
        content.addChild(text)
        content.padding = AUIEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        return card(content, color: tint.opacity(0.12), cornerRadius: 6)
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

    /// `content` on a tinted, rounded card that covers its padding too.
    ///
    /// A view's padding sits outside its own background (a margin, in CSS
    /// terms), so a view given both draws its tint short of its edges. The
    /// tint goes on a box around the padded content instead, the way
    /// SwiftUI's `.padding()` then `.background()` stacks.
    static func card(_ content: AUIView, color: AUIColor?, cornerRadius: CGFloat = 0) -> AUIStack {
        let card = AUIStack(.vertical, spacing: 0, alignment: .fill)
        card.wraps = false
        card.addChild(content)
        card.backgroundColor = color
        card.cornerRadius = cornerRadius
        return card
    }

    /// `leading` at the start of a row and `trailing` at its end, the way
    /// `HStack { a; Spacer(); b }` places them. When space is tight they close
    /// to the row's spacing; a spacer between them would keep a gap on each
    /// side of it, twice SwiftUI's.
    static func ends(_ leading: AUIView, _ trailing: AUIView, spacing: CGFloat = 8) -> AUIStack {
        let stack = row([leading, trailing], spacing: spacing)
        stack.distribution = .spaceBetween
        return stack
    }

    static func row(_ views: [AUIView], spacing: CGFloat = 8) -> AUIStack {
        let stack = AUIStack(.horizontal, spacing: spacing, alignment: .center)
        stack.wraps = false
        views.forEach(stack.addChild)
        return stack
    }
}
