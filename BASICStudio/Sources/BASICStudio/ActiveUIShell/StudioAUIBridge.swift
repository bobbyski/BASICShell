//
//  StudioAUIBridge.swift
//  BASICStudio
//
//  A BASIC program's own windows: BASICCore's AUI requests, made real.
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

/// Makes the ActiveUI controls a BASIC program asks for (`AUIWindow("…")`
/// and the rest), and reports what the user does back to the program
/// (ACTIVEUI_TRANSITION.md P6).
///
/// ```text
///   interpreter thread                 main thread
///   auiPerform(.create …) ──hop──►  perform: build the AUIView, keep it by id
///                                     button click ─► postEvent(CLICK, id)
///   win.run() polls .isOpen ◄───────  window closes ─► postEvent(CLOSE, id)
/// ```
///
/// Works under either shell: a program's window is its own `AUIWindow`,
/// beside Studio's. The program's windows close when the program ends,
/// because nothing is left to answer them.
@MainActor
final class StudioAUIBridge {
    /// Where the user's actions go: `BASICSession.postAUIEvent`. `column`
    /// is a table cell's, with `index` its row; -1 for everything else.
    var postEvent: ((_ kind: String, _ source: Int, _ text: String, _ index: Int, _ column: Int) -> Void)?
    /// How a dialog is shown. Tests answer at once instead.
    var presentDialog: (_ title: String, _ message: String, _ buttons: [String], _ done: @escaping @MainActor (Int) -> Void) -> Void = { title, message, buttons, done in
        AUIAlert.present(title: title, message: message, buttons: buttons, completion: done)
    }

    /// False in tests: windows are marked open and closed, and report their
    /// close to the program, without appearing on screen.
    var showsWindows = true

    private(set) var views: [Int: AUIView] = [:]
    private(set) var windows: [Int: AUIWindow] = [:]
    /// A window's content: controls added to the window go in here.
    private var windowRoots: [Int: AUIStack] = [:]
    private var openWindows: Set<Int> = []
    private var rows: [Int: RowStore] = [:]
    private var dialogs: [Int: Dialog] = [:]
    private var tabs: [Int: Tabs] = [:]
    private var pies: [Int: Pie] = [:]
    /// The size each window asked for with `size`, if it did.
    private var sizes: [Int: CGSize] = [:]

    private struct Dialog {
        var title: String
        var message: String
        var buttons: [String] = []
    }

    /// A list's or table's rows, read by its table's closures, and how each
    /// of a table's columns shows its cells.
    @MainActor
    final class RowStore {
        var rows: [[String]] = []
        var styles: [Int: BASICAUIColumnStyle] = [:]

        func cell(_ row: Int, _ column: Int) -> String {
            guard rows.indices.contains(row), rows[row].indices.contains(column) else { return "" }
            return rows[row][column]
        }

        func setCell(_ row: Int, _ column: Int, _ text: String) {
            guard rows.indices.contains(row) else { return }
            while rows[row].count <= column { rows[row].append("") }
            rows[row][column] = text
        }
    }

    /// Tabs: the pages so far, and the tab view showing them, which is made
    /// again as pages are added because an `AUITabView` takes its pages once.
    /// `holder` is the control the program put in its window.
    @MainActor
    final class Tabs {
        let holder: AUIStack
        var pages: [(title: String, view: AUIView)] = []
        var view: AUITabView?
        var selected = 0

        init(holder: AUIStack) {
            self.holder = holder
        }
    }

    /// A pie chart: its slices, which its sector mark reads.
    @MainActor
    final class Pie {
        let chart: AUIChart
        var slices: [(label: String, value: Double)] = []

        init(chart: AUIChart) {
            self.chart = chart
        }
    }

    // MARK: Requests

