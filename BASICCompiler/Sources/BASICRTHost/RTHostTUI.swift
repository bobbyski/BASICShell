import BASICRT
import Foundation
import TUIKit

// BASICRTHost — TUIKit, for a compiled program.
//
// The interpreter's binding (BASICCore's BASICTUIKit.swift) turns a TUI
// pseudo class into a handle and dispatches methods on it against a registry
// of real TUIKit objects. This is that binding for a compiled program: the
// same handles, the same method names, the same rules about which control
// answers which word — written against the runtime's own values rather than
// the interpreter's, and calling BASIC handlers by name through the
// program's own handler table.
//
// A compiled program runs on the main thread, which is where TUIKit's
// @MainActor work belongs, so the registry is reached with
// `MainActor.assumeIsolated` rather than a pump.

/// The BASIC handler a control calls: the compiler emits one trampoline per
/// function and registers it by name.
typealias RTHandlerTrampoline = @convention(c) (UnsafeMutableRawPointer?) -> Void

@MainActor
final class RTTUIRegistry {
    static let shared = RTTUIRegistry()
    private init() {}

    var views: [Int: TUIView] = [:]
    var windows: [Int: Window] = [:]
    var apps: [Int: App] = [:]
    var menus: [Int: MenuBar] = [:]
    var openMenus: [Int: Menu] = [:]
    var dialogs: [Int: DialogSpec] = [:]
    /// What each handle is, so an error can name it.
    var kinds: [Int: String] = [:]
    /// The BASIC function each control calls, by handle.
    var handlers: [Int: String] = [:]
    /// Windows that have a menu bar, and so have one row less to give.
    var windowsWithMenuBars: Set<Int> = []
    /// The first control that can take focus. A window opens with nothing
    /// focused otherwise, and the program looks hung.
    var pendingFirstResponder: TUIView?

    private var nextID = 1

    func allocate(kind: String) -> Int {
        let id = nextID
        nextID += 1
        kinds[id] = kind
        return id
    }

    /// Everything a finished application leaves behind.
    func releaseAll() {
        pendingFirstResponder = nil
        windowsWithMenuBars.removeAll()
        openMenus.removeAll()
        dialogs.removeAll()
        menus.removeAll()
        apps.removeAll()
        windows.removeAll()
        views.removeAll()
        handlers.removeAll()
    }

    /// What a dialog will be when it is shown. TUIKit takes a dialog's
    /// message at construction and offers no setter, so the real object
    /// cannot exist until the program has finished describing it.
    struct DialogSpec {
        var title: String
        var message = ""
        var buttons: [(title: String, handler: String?)] = []
    }
}

/// The program's named handlers, and the errors they raise.
enum RTTUIHandlers {
    nonisolated(unsafe) static var trampolines: [String: RTHandlerTrampoline] = [:]
    /// A handler cannot throw through TUIKit — it is called mid-frame from a
    /// non-throwing closure — so a failure is parked here and reported by
    /// `run`, the statement the program is sitting on.
    nonisolated(unsafe) static var failure: String?

    static func call(_ name: String) {
        guard let trampoline = trampolines[name.uppercased()] else { return }
        trampoline(nil)
    }
}

@_cdecl("basic_rt_host_handler_register")
public func basic_rt_host_handler_register(_ name: UnsafePointer<CChar>, _ handler: UnsafeMutableRawPointer) {
    RTTUIHandlers.trampolines[String(cString: name).uppercased()] = unsafeBitCast(handler, to: RTHandlerTrampoline.self)
}

// MARK: - Construction

