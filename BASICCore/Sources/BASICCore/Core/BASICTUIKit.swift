//
//  BASICTUIKit.swift
//  BASICCore
//
//  TUIKit presented to BASIC as pseudo classes — phases 2 and 3 of
//  TUIKIT_PLAN.md.
//
//      let app = TUIApp()
//      let win = TUIWindow("Save changes?")
//      let row = TUIStack("h")
//      let ok  = TUIButton("Save")
//      ok.onclick("Saved")
//      row.add(ok)
//      win.add(row)
//      app.run(win)
//
//      function Saved()
//          app.stop()
//      end function
//
//  The binding lives in BASICCore rather than in either host, so one BASIC
//  program runs in both (TUIKIT_PLAN.md §5). What stays host-specific is only
//  where the cells go — see ``BASICTUIPresentationHost``.
//

import Foundation
import TUIKit

// MARK: - The host seam

/// Supplies the surface a TUI application draws on.
///
/// The whole of what differs between hosts: BASICShell returns `ANSIDriver()`,
/// BASICStudio will return a driver over its console, and a headless host
/// returns TUIKit's `HeadlessDriver` — which is how this can be tested without
/// a terminal.
public protocol BASICTUIPresentationHost: BASICHost {
    /// The driver a TUI application should run on, or `nil` where there is no
    /// surface to draw to.
    ///
    /// Deliberately not `@MainActor`: constructing a driver needs no isolation,
    /// and requiring it made the host itself un-sendable at the one place the
    /// binding uses it.
    func makeTUIDriver() -> (any TerminalDriver)?
}

// MARK: - The registry

/// The live TUIKit objects, by handle.
///
/// `@MainActor` because every TUIKit view is, and a separate class rather than
/// fields on `BASICRuntime` for the same reason: the runtime is not main-actor
/// isolated and cannot hold them.
@MainActor
final class BASICTUIRegistry {
    static let shared = BASICTUIRegistry()
    private init() {}

    /// Views by handle. `TUIView` is a class, so these are the real objects.
    var views: [Int: TUIView] = [:]
    /// Applications by handle.
    var apps: [Int: App] = [:]
    /// Windows by handle.
    var windows: [Int: Window] = [:]
    /// Menu bars by handle. Not views a program adds to a stack — a bar is
    /// attached to a window and lays itself across the top.
    var menus: [Int: MenuBar] = [:]
    /// What each dialog will be, when it is shown.
    ///
    /// A description rather than a `Dialog`, because TUIKit takes a dialog's
    /// message at construction and offers no setter — so the real object cannot
    /// exist until the program has finished saying what it wants, which is at
    /// `show`. The same reason `TUIApp` holds no `App` until `run`.
    var dialogs: [Int: BASICTUIDialogSpec] = [:]
    /// The menu a `TUIMenu` is currently building items into.
    var openMenus: [Int: Menu] = [:]
    /// Windows that have a menu bar, and so have one row less to give.
    var windowsWithMenuBars: Set<Int> = []
    /// Windows that have a status strip, and so have one row less at the foot.
    var windowsWithStatusBars: Set<Int> = []
    /// Backing store for ``floatingWindows`` (see BASICTUIChrome.swift).
    var floatingWindowStorage: [Int: FloatingWindow] = [:]
    /// The handle most recently allocated, so a builder can reach it.
    var lastAllocatedID = 0
    /// A theme set before the app existed, applied when it does.
    ///
    /// A program configures its application before running it — that is the
    /// natural order to write — but `TUIApp` holds no `App` until `run`,
    /// because TUIKit takes the driver at construction. So everything said to
    /// the application early is remembered here and applied at `run`.
    var pendingTheme: Theme?
    /// Timers asked for before the app existed.
    var pendingTimers: [(seconds: Double, handler: String)] = []
    /// Windows to present once the app is up.
    var pendingPresents: [Int] = []
    /// The BASIC function each control calls, by handle.
    var handlers: [Int: String] = [:]
    /// The first control that can take focus, per window, in the order the
    /// program added them.
    ///
    /// A window opens with nothing focused otherwise, so the first keystroke
    /// goes nowhere and the program looks hung. Tab still moves focus after
    /// that; this only decides where it starts.
    var pendingFirstResponder: TUIView?
    /// What each handle is, for error messages that can name it.
    var kinds: [Int: String] = [:]