    /// Carries out one request from the program.
    func perform(_ request: BASICAUIRequest) throws -> BASICAUIAnswer {
        switch request {
        case .create(let id, let kind, let arguments):
            try create(id: id, kind: kind, arguments: arguments)
        case .add(let parent, let child):
            guard let childView = views[child] else { throw missing(child) }
            guard let container = windowRoots[parent] ?? (views[parent] as? AUIStack) else { throw missing(parent) }
            childView.removeFromParent()
            container.addChild(childView)
            container.invalidateLayout()
        case .addTab(let id, let title, let child):
            guard let tabs = tabs[id] else { throw missing(id) }
            guard let page = views[child] else { throw missing(child) }
            page.removeFromParent()
            tabs.pages.append((title, page))
            rebuild(tabs, id: id)
        case .setText(let id, let text):
            if let window = windows[id] {
                window.title = text
            } else if let label = views[id] as? AUILabel {
                label.text = text
            } else if let button = views[id] as? AUIButton {
                button.title = text
            } else if let field = views[id] as? AUITextField {
                field.text = text
            } else if let picker = views[id] as? AUIDatePicker {
                picker.date = Self.date(from: text) ?? picker.date
            } else {
                throw missing(id)
            }
        case .text(let id):
            if let label = views[id] as? AUILabel { return .text(label.text) }
            if let field = views[id] as? AUITextField { return .text(field.text) }
            if let picker = views[id] as? AUIDatePicker { return .text(Self.text(of: picker.date)) }
            throw missing(id)
        case .addItem(let id, let cells):
            if let picker = views[id] as? AUIPicker {
                picker.options.append(cells.first ?? "")
                return .none
            }
            guard let store = rows[id], let table = views[id] as? AUITable else { throw missing(id) }
            store.rows.append(cells)
            table.reloadData()
        case .clearItems(let id):
            if let picker = views[id] as? AUIPicker {
                picker.options = []
                picker.selectedIndex = nil
                return .none
            }
            if let pie = pies[id] {
                pie.slices.removeAll()
                pie.chart.redraw()
                return .none
            }
            guard let store = rows[id], let table = views[id] as? AUITable else { throw missing(id) }
            store.rows.removeAll()
            table.selectedRows = []
            table.reloadData()
        case .itemCount(let id):
            if let picker = views[id] as? AUIPicker { return .number(Double(picker.options.count)) }
            if let pie = pies[id] { return .number(Double(pie.slices.count)) }
            if let tabs = tabs[id] { return .number(Double(tabs.pages.count)) }
            guard let store = rows[id] else { throw missing(id) }
            return .number(Double(store.rows.count))
        case .selectedIndex(let id):
            if let picker = views[id] as? AUIPicker { return .number(Double(picker.selectedIndex ?? -1)) }
            if let tabs = tabs[id] { return .number(Double(tabs.pages.isEmpty ? -1 : tabs.selected)) }
            guard let table = views[id] as? AUITable else { throw missing(id) }
            return .number(Double(table.selectedRows.first ?? -1))
        case .selectedText(let id):
            if let picker = views[id] as? AUIPicker {
                guard let index = picker.selectedIndex, picker.options.indices.contains(index) else { return .text("") }
                return .text(picker.options[index])
            }
            if let tabs = tabs[id] {
                return .text(tabs.pages.indices.contains(tabs.selected) ? tabs.pages[tabs.selected].title : "")
            }
            guard let table = views[id] as? AUITable, let store = rows[id] else { throw missing(id) }
            guard let row = table.selectedRows.first, store.rows.indices.contains(row) else { return .text("") }
            return .text(store.rows[row].first ?? "")
        case .select(let id, let index):
            if let picker = views[id] as? AUIPicker {
                picker.selectedIndex = picker.options.indices.contains(index) ? index : nil
            } else if let tabs = tabs[id] {
                guard tabs.pages.indices.contains(index) else { return .none }
                tabs.selected = index
                tabs.view?.selectedTabIndex = index
            } else if let table = views[id] as? AUITable, let store = rows[id] {
                table.selectedRows = store.rows.indices.contains(index) ? [index] : []
                if store.rows.indices.contains(index) { table.revealRow(index) }
            } else {
                throw missing(id)
            }
        case .setColumnStyle(let id, let column, let style):
            guard let store = rows[id], let table = views[id] as? AUITable else { throw missing(id) }
            store.styles[column] = style
            table.reloadData()
        case .cell(let id, let row, let column):
            guard let store = rows[id] else { throw missing(id) }
            return .text(store.cell(row, column))
        case .setCell(let id, let row, let column, let text):
            guard let store = rows[id], let table = views[id] as? AUITable else { throw missing(id) }
            guard store.rows.indices.contains(row) else {
                throw BASICError.runtime("AUITable has rows 0 to \(store.rows.count - 1), not \(row)")
            }
            store.setCell(row, column, text)
            table.reloadRows([row])
        case .addSlice(let id, let label, let value):
            guard let pie = pies[id] else { throw missing(id) }
            pie.slices.append((label, value))
            pie.chart.redraw()
        case .setSize(let id, let width, let height):
            guard let window = windows[id] else { throw missing(id) }
            sizes[id] = CGSize(width: width, height: height)
            if openWindows.contains(id), showsWindows {
                window.setContentSize(CGSize(width: width, height: height))
            }
        case .setEnabled(let id, let enabled):
            guard let view = views[id] else { throw missing(id) }
            view.isEnabled = enabled
        case .addButton(let id, let title):
            guard dialogs[id] != nil else { throw missing(id) }
            dialogs[id]?.buttons.append(title)
        case .show(let id):
            guard let window = windows[id] else { throw missing(id) }
            openWindows.insert(id)
            if showsWindows {
                window.show()
                // A program's window is the size it asked for, or else fits
                // what the program put in it, at least 480 × 360 and no taller
                // than 900.
                if let size = sizes[id] {
                    window.setContentSize(size)
                } else if let root = windowRoots[id] {
                    let fitted = root.layoutSize(fitting: CGSize(width: 520, height: 10_000))
                    window.setContentSize(CGSize(width: max(480, fitted.width), height: min(900, max(360, fitted.height))))
                }
            }
        case .close(let id):
            guard let window = windows[id] else { throw missing(id) }
            if showsWindows {
                window.close()
            } else {
                windowClosed(id)
            }
        case .isOpen(let id):
            return .flag(openWindows.contains(id))
        }
        return .none
    }

