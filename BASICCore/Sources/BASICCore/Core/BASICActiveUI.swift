//
//  BASICActiveUI.swift
//  BASICCore
//
//  ActiveUI for BASIC programs: AUIWindow and friends, as pseudo classes.
//

import BASICSyntax
import Foundation

/// The ActiveUI pseudo classes (ACTIVEUI_TRANSITION.md P6). Raw values are
/// ``BASICKeywords/activeUIClasses``, spelled as a program writes them.
public enum BASICAUIKind: String, CaseIterable, Sendable {
    case window = "AUIWindow"
    case stack = "AUIStack"
    case label = "AUILabel"
    case button = "AUIButton"
    case field = "AUIField"
    case list = "AUIList"
    case table = "AUITable"
    case dialog = "AUIDialog"
    case tabs = "AUITabs"
    case picker = "AUIPicker"
    case date = "AUIDate"
    case pieChart = "AUIPieChart"

    /// The kind a program's name refers to, in any case.
    public init?(named name: String) {
        guard let kind = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame }) else {
            return nil
        }
        self = kind
    }

    /// Whether this kind sits inside a window, rather than being one.
    var isControl: Bool {
        self != .window && self != .dialog
    }
}

/// How a table's column shows its cells.
public enum BASICAUIColumnStyle: Equatable, Sendable {
    /// Text the program sets; the user only reads it.
    case text
    /// A field in every row that the user types into.
    case editable
    /// One of a few, picked in every row: present, absent or tardy.
    case choices([String])
}

/// One thing a program asks of the windows, as a value.
///
/// Typed rather than a method name and a list of arguments: the interpreter
/// checks a call's name and arguments once, here, and the host implements a
/// short closed list. A recording host is how the conformance tests drive
/// every pseudo class without a window.
public enum BASICAUIRequest: Equatable, Sendable {
    /// Makes control `id`. `arguments` are the constructor's, as strings:
    /// a window's title, a stack's axis, a table's column titles.
    case create(id: Int, kind: BASICAUIKind, arguments: [String])
    /// Puts `child` at the end of window or stack `parent`.
    case add(parent: Int, child: Int)
    /// A window's title, a label's text, a button's title, a field's text.
    case setText(id: Int, text: String)
    /// Answers a string: a label's or field's text.
    case text(id: Int)
    /// A list's item (one cell), a table's row, or a picker's option.
    case addItem(id: Int, cells: [String])
    case clearItems(id: Int)
    /// Answers a number.
    case itemCount(id: Int)
    /// Answers a number, -1 when nothing is selected.
    case selectedIndex(id: Int)
    /// Answers a string, "" when nothing is selected.
    case selectedText(id: Int)
    case setEnabled(id: Int, enabled: Bool)
    /// A dialog's button, in order.
    case addButton(id: Int, title: String)
    /// Puts a window up and returns at once. For a dialog, waits for a
    /// button and answers its index as a number.
    case show(id: Int)
    case close(id: Int)
    /// Answers a boolean: whether a window is still up.
    case isOpen(id: Int)
    /// Puts `child` in tabs `id` as a page of its own, under `title`.
    case addTab(id: Int, title: String, child: Int)
    /// Shows a tab, picks a picker's option, or selects a list's or table's
    /// row. -1 selects nothing.
    case select(id: Int, index: Int)
    /// How table `id` shows column `column` (counted from 0).
    case setColumnStyle(id: Int, column: Int, style: BASICAUIColumnStyle)
    /// Answers a string: one cell of a table.
    case cell(id: Int, row: Int, column: Int)
    case setCell(id: Int, row: Int, column: Int, text: String)
    /// A slice of a pie chart: what it counts, and how many.
    case addSlice(id: Int, label: String, value: Double)
    /// A window's size, in points.
    case setSize(id: Int, width: Double, height: Double)
}

/// What a host answers a request with. Most requests answer ``none``.
public enum BASICAUIAnswer: Equatable, Sendable {
    case none
    case number(Double)
    case text(String)
    case flag(Bool)
}

/// A host that can put up ActiveUI windows for a program: BASICStudio.
///
/// One method, because the requests are the vocabulary. Called on the
/// interpreter's thread; a host whose windows live on the main thread hops
/// there itself. What the user does comes back through
/// ``BASICSession/postAUIEvent(kind:source:text:index:)``.
public protocol BASICAUIHost: BASICHost {
    /// Carries out `request`, answering ``BASICAUIAnswer/none`` unless the
    /// request says it answers something.
    func auiPerform(_ request: BASICAUIRequest) throws -> BASICAUIAnswer
}