    private var nextID = 1

    func allocate(kind: String) -> Int {
        let id = nextID
        nextID += 1
        kinds[id] = kind
        lastAllocatedID = id
        return id
    }

    /// Everything a finished application leaves behind.
    ///
    /// Called when `run` returns rather than left to accumulate: a program that
    /// opens a dialog in a loop would otherwise retain every window it ever
    /// showed, and the handles are dead the moment the app stops.
    func releaseAll() {
        pendingFirstResponder = nil
        windowsWithMenuBars.removeAll()
        windowsWithStatusBars.removeAll()
        floatingWindowStorage.removeAll()
        pendingTheme = nil
        pendingTimers.removeAll()
        pendingPresents.removeAll()
        views.removeAll()
        menus.removeAll()
        dialogs.removeAll()
        openMenus.removeAll()
        apps.removeAll()
        windows.removeAll()
        handlers.removeAll()
        kinds.removeAll()
    }
}

/// What a `TUIDialog` will be when it is shown.
struct BASICTUIDialogSpec {
    var title: String
    var message: String = ""
    var buttons: [(title: String, handler: String?)] = []
}

/// Runs `body` on the main actor, from wherever the interpreter happens to be.
///
/// TUIKit is main-actor isolated. The interpreter is not isolated at all, and —
/// this is the part that matters — an ordinary `RUN` executes on a **worker
/// lane**, not the main thread. So neither `assumeIsolated` alone nor a plain
/// main-thread assumption is enough.
///
/// On the main thread `assumeIsolated` is correct and free. Off it, the work is
/// posted to the main actor and this thread blocks until it finishes — which is
/// safe precisely because the blocked thread is not the main one, and because
/// `runProgramSynchronously` leaves the main thread pumping its run loop rather
/// than parked in a semaphore.
func withTUIRegistry<Value: Sendable>(
    _ body: @escaping @MainActor @Sendable (BASICTUIRegistry) throws -> Value
) throws -> Value {
    if Thread.isMainThread {
        return try MainActor.assumeIsolated { try body(BASICTUIRegistry.shared) }
    }
    // The main thread is waiting for this worker and will not service the main
    // actor until it is told to. Asked for before posting, or the Task below
    // would never run.
    BASICMainActorPump.request()
    let box = BASICTUIResultBox<Value>()
    let finished = DispatchSemaphore(value: 0)
    Task { @MainActor in
        do {
            box.value = try body(BASICTUIRegistry.shared)
        } catch {
            box.error = error
        }
        finished.signal()
    }
    finished.wait()
    if let error = box.error { throw error }
    guard let value = box.value else {
        throw BASICError.runtime("A TUI operation finished without a result")
    }
    return value
}

/// Carries a result across the actor hop above.
final class BASICTUIResultBox<Value>: @unchecked Sendable {
    var value: Value?
    var error: Error?
}

// MARK: - Construction

extension BASICRuntime {

    /// Builds a TUI pseudo-class handle.
    func tuiObject(typeName: String, arguments: [BASICValue]) throws -> BASICValue {
        let title = arguments.first?.string?.description ?? ""
        let id = try withTUIRegistry { registry -> Int in
            let id = registry.allocate(kind: typeName)
            switch typeName.uppercased() {
            case "TUIAPP":
                // No `App` yet. TUIKit takes the driver at construction and has
                // no way to swap it later, and the driver comes from the host
                // at `run` time — so the handle is an empty seat until then.
                break

            case "TUIWINDOW":
                let window = Window()
                window.fillsScreen = true
                registry.windows[id] = window

            case "TUISTACK":
                // "h" or "v", defaulting to vertical: a column of controls is
                // the shape a form takes, and the one a program writing its
                // first window almost always means.
                let horizontal = title.lowercased().hasPrefix("h")
                registry.views[id] = horizontal
                    ? HStack(spacing: 1)
                    : VStack(spacing: 0)

            case "TUIBUTTON":
                registry.views[id] = Button(title)

            case "TUILABEL":
                registry.views[id] = Label(title)

            case "TUIFIELD":
                registry.views[id] = TextField(placeholder: title)

            case "TUILIST":
                registry.views[id] = ListView()

            case "TUITABLE":
                // Columns arrive later, through `column`. TableView wants them
                // at construction, so it starts with one placeholder that the
                // first `column` call replaces — a table with no columns at all
                // draws nothing and looks like a failure to build.
                registry.views[id] = TableView(columns: [])

            case "TUICHECK":
                registry.views[id] = Checkbox(title)

            case "TUITEXT":
                registry.views[id] = TextView(text: title)

            case "TUIGAUGE":
                registry.views[id] = Gauge(value: 0, in: 0...100)

            case "TUIMENU":
                // The bar, not a menu: a program adds menus to it by title.
                registry.menus[id] = MenuBar()

            case "TUIDIALOG":
                registry.dialogs[id] = BASICTUIDialogSpec(title: title)

            default:
                guard try BASICRuntime.tuiChromeObject(
                    typeName: typeName, title: title, registry: registry
                ) else {
                    throw BASICError.runtime("Unknown TUI class \(typeName)")
                }
            }
            return id
        }
        return .systemObject(typeName, id)
    }

