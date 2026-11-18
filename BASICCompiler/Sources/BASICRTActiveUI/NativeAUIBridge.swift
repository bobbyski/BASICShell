//
//  NativeAUIBridge.swift
//  BASICRTActiveUI
//
//  A compiled program's own windows: BASICCore's AUI requests, made real.
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

/// Makes the ActiveUI controls a compiled BASIC program asks for
/// (`AUIWindow("…")` and the rest), and reports what the user does back to
/// the program (BASIC-31).
///
/// ```text
///   program thread                     main thread
///   auiPerform(.create …) ──hop──►  perform: build the AUIView, keep it by id
///                                     button click ─► post CLICK, id
///   win.run() polls .isOpen ◄───────  window closes ─► post CLOSE, id
/// ```
///
/// BASICStudio's `StudioAUIBridge` answers the same requests for a program
/// its interpreter runs, inside Studio; this answers them in the program's
/// own process, where the program is the application. The two are kept
/// alike on purpose, request for request: what a control does is
/// BASICCore's, and both bridges only make it real. (Studio's also opens the
/// windows of a program that imports ActiveUI itself, which a native program
/// does through ActiveUI directly.)
///
/// Every member runs on the main thread. ``NativeAUIHost`` carries each
/// request there from the program's thread.
@MainActor
final class NativeAUIBridge {
    /// What the bridge reports on stderr, and the scripted user, for a run
    /// that no one watches (see ``NativeAUIAutomation``).
    let automation: NativeAUIAutomation

    /// Every control the program made, by its id.
    var views: [Int: AUIView] = [:]
    /// Every window the program made, by its id, up or not.
    private(set) var windows: [Int: AUIWindow] = [:]
    /// A window's content: controls added to the window go in here.
    var windowRoots: [Int: AUIStack] = [:]
    /// The windows on screen now.
    private(set) var openWindows: Set<Int> = []
    /// Each list's and table's rows, by the control's id.
    var rows: [Int: RowStore] = [:]
    /// Each dialog, by its id; a dialog has no view until it is shown.
    var dialogs: [Int: Dialog] = [:]
    /// Each set of tabs, by its id.
    var tabs: [Int: Tabs] = [:]
    /// Each pie chart, by its id.
    var pies: [Int: Pie] = [:]
    /// The size each window asked for with `size`, if it did.
    private var sizes: [Int: CGSize] = [:]
    /// Whether a window has been shown yet: the scripted user starts then.
    private var hasShownAWindow = false

    /// Creates a bridge with no controls.
    init(automation: NativeAUIAutomation = NativeAUIAutomation()) {
        self.automation = automation
    }

    /// A dialog the program is building: its title, message and buttons.
    struct Dialog {
        /// What it asks.
        var title: String
        /// What it says under the title.
        var message: String
        /// Its buttons, in order; none means a single OK.
        var buttons: [String] = []
    }

    /// A list's or table's rows, read by its table's closures, and how each
    /// of a table's columns shows its cells.
    @MainActor
    final class RowStore {
        /// The rows, each a list of cells.
        var rows: [[String]] = []
        /// How each column that is not plain text shows its cells.
        var styles: [Int: BASICAUIColumnStyle] = [:]

        /// One cell, or "" when there is none.
        func cell(_ row: Int, _ column: Int) -> String {
            guard rows.indices.contains(row), rows[row].indices.contains(column) else { return "" }
            return rows[row][column]
        }

        /// Sets one cell, widening its row as needed.
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
        /// The control the program placed.
        let holder: AUIStack
        /// Every page, in order.
        var pages: [(title: String, view: AUIView)] = []
        /// The tab view showing them, once there is a page.
        var view: AUITabView?
        /// The page on show.
        var selected = 0

        /// Tabs with no pages, inside `holder`.
        init(holder: AUIStack) {
            self.holder = holder
        }
    }

    /// A pie chart: its slices, which its sector mark reads.
    @MainActor
    final class Pie {
        /// The chart the program placed.
        let chart: AUIChart
        /// Every slice, in order.
        var slices: [(label: String, value: Double)] = []