@MainActor
private func makeTUIObject(_ typeName: String, _ arguments: [RTValue]) -> Int {
    let registry = RTTUIRegistry.shared
    let title = arguments.first?.string?.description ?? ""
    let id = registry.allocate(kind: typeName)
    switch typeName.uppercased() {
    case "TUIAPP":
        // No `App` yet: TUIKit takes its driver at construction, and the
        // driver is the host's answer at `run` time.
        break
    case "TUIWINDOW":
        let window = Window()
        window.fillsScreen = true
        registry.windows[id] = window
    case "TUISTACK":
        // "h" or "v", defaulting to vertical — the shape a form takes.
        registry.views[id] = title.lowercased().hasPrefix("h") ? HStack(spacing: 1) : VStack(spacing: 0)
    case "TUILABEL":
        registry.views[id] = Label(title)
    case "TUIFIELD":
        registry.views[id] = TextField(placeholder: title)
    case "TUILIST":
        registry.views[id] = ListView()
    case "TUITABLE":
        registry.views[id] = TableView(columns: [])
    case "TUICHECK":
        registry.views[id] = Checkbox(title)
    case "TUIGAUGE":
        registry.views[id] = Gauge(value: arguments.first?.number ?? 0, in: 0...100)
    case "TUIBUTTON":
        registry.views[id] = Button(title)
    case "TUIMENU":
        registry.menus[id] = MenuBar()
    case "TUIDIALOG":
        registry.dialogs[id] = RTTUIRegistry.DialogSpec(title: title)
    default:
        basic_rt_fail("\(typeName) is not supported by basicc yet")
    }
    return id
}