    /// Dispatches a method on a TUI handle.
    ///
    /// - Parameter invokeHandler: Calls a BASIC function by name. Passed in
    ///   rather than reached for, because the runtime has no way to call into
    ///   the interpreter and a control's whole purpose is to do exactly that.
    func callTUIMethod(
        typeName: String,
        id: Int,
        method: String,
        arguments: [BASICValue],
        presentationHost: (any BASICTUIPresentationHost)?,
        invokeHandler: @escaping (String) throws -> Void
    ) throws -> BASICValue {
        let name = method.uppercased()

        // `run` is the one that blocks, and the one that needs a driver and an
        // event loop, so it is handled before the ordinary property setters.
        if name == "RUN" {
            return try runTUIApplication(
                appID: id,
                arguments: arguments,
                presentationHost: presentationHost,
                invokeHandler: invokeHandler
            )
        }

        return try withTUIRegistry { registry in
            // A local rather than a nested `func`, which would not inherit the
            // closure's main-actor isolation and so could not read the registry.
            let subject = registry.views[id]
            func view() throws -> TUIView {
                guard let subject else {
                    throw BASICError.runtime("\(typeName) is not a view")
                }
                return subject
            }

            switch name {
            case "ADD":
                guard let first = arguments.first,
                      case .systemObject(_, let childID) = first else {
                    throw BASICError.runtime("\(typeName).add expects a TUI view")
                }
                // A menu bar is attached, not stacked: it anchors itself across
                // the top of the window rather than taking a place in a column.
                // Checked before the view lookup below, because a bar is not in
                // the view table and would be rejected as "not a TUI view".
                // A status strip owns the last row, the way a menu bar owns the
                // first. Filling the window with it would hide everything else.
                if let window = registry.windows[id],
                   let strip = registry.views[childID] as? StatusBar {
                    strip.anchors = AnchorSet(leading: 0, trailing: 0, bottom: 0, height: 1)
                    window.addSubview(strip)
                    registry.windowsWithStatusBars.insert(id)
                    return .empty
                }
                if let window = registry.windows[id], let bar = registry.menus[childID] {
                    bar.anchors = AnchorSet(leading: 0, trailing: 0, top: 0, height: 1)
                    window.addSubview(bar)
                    registry.windowsWithMenuBars.insert(id)
                    // Anything already filling the window is covering the bar.
                    // Push it down a row rather than leaving a menu that is
                    // drawn and then painted over — which looks like a menu bar
                    // that does not work.
                    for existing in window.subviews where existing !== bar {
                        existing.anchors = AnchorSet(leading: 0, trailing: 0, top: 1, bottom: 0)
                    }
                    return .empty
                }
                guard let child = registry.views[childID] else {
                    throw BASICError.runtime("\(typeName).add expects a TUI view")
                }
                // A panel and a floating window are frames: things go *inside*
                // them, not on top of them. Adding to the view itself would put
                // the child over the border.
                if let window = registry.floatingWindows[id] {
                    child.anchors = AnchorSet(leading: 0, trailing: 0, top: 0, bottom: 0)
                    window.content.addSubview(child)
                    return .empty
                }
                if let panel = registry.views[id] as? Panel {
                    child.anchors = AnchorSet(leading: 0, trailing: 0, top: 0, bottom: 0)
                    panel.content.addSubview(child)
                    return .empty
                }
                if let window = registry.windows[id] {
                    // Fill the window unless the program has said otherwise. A
                    // view added with no anchors gets zero size and the window
                    // comes up blank — which looks like the app failing to
                    // start rather than a layout that was never given.
                    //
                    // One row down when there is a menu bar, which owns the top.
                    let top = registry.windowsWithMenuBars.contains(id) ? 1 : 0
                    let bottom = registry.windowsWithStatusBars.contains(id) ? 1 : 0
                    child.anchors = AnchorSet(
                        leading: 0, trailing: 0, top: top, bottom: bottom
                    )
                    window.addSubview(child)
                } else {
                    let parent = try view()
                    // A stack lays its children out along its axis, but only
                    // once they have a height to be laid out with.
                    if parent is StackView, child.frame.size.height == 0 {
                        child.frame = Rect(x: 0, y: 0, width: 1, height: 1)
                    }
                    parent.addSubview(child)
                }
                return .empty

            case "TITLE", "TEXT":
                guard let value = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).\(method) expects a string")
                }
                if let label = try? view() as? Label {
                    label.text = value
                } else if let button = try? view() as? Button {
                    button.title = value
                } else if let field = try? view() as? TextField {
                    // `text` is private(set); `setText` is the door.
                    field.setText(value)
                }
                return .empty

            case "COLUMN":
                guard let table = try view() as? TableView else {
                    throw BASICError.runtime("\(typeName) has no columns")
                }
                guard let heading = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).column expects a title")
                }
                table.columns.append(TableColumn(heading))
                return .empty

            case "ADDROW":
                guard let table = subject as? TableView else {
                    // A sidebar's `addrow` — icon, title, subtitle.
                    return try BASICRuntime.callTUIChromeMethod(
                        typeName: typeName, id: id, method: method,
                        arguments: arguments, registry: registry
                    )
                }
                // Short rows are padded rather than refused, as RichTable does:
                // a table gaining a column should not turn every existing
                // addrow into a runtime error halfway through a program.
                var row = arguments.map { $0.string?.description ?? Self.tuiPlain($0) }
                while row.count < table.columns.count { row.append("") }
                table.rows.append(row)
                return .empty

            case "MENU":
                guard let bar = registry.menus[id] else {
                    throw BASICError.runtime("\(typeName) is not a menu bar")
                }
                guard let heading = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).menu expects a title")
                }
                let menu = Menu(heading)
                bar.addMenu(menu)
                // Items go into the menu most recently opened, so a program
                // reads top to bottom: menu "File", item, item, menu "Edit".
                registry.openMenus[id] = menu
                return .empty

            case "ITEM":
                guard let menu = registry.openMenus[id] else {
                    throw BASICError.runtime("\(typeName).item needs a menu — call menu first")
                }
                guard let label = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).item expects a title")
                }
                let handler = arguments.count > 1
                    ? arguments[1].string?.description
                    : nil
                _ = menu.addItem(label) {
                    guard let handler else { return }
                    BASICTUIRuntimeBridge.shared.invoke(handlerNamed: handler)
                }
                return .empty

            case "SEPARATOR":
                guard let menu = registry.openMenus[id] else {
                    throw BASICError.runtime("\(typeName).separator needs a menu")
                }
                menu.addSeparator()
                return .empty

            case "MESSAGE":
                guard let dialog = registry.dialogs[id] else {
                    throw BASICError.runtime("\(typeName) is not a dialog")
                }
                guard let body = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).message expects text")
                }
                registry.dialogs[id]?.message = body
                _ = dialog
                return .empty

            case "ADDBUTTON":
                guard let dialog = registry.dialogs[id] else {
                    throw BASICError.runtime("\(typeName) is not a dialog")
                }
                guard let label = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).addbutton expects a title")
                }
                let handler = arguments.count > 1 ? arguments[1].string?.description : nil
                registry.dialogs[id]?.buttons.append((title: label, handler: handler))
                _ = dialog
                return .empty

            case "CHECKED":
                guard let box = try view() as? Checkbox else {
                    throw BASICError.runtime("\(typeName) has nothing to check")
                }
                // With an argument it sets; without one it reads. A program
                // asking "is it ticked?" and a program ticking it are the same
                // word in BASIC, and splitting them into `checked` and
                // `setchecked` buys nothing.
                if let wanted = arguments.first {
                    box.setChecked(wanted.truthy)
                    return .empty
                }
                return .boolean(box.isChecked)

            case "ONTOGGLE":
                guard let box = try view() as? Checkbox else {
                    throw BASICError.runtime("\(typeName) has nothing to toggle")
                }
                guard let handler = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).ontoggle expects a handler name")
                }
                registry.handlers[id] = handler
                if registry.pendingFirstResponder == nil {
                    registry.pendingFirstResponder = box
                }
                box.onChange = { _ in
                    BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                }
                return .empty

            case "ADDITEM":
                guard let list = subject as? ListView else {
                    // A toolbar's `additem` — same word, different control.
                    return try BASICRuntime.callTUIChromeMethod(
                        typeName: typeName, id: id, method: method,
                        arguments: arguments, registry: registry
                    )
                }
                guard let value = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).additem expects a string")
                }
                list.items.append(value)
                return .empty

            case "SELECTED":
                if let table = try? view() as? TableView {
                    return .number(Double(table.selectedIndex ?? -1))
                }
                guard let list = subject as? ListView else {
                    return try BASICRuntime.callTUIChromeMethod(
                        typeName: typeName, id: id, method: method,
                        arguments: arguments, registry: registry
                    )
                }
                // -1 rather than an error when nothing is selected: a program
                // asking "which row?" before the user has touched anything is
                // the ordinary case, not a mistake.
                return .number(Double(list.selectedIndex ?? -1))

            case "SELECTEDTEXT$", "SELECTEDTEXT":
                guard let list = try view() as? ListView else {
                    throw BASICError.runtime("\(typeName) is not a list")
                }
                guard let index = list.selectedIndex, list.items.indices.contains(index) else {
                    return .string(BASICString(""))
                }
                return .string(BASICString(list.items[index]))

            case "VALUE$", "VALUE":
                // A label reads too. It has no *input*, but "what does it say
                // now?" is the obvious question to ask one after a handler has
                // been changing it, and refusing meant a handler that read a
                // label threw mid-frame — parking the error and never reaching
                // `app.stop()`, so the program hung instead of quitting.
                if let label = try? view() as? Label {
                    if let wanted = arguments.first?.string?.description {
                        label.text = wanted
                        return .empty
                    }
                    return .string(BASICString(label.text))
                }
                if let button = try? view() as? Button {
                    return .string(BASICString(button.title))
                }
                if let box = try? view() as? Checkbox {
                    return .boolean(box.isChecked)
                }
                if let gauge = try? view() as? Gauge {
                    if let wanted = arguments.first?.number {
                        gauge.setValue(wanted)
                        return .empty
                    }
                    return .number(gauge.value)
                }
                if let editor = try? view() as? TextView {
                    if let wanted = arguments.first?.string?.description {
                        editor.setText(wanted)
                        return .empty
                    }
                    return .string(BASICString(editor.text))
                }
                guard let field = try view() as? TextField else {
                    throw BASICError.runtime("\(typeName) has no value to read")
                }
                return .string(BASICString(field.text))

            case "ONSELECT":
                guard let handler = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).onselect expects a handler name")
                }
                registry.handlers[id] = handler
                if let table = try? view() as? TableView {
                    if registry.pendingFirstResponder == nil {
                        registry.pendingFirstResponder = table
                    }
                    table.onSelectionChanged = { _ in
                        BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                    }
                    return .empty
                }
                guard let list = subject as? ListView else {
                    // A tab strip's or a sidebar's selection.
                    return try BASICRuntime.callTUIChromeMethod(
                        typeName: typeName, id: id, method: method,
                        arguments: arguments, registry: registry
                    )
                }
                if registry.pendingFirstResponder == nil {
                    registry.pendingFirstResponder = list
                }
                list.onSelectionChanged = { _ in
                    BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                }
                return .empty

            case "ONCHANGE":
                guard let field = try view() as? TextField else {
                    throw BASICError.runtime("\(typeName) has no text to handle")
                }
                guard let handler = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).onchange expects a handler name")
                }
                registry.handlers[id] = handler
                if registry.pendingFirstResponder == nil {
                    registry.pendingFirstResponder = field
                }
                field.onChanged = { _ in
                    BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                }
                return .empty

            case "ONCLICK":
                // Recorded here rather than at `add`: a button only earns focus
                // once it has something to do.
                guard let handler = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).onclick expects a handler name")
                }
                guard let button = try view() as? Button else {
                    throw BASICError.runtime("\(typeName) has no click to handle")
                }
                registry.handlers[id] = handler
                if registry.pendingFirstResponder == nil {
                    registry.pendingFirstResponder = button
                }
                // The closure is installed once and reads the registry each
                // time, so `onclick` may be called again to change the handler
                // without leaving the old one wired underneath.
                button.onActivate = {
                    // A handler that throws must not escape into TUIKit, which
                    // has nowhere to put a BASIC error mid-frame. It is parked
                    // and re-thrown by `run`, the statement the program is
                    // actually sitting on.
                    BASICTUIRuntimeBridge.shared.invoke(handlerFor: id)
                }
                return .empty

            case "SHOW":
                guard let app = registry.apps[id] else {
                    throw BASICError.runtime("\(typeName) is not an application")
                }
                guard case .systemObject(_, let dialogID)? = arguments.first,
                      let spec = registry.dialogs[dialogID] else {
                    throw BASICError.runtime("\(typeName).show expects a dialog")
                }
                let dialog = Dialog(title: spec.title, message: spec.message)
                for (index, button) in spec.buttons.enumerated() {
                    // The first button added is the default, and so the one
                    // with focus. Without a default nothing in the dialog is
                    // focused, Enter does nothing, and the dialog looks frozen —
                    // which is exactly how it first behaved.
                    _ = dialog.addButton(button.title, isDefault: index == 0) {
                        guard let handler = button.handler else { return }
                        BASICTUIRuntimeBridge.shared.invoke(handlerNamed: handler)
                    }
                }
                // `addButton` calls the action and *then* `onDismiss`, so
                // confirming and cancelling both land here and neither leaves a
                // window behind.
                dialog.onDismiss = { [weak app, weak dialog] in
                    if let app, let dialog { app.dismiss(dialog) }
                }
                // Sized twice, as TUIKit's own document controller does: once
                // before it is placed, once after, when the desktop has given
                // it a frame to be measured against.
                dialog.sizeToFit(in: app.desktop.bounds.size)
                app.present(dialog)
                dialog.sizeToFit(in: app.desktop.bounds.size)
                return .empty

            case "STOP":
                guard let app = registry.apps[id] else {
                    throw BASICError.runtime("\(typeName) is not an application")
                }
                app.stop()
                return .empty

            default:
                // Not a control method — try the shell (BASICTUIChrome.swift).
                // One `default` rather than two switches the caller has to
                // choose between, so a program never has to know which half of
                // the binding a method lives in.
                return try BASICRuntime.callTUIChromeMethod(
                    typeName: typeName,
                    id: id,
                    method: method,
                    arguments: arguments,
                    registry: registry
                )
            }
        }
    }

    /// Runs a TUI application and blocks until it stops.
    private func runTUIApplication(
        appID: Int,
        arguments: [BASICValue],
        presentationHost: (any BASICTUIPresentationHost)?,
        invokeHandler: @escaping (String) throws -> Void
    ) throws -> BASICValue {
        guard case .systemObject(_, let windowID) = arguments.first else {
            throw BASICError.runtime("TUIApp.run expects a window")
        }
        guard let host = presentationHost else {
            throw BASICError.runtime("This host cannot show a TUI application")
        }
        BASICTUIRuntimeBridge.shared.invokeHandler = invokeHandler
        defer { BASICTUIRuntimeBridge.shared.invokeHandler = nil }

        try BASICTUIRuntimeBridge.runBlocking(appID: appID, windowID: windowID, host: host)

        if let failure = BASICTUIRuntimeBridge.shared.takeFailure() {
            throw failure
        }
        return .empty
    }
}

extension BASICRuntime {
    /// A non-string BASIC value as a table cell.
    ///
    /// Numbers reach `addrow` constantly — a row of counts is the ordinary
    /// case — and refusing them would make every call site wrap in `STR$`.
    static func tuiPlain(_ value: BASICValue) -> String {
        if let number = value.number {
            return number == number.rounded() && abs(number) < 1e15
                ? String(Int(number))
                : String(number)
        }
        if case .boolean(let flag) = value { return flag ? "True" : "False" }
        return ""
    }
}
