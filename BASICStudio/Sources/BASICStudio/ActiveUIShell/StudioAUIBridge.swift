//
//  StudioAUIBridge.swift
//  BASICStudio
//
//  A BASIC program's own windows: BASICCore's AUI requests, made real.
//

import ActiveUI
import AppKit
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
    /// Where the user's actions go: `BASICSession.postAUIEvent`.
    var postEvent: ((_ kind: String, _ source: Int, _ text: String, _ index: Int) -> Void)?
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

    private struct Dialog {
        var title: String
        var message: String
        var buttons: [String] = []
    }

    /// A list's or table's rows, read by its table's closures.
    @MainActor
    final class RowStore {
        var rows: [[String]] = []
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
            container.addChild(childView)
            container.invalidateLayout()
        case .setText(let id, let text):
            if let window = windows[id] {
                window.title = text
            } else if let label = views[id] as? AUILabel {
                label.text = text
            } else if let button = views[id] as? AUIButton {
                button.title = text
            } else if let field = views[id] as? AUITextField {
                field.text = text
            } else {
                throw missing(id)
            }
        case .text(let id):
            if let label = views[id] as? AUILabel { return .text(label.text) }
            if let field = views[id] as? AUITextField { return .text(field.text) }
            throw missing(id)
        case .addItem(let id, let cells):
            guard let store = rows[id], let table = views[id] as? AUITable else { throw missing(id) }
            store.rows.append(cells)
            table.reloadData()
        case .clearItems(let id):
            guard let store = rows[id], let table = views[id] as? AUITable else { throw missing(id) }
            store.rows.removeAll()
            table.reloadData()
        case .itemCount(let id):
            guard let store = rows[id] else { throw missing(id) }
            return .number(Double(store.rows.count))
        case .selectedIndex(let id):
            guard let table = views[id] as? AUITable else { throw missing(id) }
            return .number(Double(table.selectedRows.first ?? -1))
        case .selectedText(let id):
            guard let table = views[id] as? AUITable, let store = rows[id] else { throw missing(id) }
            guard let row = table.selectedRows.first, store.rows.indices.contains(row) else { return .text("") }
            return .text(store.rows[row].first ?? "")
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
                self?.postEvent?("CLICK", id, button?.title ?? "", -1)
            }
            views[id] = button
        case .field:
            let field = AUITextField(first, placeholder: arguments.count > 1 ? arguments[1] : nil)
            field.onSubmit = { [weak self] text in self?.postEvent?("SUBMIT", id, text, -1) }
            field.onChange = { [weak self] text in self?.postEvent?("CHANGE", id, text, -1) }
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
                AUITableColumn(title) { row in
                    let cells = store.rows[row]
                    return AUILabel(cells.indices.contains(column) ? cells[column] : "")
                }
            }
            let table = AUITable(columns: columns, rowCount: { store.rows.count })
            watchSelection(of: table, id: id, store: store)
            rows[id] = store
            views[id] = table
        case .dialog:
            dialogs[id] = Dialog(title: first, message: arguments.count > 1 ? arguments[1] : "")
        }
        if let table = views[id] as? AUITable {
            table.minimumSize = CGSize(width: 200, height: 120)
            table.flexibility = .both()
        }
    }

    /// A window went away, by the user or the program: tell the program.
    /// Not for a window closeAll put away; the program is gone by then.
    private func windowClosed(_ id: Int) {
        guard openWindows.remove(id) != nil else { return }
        postEvent?("CLOSE", id, "", -1)
    }

    private func watchSelection(of table: AUITable, id: Int, store: RowStore) {
        table.onSelectionChange = { [weak self] selected in
            guard let row = selected.first, store.rows.indices.contains(row) else { return }
            self?.postEvent?("SELECT", id, store.rows[row].first ?? "", row)
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