@_cdecl("basic_rt_host_tui_new")
public func basic_rt_host_tui_new(_ typeName: UnsafePointer<CChar>, _ count: Int, _ arguments: UnsafePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer {
    let name = String(cString: typeName)
    let box = RTTUICallBox()
    box.arguments = (0..<count).map { rtValue(arguments[$0]) }
    MainActor.assumeIsolated { box.id = makeTUIObject(name, box.arguments) }
    return rtOwned(RTValue.number(Double(box.id)))
}

// MARK: - Methods

@MainActor
private func callTUIMethod(_ typeName: String, _ id: Int, _ method: String, _ arguments: [RTValue]) -> RTValue {
    let registry = RTTUIRegistry.shared
    let name = method.uppercased()
    let subject = registry.views[id]
    func text(_ index: Int) -> String? {
        guard arguments.indices.contains(index) else { return nil }
        return arguments[index].string?.description ?? RTTUIText.plain(arguments[index])
    }
    func view() -> TUIView {
        guard let subject else { basic_rt_fail("\(typeName) is not a view") }
        return subject
    }
    func focusIfFirst(_ candidate: TUIView) {
        if registry.pendingFirstResponder == nil { registry.pendingFirstResponder = candidate }
    }

    switch name {
    case "RUN":
        guard case .system(let object)? = arguments.first, let handle = object.payload as? RTTUIHandle else {
            basic_rt_fail("\(typeName).run expects a window")
        }
        runTUIApplication(appID: id, windowID: handle.id)
        return .empty

    case "ADD":
        guard case .system(let object)? = arguments.first, let child = object.payload as? RTTUIHandle else {
            basic_rt_fail("\(typeName).add expects a TUI view")
        }
        // A menu bar is attached, not stacked: it anchors itself across the
        // top of the window rather than taking a place in a column.
        if let window = registry.windows[id], let bar = registry.menus[child.id] {
            bar.anchors = AnchorSet(leading: 0, trailing: 0, top: 0, height: 1)
            window.addSubview(bar)
            registry.windowsWithMenuBars.insert(id)
            for existing in window.subviews where existing !== bar {
                existing.anchors = AnchorSet(leading: 0, trailing: 0, top: 1, bottom: 0)
            }
            return .empty
        }
        guard let childView = registry.views[child.id] else {
            basic_rt_fail("\(typeName).add expects a TUI view")
        }
        if let window = registry.windows[id] {
            // Fill the window unless the program said otherwise; one row down
            // when there is a menu bar, which owns the top.
            let top = registry.windowsWithMenuBars.contains(id) ? 1 : 0
            childView.anchors = AnchorSet(leading: 0, trailing: 0, top: top, bottom: 0)
            window.addSubview(childView)
        } else {
            let parent = view()
            // A stack lays its children out along its axis, but only once
            // they have a height to be laid out with.
            if parent is StackView, childView.frame.size.height == 0 {
                childView.frame = Rect(x: 0, y: 0, width: 1, height: 1)
            }
            parent.addSubview(childView)
        }
        return .empty

    case "TITLE", "TEXT":
        guard let value = text(0) else { basic_rt_fail("\(typeName).\(method) expects a string") }
        if let label = subject as? Label { label.text = value }
        else if let button = subject as? Button { button.title = value }
        else if let field = subject as? TextField { field.setText(value) }
        return .empty

    case "COLUMN":
        guard let table = subject as? TableView else { basic_rt_fail("\(typeName) has no columns") }
        guard let heading = text(0) else { basic_rt_fail("\(typeName).column expects a title") }
        if let width = arguments.count > 1 ? arguments[1].number.map({ Int($0) }) : nil, width > 0 {
            table.columns.append(TableColumn(heading, width: .fixed(width)))
        } else {
            table.columns.append(TableColumn(heading))
        }
        return .empty

    case "ADDROW":
        guard let table = subject as? TableView else { basic_rt_fail("\(typeName) has no rows") }
        // Short rows are padded rather than refused: a table gaining a column
        // should not turn every existing addrow into an error.
        var row = arguments.map { $0.string?.description ?? RTTUIText.plain($0) }
        while row.count < table.columns.count { row.append("") }
        table.rows.append(row)
        return .empty

    case "MENU":
        guard let bar = registry.menus[id] else { basic_rt_fail("\(typeName) is not a menu bar") }
        guard let heading = text(0) else { basic_rt_fail("\(typeName).menu expects a title") }
        let menu = Menu(heading)
        bar.addMenu(menu)
        // Items go into the menu most recently opened, so a program reads top
        // to bottom: menu "File", item, item, menu "Edit".
        registry.openMenus[id] = menu
        return .empty

    case "ITEM":
        guard let menu = registry.openMenus[id] else { basic_rt_fail("\(typeName).item needs a menu — call menu first") }
        guard let label = text(0) else { basic_rt_fail("\(typeName).item expects a title") }
        let handler = text(1)
        _ = menu.addItem(label) {
            guard let handler else { return }
            RTTUIHandlers.call(handler)
        }
        return .empty

    case "SEPARATOR":
        guard let menu = registry.openMenus[id] else { basic_rt_fail("\(typeName).separator needs a menu") }
        menu.addSeparator()
        return .empty

    case "MESSAGE":
        guard registry.dialogs[id] != nil else { basic_rt_fail("\(typeName) is not a dialog") }
        guard let body = text(0) else { basic_rt_fail("\(typeName).message expects text") }
        registry.dialogs[id]?.message = body
        return .empty

    case "ADDBUTTON":
        guard registry.dialogs[id] != nil else { basic_rt_fail("\(typeName) is not a dialog") }
        guard let label = text(0) else { basic_rt_fail("\(typeName).addbutton expects a title") }
        registry.dialogs[id]?.buttons.append((title: label, handler: text(1)))
        return .empty

    case "ADDITEM":
        guard let list = subject as? ListView else { basic_rt_fail("\(typeName).additem expects a list") }
        guard let value = text(0) else { basic_rt_fail("\(typeName).additem expects a string") }
        list.items.append(value)
        return .empty

    case "CHECKED":
        guard let box = subject as? Checkbox else { basic_rt_fail("\(typeName) has nothing to check") }
        // With an argument it sets; without one it reads.
        if let wanted = arguments.first {
            box.setChecked(wanted.truthy)
            return .empty
        }
        return .boolean(box.isChecked)

    case "ONTOGGLE":
        guard let box = subject as? Checkbox else { basic_rt_fail("\(typeName) has nothing to toggle") }
        guard let handler = text(0) else { basic_rt_fail("\(typeName).ontoggle expects a handler name") }
        registry.handlers[id] = handler
        focusIfFirst(box)
        box.onChange = { _ in RTTUIDispatch.invoke(handlerFor: id) }
        return .empty

    case "ONSELECT":
        guard let handler = text(0) else { basic_rt_fail("\(typeName).onselect expects a handler name") }
        registry.handlers[id] = handler
        if let table = subject as? TableView {
            focusIfFirst(table)
            table.onSelectionChanged = { _ in RTTUIDispatch.invoke(handlerFor: id) }
            return .empty
        }
        guard let list = subject as? ListView else { basic_rt_fail("\(typeName) has no selection") }
        focusIfFirst(list)
        list.onSelectionChanged = { _ in RTTUIDispatch.invoke(handlerFor: id) }
        return .empty

    case "ONCLICK":
        guard let handler = text(0) else { basic_rt_fail("\(typeName).onclick expects a handler name") }
        guard let button = subject as? Button else { basic_rt_fail("\(typeName) has no click to handle") }
        registry.handlers[id] = handler
        focusIfFirst(button)
        // Installed once and reading the registry each time, so `onclick` may
        // be called again without leaving the old handler wired underneath.
        button.onActivate = { RTTUIDispatch.invoke(handlerFor: id) }
        return .empty

    case "SELECTED":
        if let table = subject as? TableView { return .number(Double(table.selectedIndex ?? -1)) }
        guard let list = subject as? ListView else { basic_rt_fail("\(typeName) has no selection") }
        // -1 rather than an error when nothing is selected: asking "which
        // row?" before the user has touched anything is the ordinary case.
        return .number(Double(list.selectedIndex ?? -1))

    case "SELECTEDTEXT$", "SELECTEDTEXT":
        guard let list = subject as? ListView else { basic_rt_fail("\(typeName) is not a list") }
        guard let index = list.selectedIndex, list.items.indices.contains(index) else { return .string(RTText("")) }
        return .string(RTText(list.items[index]))

    case "VALUE$", "VALUE":
        // A label reads too: "what does it say now?" is the obvious question
        // after a handler has been changing it.
        if let label = subject as? Label {
            if let wanted = text(0) { label.text = wanted; return .empty }
            return .string(RTText(label.text))
        }
        if let button = subject as? Button { return .string(RTText(button.title)) }
        if let box = subject as? Checkbox { return .boolean(box.isChecked) }
        if let gauge = subject as? Gauge {
            if let wanted = arguments.first?.number { gauge.setValue(wanted); return .empty }
            return .number(gauge.value)
        }
        guard let field = subject as? TextField else { basic_rt_fail("\(typeName) has no value to read") }
        return .string(RTText(field.text))

    case "SHOW":
        guard let app = registry.apps[id] else { basic_rt_fail("\(typeName) is not an application") }
        guard case .system(let object)? = arguments.first, let handle = object.payload as? RTTUIHandle,
              let spec = registry.dialogs[handle.id] else {
            basic_rt_fail("\(typeName).show expects a dialog")
        }
        let dialog = Dialog(title: spec.title, message: spec.message)
        for (index, button) in spec.buttons.enumerated() {
            // The first button added is the default, and so the one with
            // focus: without one, Enter does nothing and the dialog looks
            // frozen.
            _ = dialog.addButton(button.title, isDefault: index == 0) {
                guard let handler = button.handler else { return }
                RTTUIHandlers.call(handler)
            }
        }
        dialog.onDismiss = { [weak app, weak dialog] in
            if let app, let dialog { app.dismiss(dialog) }
        }
        // Sized twice, as TUIKit's own document controller does: once before
        // it is placed, once after, when it has a frame to measure against.
        dialog.sizeToFit(in: app.desktop.bounds.size)
        app.present(dialog)
        dialog.sizeToFit(in: app.desktop.bounds.size)
        return .empty

    case "STOP":
        guard let app = registry.apps[id] else { basic_rt_fail("\(typeName) is not an application") }
        app.stop()
        return .empty

    default:
        basic_rt_fail("\(typeName) has no method \(method)")
    }
}

@_cdecl("basic_rt_host_tui_call")
public func basic_rt_host_tui_call(_ typeName: UnsafePointer<CChar>, _ id: Int, _ method: UnsafePointer<CChar>, _ count: Int, _ arguments: UnsafePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer {
    let type = String(cString: typeName)
    let name = String(cString: method)
    let values = (0..<count).map { rtValue(arguments[$0]) }
    // The values do not cross a thread here — a compiled program's main
    // thread is the main actor's executor — so the box carries them past the
    // Sendable check that `assumeIsolated` applies to its result.
    let box = RTTUICallBox()
    box.arguments = values
    MainActor.assumeIsolated { box.result = callTUIMethod(type, id, name, box.arguments) }
    return rtOwned(box.result)
}

/// Calling a control's handler from inside a frame.
enum RTTUIDispatch {
    @MainActor
    static func invoke(handlerFor id: Int) {
        guard let handler = RTTUIRegistry.shared.handlers[id] else { return }
        RTTUIHandlers.call(handler)
    }
}

/// What a value looks like when a control needs text for it.
enum RTTUIText {
    static func plain(_ value: RTValue) -> String {
        value.description
    }
}

// MARK: - Running

/// Runs the application, blocking until it stops.
///
/// TUIKit's `App` is `@MainActor` and `async`, and a compiled program's main
/// thread *is* the main actor's executor — so waiting on a semaphore would
/// deadlock. The main thread pumps its run loop instead, which is where the
/// main actor's work is enqueued.
@MainActor
private func runTUIApplication(appID: Int, windowID: Int) {
    let registry = RTTUIRegistry.shared
    guard let window = registry.windows[windowID] else {
        basic_rt_fail("TUIApp.run expects an application and a window")
    }
    // TUIKit's driver sets O_NONBLOCK on standard input when it starts and
    // does not clear it, which would make every later read look like end of
    // input. Saved and restored around the application.
    let savedFlags = fcntl(STDIN_FILENO, F_GETFL)
    defer { if savedFlags >= 0 { _ = fcntl(STDIN_FILENO, F_SETFL, savedFlags) } }

    let box = RTTUIRunBox()
    let app = App(driver: ANSIDriver())
    // ^C is a control's copy key in TUIKit, and an app that quit on it would
    // lose a program's window to a mistimed keystroke.
    app.stopsOnControlC = false
    registry.apps[appID] = app
    if let first = registry.pendingFirstResponder {
        _ = window.makeFirstResponder(first)
    }

    Task { @MainActor in
        do {
            try await app.run(window)
        } catch {
            box.error = "\(error)"
        }
        box.isFinished = true
    }
    while !box.isFinished {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }

    // Released when the app stops rather than left to accumulate: a program
    // that shows a dialog in a loop would otherwise retain every window.
    registry.releaseAll()
    if let failure = RTTUIHandlers.failure {
        RTTUIHandlers.failure = nil
        basic_rt_fail(failure)
    }
    if let error = box.error {
        basic_rt_fail("TUI application failed: \(error)")
    }
}

/// Carries a call's values into the main-actor hop and its result out.
///
/// Nothing crosses a thread here — a compiled program's main thread is the
/// main actor's executor — so the box stands in for a `Sendable` conformance
/// the runtime's values do not need.
private final class RTTUICallBox: @unchecked Sendable {
    var arguments: [RTValue] = []
    var result: RTValue = .empty
    var id = 0
}

private final class RTTUIRunBox: @unchecked Sendable {
    var isFinished = false
    var error: String?
}
