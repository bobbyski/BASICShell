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
        return id
    }

    /// Everything a finished application leaves behind.
    ///
    /// Called when `run` returns rather than left to accumulate: a program that
    /// opens a dialog in a loop would otherwise retain every window it ever
    /// showed, and the handles are dead the moment the app stops.
    func releaseAll() {
        pendingFirstResponder = nil
        views.removeAll()
        apps.removeAll()
        windows.removeAll()
        handlers.removeAll()
        kinds.removeAll()
    }
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

            default:
                throw BASICError.runtime("Unknown TUI class \(typeName)")
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
                      case .systemObject(_, let childID) = first,
                      let child = registry.views[childID] else {
                    throw BASICError.runtime("\(typeName).add expects a TUI view")
                }
                if let window = registry.windows[id] {
                    // Fill the window unless the program has said otherwise. A
                    // view added with no anchors gets zero size and the window
                    // comes up blank — which looks like the app failing to
                    // start rather than a layout that was never given.
                    child.anchors = AnchorSet(leading: 0, trailing: 0, top: 0, bottom: 0)
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

            case "ADDITEM":
                guard let list = try view() as? ListView else {
                    throw BASICError.runtime("\(typeName) is not a list")
                }
                guard let value = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).additem expects a string")
                }
                list.items.append(value)
                return .empty

            case "SELECTED":
                guard let list = try view() as? ListView else {
                    throw BASICError.runtime("\(typeName) is not a list")
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
                guard let field = try view() as? TextField else {
                    throw BASICError.runtime("\(typeName) has no value to read")
                }
                return .string(BASICString(field.text))

            case "ONSELECT":
                guard let list = try view() as? ListView else {
                    throw BASICError.runtime("\(typeName) has no selection to handle")
                }
                guard let handler = arguments.first?.string?.description else {
                    throw BASICError.runtime("\(typeName).onselect expects a handler name")
                }
                registry.handlers[id] = handler
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

            case "STOP":
                guard let app = registry.apps[id] else {
                    throw BASICError.runtime("\(typeName) is not an application")
                }
                app.stop()
                return .empty

            default:
                throw BASICError.runtime("\(typeName) has no method \(method)")
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