    /// Whether `id` is a dialog, whose `show` waits for an answer.
    func isDialog(_ id: Int) -> Bool {
        dialogs[id] != nil
    }

    /// Shows dialog `id` and reports the index of the button pressed.
    func showDialog(_ id: Int, done: @escaping @MainActor (Int) -> Void) {
        guard let dialog = dialogs[id] else {
            done(-1)
            return
        }
        let buttons = dialog.buttons.isEmpty ? ["OK"] : dialog.buttons
        presentDialog(dialog.title, dialog.message, buttons, done)
    }

    /// Closes every window the program opened and forgets every control:
    /// the program is over.
    func closeAll() {
        let open = openWindows
        openWindows.removeAll()
        for id in open {
            windows[id]?.close()
        }
        views.removeAll()
        windows.removeAll()
        windowRoots.removeAll()
        rows.removeAll()
        dialogs.removeAll()
        tabs.removeAll()
        pies.removeAll()
        sizes.removeAll()
    }

    // MARK: Making controls

    private func create(id: Int, kind: BASICAUIKind, arguments: [String]) throws {
        let first = arguments.first ?? ""
        switch kind {
        case .window:
            let root = AUIStack(.vertical, spacing: 10, alignment: .fill)
            root.wraps = false
            root.padding = AUIEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
            let window = AUIWindow(title: first, rootView: root, contentSize: CGSize(width: 480, height: 360))
            window.onClose = { [weak self] in self?.windowClosed(id) }
            windows[id] = window
            windowRoots[id] = root
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
                self?.postEvent?("CLICK", id, button?.title ?? "", -1, -1)
            }
            views[id] = button
        case .field:
            let field = AUITextField(first, placeholder: arguments.count > 1 ? arguments[1] : nil)
            field.onSubmit = { [weak self] text in self?.postEvent?("SUBMIT", id, text, -1, -1) }
            field.onChange = { [weak self] text in self?.postEvent?("CHANGE", id, text, -1, -1) }
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
            let store = RowStore()
            let columns = arguments.enumerated().map { column, title in
                AUITableColumn(title) { [weak self] row in
                    self?.cellView(id: id, store: store, row: row, column: column) ?? AUILabel("")
                }
            }
            let table = AUITable(columns: columns, rowCount: { store.rows.count })
            watchSelection(of: table, id: id, store: store)
            rows[id] = store
            views[id] = table
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
                self?.postEvent?("CHANGE", id, options.indices.contains(index) ? options[index] : "", index, -1)
            }
            views[id] = picker
        case .date:
            let picker = AUIDatePicker(date: Self.date(from: first) ?? Date())
            picker.onChange = { [weak self] date in
                self?.postEvent?("CHANGE", id, Self.text(of: date), -1, -1)
            }
            views[id] = picker
        case .pieChart:
            let chart = AUIChart()
            let pie = Pie(chart: chart)
            chart.marks = [
                AUISectorMark(count: { pie.slices.count }) { index in
                    AUIDataPoint(pie.slices[index].label, pie.slices[index].value)
                }
                .showsLabels(true)
            ]
            chart.title = first.isEmpty ? nil : first
            chart.legendIsVisible = true
            chart.minimumSize = CGSize(width: 260, height: 220)
            chart.flexibility = .both()
            pies[id] = pie
            views[id] = chart
        }
        if let table = views[id] as? AUITable {
            table.minimumSize = CGSize(width: 200, height: 120)
            table.flexibility = .both()
        }
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
            field.fieldStyle = .plain
            field.textProvider = { store.cell(row, column) }
            field.onEndEditing = { [weak self] newText in
                guard newText != store.cell(row, column) else { return }
                store.setCell(row, column, newText)
                self?.postEvent?("CHANGE", id, newText, row, column)
            }
            return field
        case .choices(let choices):
            let segments = AUISegmentedControl(choices, selectedIndex: choices.firstIndex(of: text))
            segments.selectedIndexProvider = { choices.firstIndex(of: store.cell(row, column)) }
            segments.onSelectionChange = { [weak self] index in
                guard choices.indices.contains(index), choices[index] != store.cell(row, column) else { return }
                store.setCell(row, column, choices[index])
                self?.postEvent?("CHANGE", id, choices[index], row, column)
            }
            return segments
        }
    }

    /// Makes tabs' view again with every page so far, on the same tab.
    private func rebuild(_ tabs: Tabs, id: Int) {
        tabs.view?.removeFromParent()
        for page in tabs.pages { page.view.removeFromParent() }
        let selected = min(tabs.selected, tabs.pages.count - 1)
        let view = AUITabView(tabs.pages.map { (title: $0.title, content: $0.view) }, selectedIndex: max(0, selected))
        view.flexibility = .both()
        view.onTabChange = { [weak self, weak tabs] index in
            guard let tabs else { return }
            tabs.selected = index
            let title = tabs.pages.indices.contains(index) ? tabs.pages[index].title : ""
            self?.postEvent?("CHANGE", id, title, index, -1)
        }
        tabs.view = view
        tabs.holder.addChild(view)
        tabs.holder.invalidateLayout()
    }

    /// A date as AUIDate gives and takes it: `YYYY-MM-DD`, in the user's
    /// own calendar day.
    nonisolated static func text(of date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

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

    /// A window went away, by the user or the program: tell the program.
    /// Not for a window closeAll put away; the program is gone by then.
    private func windowClosed(_ id: Int) {
        guard openWindows.remove(id) != nil else { return }
        postEvent?("CLOSE", id, "", -1, -1)
    }

    private func watchSelection(of table: AUITable, id: Int, store: RowStore) {
        table.onSelectionChange = { [weak self] selected in
            guard let row = selected.first, store.rows.indices.contains(row) else { return }
            self?.postEvent?("SELECT", id, store.rows[row].first ?? "", row, -1)
        }
    }

    private func missing(_ id: Int) -> BASICError {
        BASICError.runtime("ActiveUI control \(id) is not one this request applies to")
    }
}

extension StudioModel: BASICAUIHost {
    /// A program's window request, carried to the main thread. A dialog's
    /// `show` waits here, on the program's thread, for the button, leaving
    /// the main thread free to run the sheet.
    nonisolated func auiPerform(_ request: BASICAUIRequest) throws -> BASICAUIAnswer {
        if case .show(let id) = request, valueOnMainSync({ auiBridge.isDialog(id) }) {
            let answered = DispatchSemaphore(value: 0)
            let choice = ChoiceBox()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.auiBridge.showDialog(id) { index in
                        choice.set(index)
                        answered.signal()
                    }
                }
            }
            answered.wait()
            return .number(Double(choice.value))
        }
        let result: Result<BASICAUIAnswer, BASICError> = valueOnMainSync {
            do {
                return .success(try auiBridge.perform(request))
            } catch let error as BASICError {
                return .failure(error)
            } catch {
                return .failure(.runtime("\(error)"))
            }
        }
        return try result.get()
    }
}

/// The button a dialog answered, handed from the main thread to the
/// program's.
private final class ChoiceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var choice = -1

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return choice
    }

    func set(_ value: Int) {
        lock.lock()
        choice = value
        lock.unlock()
    }
}
