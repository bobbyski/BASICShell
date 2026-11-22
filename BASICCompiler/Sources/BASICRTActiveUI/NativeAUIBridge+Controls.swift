//
//  NativeAUIBridge+Controls.swift
//  BASICRTActiveUI
//
//  Making each control a compiled program asks for.
//

import ActiveUI
import ActiveUICharts
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import BASICCore
import Foundation

extension NativeAUIBridge {
    /// Makes control `id` of `kind`, from the constructor's arguments as
    /// text, wired to report what the user does with it. The same controls,
    /// with the same spacing and sizes, as BASICStudio's bridge makes.
    func create(id: Int, kind: BASICAUIKind, arguments: [String]) throws {
        let first = arguments.first ?? ""
        switch kind {
        case .window:
            let root = AUIStack(.vertical, spacing: 10, alignment: .fill)
            root.wraps = false
            root.padding = AUIEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
            let window = AUIWindow(title: first, rootView: root, contentSize: CGSize(width: 480, height: 360))
            register(window: window, root: root, id: id)
        case .stack:
            let axis: AUIStack.Axis = first.uppercased() == "HORIZONTAL" ? .horizontal : .vertical
            let stack = AUIStack(axis, spacing: 8, alignment: axis == .vertical ? .fill : .center)
            stack.wraps = false
            views[id] = stack
        case .label:
            views[id] = AUILabel(first)
        case .button:
            let button = AUIButton(first)
            button.onClick = { [weak self, weak button] in
                self?.post("CLICK", id, button?.title ?? "", -1, -1)
            }
            views[id] = button
        case .field:
            let field = AUITextField(first, placeholder: arguments.count > 1 ? arguments[1] : nil)
            field.onSubmit = { [weak self] text in self?.post("SUBMIT", id, text, -1, -1) }
            field.onChange = { [weak self] text in self?.post("CHANGE", id, text, -1, -1) }
            views[id] = field
        case .list:
            let store = RowStore()
            let table = AUITable(rowCount: { store.rows.count }) { row in
                AUILabel(store.rows[row].first ?? "")
            }
            watchSelection(of: table, id: id, store: store)
            rows[id] = store
            views[id] = table
        case .table:
            makeTable(id: id, titles: arguments)
        case .dialog:
            dialogs[id] = Dialog(title: first, message: arguments.count > 1 ? arguments[1] : "")
        case .tabs:
            let holder = AUIStack(.vertical, spacing: 0, alignment: .fill)
            holder.wraps = false
            holder.flexibility = .both()
            tabs[id] = Tabs(holder: holder)
            views[id] = holder
        case .picker:
            let picker = AUIPicker(arguments, selectedIndex: arguments.isEmpty ? nil : 0)
            picker.onSelectionChange = { [weak self, weak picker] index in
                let options = picker?.options ?? []
                self?.post("CHANGE", id, options.indices.contains(index) ? options[index] : "", index, -1)
            }
            views[id] = picker
        case .date:
            let picker = AUIDatePicker(date: Self.date(from: first) ?? Date())
            picker.onChange = { [weak self] date in
                self?.post("CHANGE", id, Self.text(of: date), -1, -1)
            }
            views[id] = picker
        case .pieChart:
            makePieChart(id: id, title: first)
        }
        if let table = views[id] as? AUITable {
            table.minimumSize = CGSize(width: 200, height: 120)
            table.flexibility = .both()
        }
    }

    /// A table with a column for each title, read across: titles over
    /// lined-up columns.
    private func makeTable(id: Int, titles: [String]) {
        let store = RowStore()
        let columns = titles.enumerated().map { column, title in
            AUITableColumn(title) { [weak self] row in
                self?.cellView(id: id, store: store, row: row, column: column) ?? AUILabel("")
            }
        }
        let table = AUITable(columns: columns, rowCount: { store.rows.count })
        table.showsColumnTitles = true
        watchSelection(of: table, id: id, store: store)
        rows[id] = store
        views[id] = table
    }