extension BASICRuntime {
    /// The kinds of event a control reports, as `ON AUI <kind> CALL` and the
    /// per-control `on<kind>` methods name them.
    static let auiEventKinds: Set<String> = ["CLICK", "SELECT", "SUBMIT", "CHANGE", "CLOSE"]

    /// Makes an ActiveUI control, or explains why this host cannot.
    func auiObject(kind: BASICAUIKind, arguments: [BASICValue], host: BASICAUIHost?) throws -> BASICValue {
        guard let host else {
            throw BASICError.runtime("\(kind.rawValue) needs a host that can open windows; run the program in BASICStudio")
        }
        let strings = try arguments.map(auiString)
        switch kind {
        case .window, .button:
            guard strings.count <= 1 else { throw BASICError.runtime("\(kind.rawValue) expects a title") }
        case .label:
            guard strings.count <= 1 else { throw BASICError.runtime("AUILabel expects its text") }
        case .field:
            guard strings.count <= 2 else { throw BASICError.runtime("AUIField expects text and a placeholder") }
        case .stack:
            guard strings.count <= 1 else { throw BASICError.runtime("AUIStack expects an axis") }
            if let axis = strings.first, !["VERTICAL", "HORIZONTAL"].contains(axis.uppercased()) {
                throw BASICError.runtime("AUIStack's axis is \"vertical\" or \"horizontal\", not \"\(axis)\"")
            }
        case .list:
            guard strings.isEmpty else { throw BASICError.runtime("AUIList takes no arguments") }
        case .table:
            guard !strings.isEmpty else { throw BASICError.runtime("AUITable expects its column titles") }
        case .dialog:
            guard (1...2).contains(strings.count) else { throw BASICError.runtime("AUIDialog expects a title and a message") }
        case .tabs:
            guard strings.isEmpty else { throw BASICError.runtime("AUITabs takes no arguments; add each page with addtab") }
        case .picker:
            break
        case .date:
            guard strings.count <= 1 else { throw BASICError.runtime("AUIDate expects a date, as \"YYYY-MM-DD\"") }
            if let first = strings.first, !first.isEmpty { try Self.checkDate(first) }
        case .pieChart:
            guard strings.count <= 1 else { throw BASICError.runtime("AUIPieChart expects a title") }
        }
        let id = nextAUIObjectID
        nextAUIObjectID += 1
        _ = try perform(host, .create(id: id, kind: kind, arguments: strings))
        auiObjects[id] = kind
        if kind == .table { auiTableColumns[id] = strings }
        return .systemObject(kind.rawValue, id)
    }

    /// Calls `method` on control `id`.
    ///
    /// `pump` is how `run` waits: the interpreter's break check and event
    /// drain, so handlers run and Stop works while a window is up.
    func callAUIMethod(
        typeName: String,
        id: Int,
        method: String,
        arguments: [BASICValue],
        host: BASICAUIHost?,
        pump: () throws -> Void
    ) throws -> BASICValue {
        guard let kind = auiObjects[id] ?? BASICAUIKind(named: typeName) else {
            throw BASICError.runtime("\(typeName) has no method \(method)")
        }
        guard let host else {
            throw BASICError.runtime("\(kind.rawValue) needs a host that can open windows; run the program in BASICStudio")
        }
        guard auiObjects[id] != nil else {
            throw BASICError.runtime("\(kind.rawValue) was never made; construct it with \(kind.rawValue)(...)")
        }
        let name = method.uppercased()
        func expect(_ count: Int) throws {
            guard arguments.count == count else {
                throw BASICError.runtime("\(kind.rawValue).\(method) expects \(count) argument\(count == 1 ? "" : "s")")
            }
        }
        func string(_ index: Int) throws -> String { try auiString(arguments[index]) }
        func whole(_ index: Int, _ what: String) throws -> Int {
            guard let number = arguments[index].number, number == number.rounded(), abs(number) < 1e9 else {
                throw BASICError.runtime("\(kind.rawValue).\(method) expects \(what) as a whole number")
            }
            return Int(number)
        }
        /// A table's column, by its title or by its number from 0.
        func column(_ index: Int) throws -> Int {
            let titles = auiTableColumns[id] ?? []
            if case .string(let title) = arguments[index] {
                let wanted = title.description
                guard let found = titles.firstIndex(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                    throw BASICError.runtime("AUITable has no column \"\(wanted)\"; its columns are \(titles.map { "\"\($0)\"" }.joined(separator: ", "))")
                }
                return found
            }
            let number = try whole(index, "a column")
            guard titles.indices.contains(number) else {
                throw BASICError.runtime("AUITable has columns 0 to \(titles.count - 1), not \(number)")
            }
            return number
        }