        /// A pie with no slices, drawn by `chart`.
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
            try setText(id: id, text: text)
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
            try clearItems(id: id)
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
            return .text(try selectedText(id: id))
        case .select(let id, let index):
            try select(id: id, index: index)
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
            if openWindows.contains(id) {
                window.setContentSize(CGSize(width: width, height: height))
            }
        case .setEnabled(let id, let enabled):
            guard let view = views[id] else { throw missing(id) }
            view.isEnabled = enabled
        case .addButton(let id, let title):
            guard dialogs[id] != nil else { throw missing(id) }
            dialogs[id]?.buttons.append(title)
        case .show(let id):
            try show(id)
        case .close(let id):
            guard let window = windows[id] else { throw missing(id) }
            window.close()
        case .isOpen(let id):
            return .flag(openWindows.contains(id))
        }
        return .none
    }

    /// A window's title, a label's text, a button's title, a field's text or
    /// a date picker's day.
    private func setText(id: Int, text: String) throws {
        if let window = windows[id] {
            window.title = text
        } else if let label = views[id] as? AUILabel {
            label.text = text
            automation.trace("label \(id) says \"\(text)\"")
        } else if let button = views[id] as? AUIButton {
            button.title = text
        } else if let field = views[id] as? AUITextField {
            field.text = text
        } else if let picker = views[id] as? AUIDatePicker {
            picker.date = Self.date(from: text) ?? picker.date
        } else {
            throw missing(id)
        }
    }

    /// Empties a list, a table, a picker or a pie chart.
    private func clearItems(id: Int) throws {
        if let picker = views[id] as? AUIPicker {
            picker.options = []
            picker.selectedIndex = nil
            return
        }
        if let pie = pies[id] {
            pie.slices.removeAll()
            pie.chart.redraw()
            return
        }
        guard let store = rows[id], let table = views[id] as? AUITable else { throw missing(id) }
        store.rows.removeAll()
        table.selectedRows = []
        table.reloadData()
    }

    /// The picked option, tab or row's first cell, or "" for none.
    private func selectedText(id: Int) throws -> String {
        if let picker = views[id] as? AUIPicker {
            guard let index = picker.selectedIndex, picker.options.indices.contains(index) else { return "" }
            return picker.options[index]
        }
        if let tabs = tabs[id] {
            return tabs.pages.indices.contains(tabs.selected) ? tabs.pages[tabs.selected].title : ""
        }
        guard let table = views[id] as? AUITable, let store = rows[id] else { throw missing(id) }
        guard let row = table.selectedRows.first, store.rows.indices.contains(row) else { return "" }
        return store.rows[row].first ?? ""
    }

    /// Picks a picker's option, shows a tab, or selects a row; -1 for none.
    private func select(id: Int, index: Int) throws {
        if let picker = views[id] as? AUIPicker {
            picker.selectedIndex = picker.options.indices.contains(index) ? index : nil
        } else if let tabs = tabs[id] {
            guard tabs.pages.indices.contains(index) else { return }
            tabs.selected = index
            tabs.view?.selectedTabIndex = index
        } else if let table = views[id] as? AUITable, let store = rows[id] {
            table.selectedRows = store.rows.indices.contains(index) ? [index] : []
            if store.rows.indices.contains(index) { table.revealRow(index) }
        } else {
            throw missing(id)
        }
    }

    /// Puts window `id` up, the size it asked for or else fitting what the
    /// program put in it: at least 480 × 360 and no taller than 900.
    private func show(_ id: Int) throws {
        guard let window = windows[id] else { throw missing(id) }
        openWindows.insert(id)
        window.show()
        if let size = sizes[id] {
            window.setContentSize(size)
        } else if let root = windowRoots[id] {
            let fitted = root.layoutSize(fitting: CGSize(width: 520, height: 10_000))
            window.setContentSize(CGSize(width: max(480, fitted.width), height: min(900, max(360, fitted.height))))
        }
        automation.trace("window \(id) opened: \"\(window.title)\"")
        if !hasShownAWindow {
            hasShownAWindow = true
            automation.start(on: self)
        }
    }

    // MARK: Windows and dialogs

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
        automation.trace("dialog \(id) asks \"\(dialog.title)\"")
        if let answer = automation.dialogAnswer {
            done(min(answer, buttons.count - 1))
            return
        }
        AUIAlert.present(title: dialog.title, message: dialog.message, buttons: buttons, completion: done)
    }

    /// Whether any of the program's windows is up.
    var hasOpenWindows: Bool {
        !openWindows.isEmpty
    }

    /// Closes every window the program has up, as each one's close box
    /// would: the program hears each CLOSE, and a window's `run` returns.
    func closeAllWindows() {
        for id in openWindows.sorted() {
            windows[id]?.close()
        }
    }

    /// The window made for `id`, with what the program adds going into
    /// `root`. Called by ``create(id:kind:arguments:)``.
    func register(window: AUIWindow, root: AUIStack, id: Int) {
        window.onClose = { [weak self] in self?.windowClosed(id) }
        windows[id] = window
        windowRoots[id] = root
    }

    /// A window went away, by the user or the program: tell the program.
    private func windowClosed(_ id: Int) {
        guard openWindows.remove(id) != nil else { return }
        automation.trace("window \(id) closed")
        post("CLOSE", id, "", -1, -1)
    }

    /// Queues what the user did for the program: `column` is a table cell's,
    /// with `index` its row; -1 for everything else.
    func post(_ kind: String, _ source: Int, _ text: String, _ index: Int, _ column: Int) {
        BASICCompiledAUI.post(kind: kind, source: source, text: text, index: index, column: column)
    }

    /// The error for a request naming a control it does not apply to.
    func missing(_ id: Int) -> BASICError {
        BASICError.runtime("ActiveUI control \(id) is not one this request applies to")
    }
}