    /// A pie chart whose slices are each a series of their own, so each has
    /// its own color and the legend names it: a pie of one color says nothing.
    private func makePieChart(id: Int, title: String) {
        let chart = AUIChart()
        let pie = Pie(chart: chart)
        chart.marks = [
            AUISectorMark(count: { pie.slices.count }) { index in
                AUIDataPoint(pie.slices[index].label, pie.slices[index].value, series: pie.slices[index].label)
            }
            .showsLabels(true)
        ]
        chart.title = title.isEmpty ? nil : title
        chart.legendIsVisible = true
        chart.minimumSize = CGSize(width: 260, height: 220)
        chart.flexibility = .both()
        pies[id] = pie
        views[id] = chart
    }

    /// A table cell as its column shows it: text, a field the user types
    /// into, or one choice of a few. What the user changes goes into the
    /// table's rows first, so a reload shows it, then to the program.
    private func cellView(id: Int, store: RowStore, row: Int, column: Int) -> AUIView {
        let text = store.cell(row, column)
        switch store.styles[column] ?? .text {
        case .text:
            return AUILabel(text)
        case .editable:
            let field = AUITextField(text)
            field.textProvider = { store.cell(row, column) }
            field.onEndEditing = { [weak self] newText in
                guard newText != store.cell(row, column) else { return }
                store.setCell(row, column, newText)
                self?.post("CHANGE", id, newText, row, column)
            }
            return field
        case .choices(let choices):
            let segments = AUISegmentedControl(choices, selectedIndex: choices.firstIndex(of: text))
            segments.selectedIndexProvider = { choices.firstIndex(of: store.cell(row, column)) }
            segments.onSelectionChange = { [weak self] index in
                guard choices.indices.contains(index), choices[index] != store.cell(row, column) else { return }
                store.setCell(row, column, choices[index])
                self?.post("CHANGE", id, choices[index], row, column)
            }
            return segments
        }
    }

    /// Makes tabs' view again with every page so far, on the same tab.
    func rebuild(_ tabs: Tabs, id: Int) {
        tabs.view?.removeFromParent()
        for page in tabs.pages { page.view.removeFromParent() }
        let selected = min(tabs.selected, tabs.pages.count - 1)
        let view = AUITabView(tabs.pages.map { (title: $0.title, content: $0.view) }, selectedIndex: max(0, selected))
        view.flexibility = .both()
        view.onTabChange = { [weak self, weak tabs] index in
            guard let tabs else { return }
            tabs.selected = index
            let title = tabs.pages.indices.contains(index) ? tabs.pages[index].title : ""
            self?.post("CHANGE", id, title, index, -1)
        }
        tabs.view = view
        tabs.holder.addChild(view)
        tabs.holder.invalidateLayout()
    }

    /// Reports the row the user picks in a list or table.
    private func watchSelection(of table: AUITable, id: Int, store: RowStore) {
        table.onSelectionChange = { [weak self] selected in
            guard let row = selected.first, store.rows.indices.contains(row) else { return }
            self?.post("SELECT", id, store.rows[row].first ?? "", row, -1)
        }
    }

    /// A date as AUIDate gives and takes it: `YYYY-MM-DD`, in the user's
    /// own calendar day.
    nonisolated static func text(of date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The day a `YYYY-MM-DD` names, at noon, or nil when it names none.
    nonisolated static func date(from text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 12
        return Calendar(identifier: .gregorian).date(from: components)
    }

    // MARK: The scripted user

    /// Every button titled `title`, in the order they were made.
    func buttons(titled title: String) -> [AUIButton] {
        views.keys.sorted().compactMap { views[$0] as? AUIButton }.filter { $0.title == title }
    }

    /// The first list or table the program made, and its id.
    func firstList() -> (id: Int, table: AUITable)? {
        for id in views.keys.sorted() {
            if let table = views[id] as? AUITable, rows[id] != nil { return (id, table) }
        }
        return nil
    }
}