        // Every control answers these.
        switch name {
        case "ID":
            try expect(0)
            return .number(Double(id))
        case "ENABLED" where kind.isControl:
            try expect(1)
            guard case .boolean(let flag) = arguments[0] else {
                throw BASICError.runtime("\(kind.rawValue).enabled expects TRUE or FALSE")
            }
            return try perform(host, .setEnabled(id: id, enabled: flag))
        default:
            break
        }
        if name.hasPrefix("ON"), Self.auiEventKinds.contains(String(name.dropFirst(2))) {
            let eventKind = String(name.dropFirst(2))
            guard Self.auiEvents(for: kind).contains(eventKind) else {
                throw BASICError.runtime("\(kind.rawValue) has no \(eventKind.lowercased()) to handle")
            }
            try expect(1)
            auiHandlers[Self.auiHandlerKey(id: id, kind: eventKind)] = try string(0)
            return .empty
        }

        switch (kind, name) {
        case (.window, "ADD"), (.stack, "ADD"):
            try expect(1)
            let childID = try control(arguments[0], for: "\(kind.rawValue).add")
            guard childID != id else { throw BASICError.runtime("\(kind.rawValue) cannot contain itself") }
            return try perform(host, .add(parent: id, child: childID))
        case (.tabs, "ADDTAB"):
            try expect(2)
            let childID = try control(arguments[1], for: "AUITabs.addtab")
            guard childID != id else { throw BASICError.runtime("AUITabs cannot contain itself") }
            return try perform(host, .addTab(id: id, title: try string(0), child: childID))
        case (.window, "TITLE"), (.button, "TITLE"), (.label, "TEXT"), (.field, "TEXT"):
            try expect(1)
            return try perform(host, .setText(id: id, text: try string(0)))
        case (.date, "TEXT"):
            try expect(1)
            let date = try string(0)
            try Self.checkDate(date)
            return try perform(host, .setText(id: id, text: date))
        case (.label, "TEXT$"), (.field, "TEXT$"), (.date, "TEXT$"):
            try expect(0)
            return try perform(host, .text(id: id))
        case (.window, "SIZE"):
            try expect(2)
            guard let width = arguments[0].number, let height = arguments[1].number, width > 0, height > 0 else {
                throw BASICError.runtime("AUIWindow.size expects a width and a height, in points")
            }
            return try perform(host, .setSize(id: id, width: width, height: height))
        case (.list, "ADD"), (.list, "ADDITEM"), (.picker, "ADD"):
            try expect(1)
            return try perform(host, .addItem(id: id, cells: [try string(0)]))
        case (.table, "ADDROW"):
            guard !arguments.isEmpty else { throw BASICError.runtime("AUITable.addrow expects a cell for each column") }
            return try perform(host, .addItem(id: id, cells: try arguments.map(auiString)))
        case (.pieChart, "ADDSLICE"):
            try expect(2)
            guard let value = arguments[1].number, value >= 0 else {
                throw BASICError.runtime("AUIPieChart.addslice expects a label and a number that is 0 or more")
            }
            return try perform(host, .addSlice(id: id, label: try string(0), value: value))
        case (.list, "CLEAR"), (.table, "CLEAR"), (.picker, "CLEAR"), (.pieChart, "CLEAR"):
            try expect(0)
            return try perform(host, .clearItems(id: id))
        case (.list, "COUNT"), (.table, "COUNT"), (.picker, "COUNT"), (.pieChart, "COUNT"), (.tabs, "COUNT"):
            try expect(0)
            return try perform(host, .itemCount(id: id))
        case (.list, "SELECTEDINDEX"), (.table, "SELECTEDINDEX"), (.picker, "SELECTEDINDEX"), (.tabs, "SELECTEDINDEX"):
            try expect(0)
            return try perform(host, .selectedIndex(id: id))
        case (.list, "SELECTEDTEXT$"), (.table, "SELECTEDTEXT$"), (.picker, "SELECTEDTEXT$"), (.tabs, "SELECTEDTEXT$"):
            try expect(0)
            return try perform(host, .selectedText(id: id))
        case (.list, "SELECT"), (.table, "SELECT"), (.picker, "SELECT"), (.tabs, "SELECT"):
            try expect(1)
            let index = try whole(0, "an index")
            guard index >= -1 else { throw BASICError.runtime("\(kind.rawValue).select expects an index from 0, or -1 for none") }
            return try perform(host, .select(id: id, index: index))
        case (.table, "EDITABLE"):
            try expect(1)
            return try perform(host, .setColumnStyle(id: id, column: try column(0), style: .editable))
        case (.table, "CHOICES"):
            guard arguments.count >= 3 else {
                throw BASICError.runtime("AUITable.choices expects a column and at least two choices")
            }
            let choices = try arguments.dropFirst().map(auiString)
            return try perform(host, .setColumnStyle(id: id, column: try column(0), style: .choices(choices)))
        case (.table, "PLAIN"):
            try expect(1)
            return try perform(host, .setColumnStyle(id: id, column: try column(0), style: .text))
        case (.table, "CELL$"):
            try expect(2)
            return try perform(host, .cell(id: id, row: try whole(0, "a row"), column: try column(1)))
        case (.table, "SETCELL"):
            try expect(3)
            return try perform(host, .setCell(id: id, row: try whole(0, "a row"), column: try column(1), text: try string(2)))
        case (.dialog, "ADDBUTTON"):
            try expect(1)
            return try perform(host, .addButton(id: id, title: try string(0)))
        case (.window, "SHOW"), (.dialog, "SHOW"):
            try expect(0)
            return try perform(host, .show(id: id))
        case (.window, "CLOSE"):
            try expect(0)
            return try perform(host, .close(id: id))
        case (.window, "RUN"):
            try expect(0)
            _ = try perform(host, .show(id: id))
            return try runAUIWindow(id: id, host: host, pump: pump)
        default:
            throw BASICError.runtime("\(kind.rawValue) has no method \(method)")
        }
    }

    /// Waits while window `id` is up, running the program's handlers as the
    /// user works it. Returns when the window closes.
    ///
    /// Handlers run between polls, on the program's own thread, which is the
    /// only thread they may run on. A Stop reaches the pump's break check.
    private func runAUIWindow(id: Int, host: BASICAUIHost, pump: () throws -> Void) throws -> BASICValue {
        while true {
            try pump()
            guard case .boolean(true) = try perform(host, .isOpen(id: id)) else { break }
            BASICAUIRunLoop.passed()
            Thread.sleep(forTimeInterval: 0.01)
        }
        // A handler for the close itself, posted as the window went.
        try pump()
        return .empty
    }

    /// The per-control handler for `kind` from control `id`, if one is set.
    func auiHandler(id: Int, kind: String) -> String? {
        auiHandlers[Self.auiHandlerKey(id: id, kind: kind.uppercased())]
    }

    /// Carries out `request` on `host`, as a BASIC value.
    private func perform(_ host: BASICAUIHost, _ request: BASICAUIRequest) throws -> BASICValue {
        switch try host.auiPerform(request) {
        case .none: return .empty
        case .number(let number): return .number(number)
        case .text(let text): return .string(BASICString(text))
        case .flag(let flag): return .boolean(flag)
        }
    }

    /// Which events each kind of control reports. A table's CHANGE is a cell
    /// the user edited or picked; tabs, a picker and a date report CHANGE
    /// when the user picks.
    static func auiEvents(for kind: BASICAUIKind) -> Set<String> {
        switch kind {
        case .window: ["CLOSE"]
        case .button: ["CLICK"]
        case .field: ["SUBMIT", "CHANGE"]
        case .list: ["SELECT"]
        case .table: ["SELECT", "CHANGE"]
        case .tabs, .picker, .date: ["CHANGE"]
        case .stack, .label, .dialog, .pieChart: []
        }
    }

    /// The control `value` names, which must be one that sits inside a
    /// window or a tab.
    private func control(_ value: BASICValue, for call: String) throws -> Int {
        guard case .systemObject(_, let childID) = value,
              let childKind = auiObjects[childID], childKind.isControl else {
            throw BASICError.runtime("\(call) expects a control: an AUIStack, AUILabel, AUIButton, AUIField, AUIList, AUITable, AUITabs, AUIPicker, AUIDate or AUIPieChart")
        }
        return childID
    }

    /// A date as AUIDate takes and gives it: `YYYY-MM-DD`, which sorts as
    /// text and stores in a database as it reads.
    static func checkDate(_ text: String) throws {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day), year > 0 else {
            throw BASICError.runtime("A date is written \"YYYY-MM-DD\", as \"2026-10-07\", not \"\(text)\"")
        }
    }

    private static func auiHandlerKey(id: Int, kind: String) -> String {
        "\(id):\(kind)"
    }

    private func auiString(_ value: BASICValue) throws -> String {
        switch value {
        case .string(let text): return text.description
        case .number(let number):
            return number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .boolean(let flag): return flag ? "TRUE" : "FALSE"
        default: throw BASICError.runtime("ActiveUI controls take text, not \(value.debugTypeName)")
        }
    }
}

/// How many times a window's `run()` has gone round, waiting for the user.
/// Handlers run inside a pass, so once two more passes are counted after an
/// event is posted, it has been handled: what a test waits for before it
/// types into a page the program is still filling in.
public enum BASICAUIRunLoop {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    public static var passes: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    static func passed() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
