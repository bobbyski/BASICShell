//
//  BASICTUIRuntimeBridge.swift
//  BASICCore
//
//  Running a `@MainActor async` TUIKit application from a synchronous,
//  non-isolated interpreter — and carrying a BASIC error back out of a
//  TUIKit callback.
//

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import TUIKit

/// The bridge between a running TUI application and the interpreter.
///
/// ## The deadlock this exists to avoid
///
/// The interpreter is synchronous and runs on the main thread. TUIKit's `App`
/// is `@MainActor` and `async`. The obvious bridge —
///
/// ```swift
///   Task { @MainActor in try await app.run(window) }
///   semaphore.wait()          // ← hangs, every time
/// ```
///
/// — cannot work: the semaphore blocks the main thread, the main actor's
/// executor *is* the main thread, so the task it waits for can never be
/// scheduled. It deadlocks silently.
///
/// It pumps the run loop instead. The main thread keeps servicing the main
/// queue, which is where the main actor's work is enqueued, so the task runs
/// and the loop exits when it finishes.
///
/// The same shape solved the same problem for the shell's editor
/// (`BASICShellEditor.swift`); this is that bridge, moved where both hosts and
/// the binding can reach it.
final class BASICTUIRuntimeBridge: @unchecked Sendable {
    static let shared = BASICTUIRuntimeBridge()
    private init() {}

    /// Calls a BASIC function by name. Set for the duration of `run`.
    var invokeHandler: ((String, [BASICValue]) throws -> Void)?

    private var failure: BASICError?

    /// Records an error raised inside a control's handler.
    ///
    /// A handler cannot throw *through* TUIKit — it is called mid-frame from a
    /// non-throwing closure, and there is nowhere for an error to go. So it is
    /// parked here and re-thrown by `run`, which is the statement the program
    /// is actually sitting on.
    func fail(with error: BASICError) {
        if failure == nil { failure = error }
    }

    /// Takes the parked error, if there is one.
    func takeFailure() -> BASICError? {
        defer { failure = nil }
        return failure
    }

    /// Lends the terminal to a full-screen application and takes it back.
    ///
    /// TUIKit's driver sets `O_NONBLOCK` on standard input when it starts and
    /// does not clear it when it stops. A shell's line editor saves and
    /// restores `termios` around every read, but `termios` is not where that
    /// flag lives — the next `read` would return `EAGAIN` forever, which reads
    /// as end of input, and the session would end when the program did.
    static func lendingTerminal<Value>(_ body: () throws -> Value) rethrows -> Value {
        let descriptor = STDIN_FILENO
        let saved = fcntl(descriptor, F_GETFL)
        defer {
            if saved >= 0 { _ = fcntl(descriptor, F_SETFL, saved) }
        }
        return try body()
    }

    /// Calls the BASIC handler wired to a control, parking any error.
    ///
    /// `@MainActor` because TUIKit calls it from a control mid-frame, and the
    /// registry it reads is main-actor isolated.
    @MainActor
    func invoke(handlerFor id: Int) {
        let handler = BASICTUIRegistry.shared.handlers[id]
        BASICTUITrace.log("invoke(handlerFor: \(id)) → \(handler ?? "NO HANDLER REGISTERED")"
            + " (registered ids: \(BASICTUIRegistry.shared.handlers.keys.sorted()))")
        guard let handler else { return }
        invoke(handlerNamed: handler)
    }

    /// Calls a BASIC handler by name.
    ///
    /// Menu items and dialog buttons are not handles a program holds — they are
    /// built and named in one call — so they carry their handler's name rather
    /// than an id to look it up by.
    @MainActor
    func invoke(handlerNamed handler: String) {
        invoke(handlerNamed: handler, with: [])
    }

    /// Calls a handler with arguments — how a control hands back the thing it
    /// was carrying.
    ///
    /// A Swift closure captures its value (`addItem(name) { apply(theme) }`);
    /// a BASIC handler is a name, so the value has to travel with the call or
    /// the program needs one near-identical function per value.
    func invoke(handlerNamed handler: String, with arguments: [BASICValue]) {
        guard let invoke = invokeHandler else {
            BASICTUITrace.log("\(handler): no invokeHandler — nothing can dispatch it")
            return
        }
        do {
            try invoke(handler, arguments)
            BASICTUITrace.log("\(handler): ran")
        } catch let error as BASICError {
            // Parked rather than thrown: a handler is called mid-frame from a
            // non-throwing closure. Parking it silently is also why a handler
            // that fails looks exactly like one that never ran.
            BASICTUITrace.log("\(handler): FAILED — \(error)")
            fail(with: error)
        } catch {
            BASICTUITrace.log("\(handler): FAILED — \(error)")
            fail(with: .runtime("\(error)"))
        }
    }

    /// Runs the application, blocking until it stops.
    ///
    /// Everything main-actor isolated happens inside: the `App` is built here
    /// because TUIKit takes its driver at construction and offers no way to
    /// swap it, and the driver is the host's answer rather than the binding's.
    static func runBlocking(appID: Int, windowID: Int, host: any BASICTUIPresentationHost) throws {
        // The driver is asked for out here, so the *host* — which is not
        // Sendable — never has to cross an isolation boundary. `TerminalDriver`
        // is Sendable, so the driver itself may.
        guard let driver = host.makeTUIDriver() else {
            throw BASICError.runtime("This host has no surface to draw a TUI application on")
        }
        try runBlocking(appID: appID, windowID: windowID, driver: driver)
    }

    /// The same, for a caller that already has a driver and no host to ask.
    /// A compiled program is its own host: it brings an `ANSIDriver` and
    /// nothing else of a `BASICHost`.
    static func runBlocking(appID: Int, windowID: Int, driver: any TerminalDriver) throws {
        return try lendingTerminal {
            let box = Box()

            // Building the App and starting its loop are main-actor work, and
            // an ordinary `RUN` is on a worker lane — so this hops rather than
            // assuming. The hop is safe because `runProgramSynchronously`
            // leaves the main thread pumping its run loop instead of parked in
            // a semaphore; without that, this would wait forever for a main
            // actor that is blocked waiting for this very worker.
            let started = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let registry = BASICTUIRegistry.shared
                guard let window = registry.windows[windowID],
                      registry.kinds[appID]?.uppercased() == "TUIAPP" else {
                    box.error = BASICError.runtime("TUIApp.run expects an application and a window")
                    box.isFinished = true
                    started.signal()
                    return
                }
                let app = App(driver: driver)
                // `^C` is a control's copy key in TUIKit, and an app that quits
                // on it would lose a program's window to a mistimed keystroke.
                app.stopsOnControlC = false
                registry.apps[appID] = app

                // Esc quits a shell window, which needs the application it is
                // quitting — so this is the earliest it can be wired.
                (window as? BASICTUIShellWindow)?.onQuit = { [weak app] in app?.stop() }

                // Everything the program said to its application before there
                // was one to say it to.
                if let theme = registry.pendingTheme {
                    BASICRuntime.applyTUITheme(theme, to: app)
                }
                for timer in registry.pendingTimers {
                    _ = app.addTimer(every: .milliseconds(Int(timer.seconds * 1000))) {
                        BASICTUIRuntimeBridge.shared.invoke(handlerNamed: timer.handler)
                    }
                }
                for scheduled in registry.pendingSchedules {
                    app.schedule(after: .milliseconds(scheduled.milliseconds)) {
                        BASICTUIRuntimeBridge.shared.invoke(handlerNamed: scheduled.handler)
                    }
                }

                // Focus the first control that has a handler. Without this the
                // window opens with nothing focused, the first keypress goes
                // nowhere, and the program looks hung rather than waiting.
                if let first = registry.pendingFirstResponder {
                    _ = window.makeFirstResponder(first)
                }
                started.signal()

                // Presented *after* `run` has started, not before. `App.run`
                // shows its own window last, so a floating window presented
                // first is immediately buried under the desktop — which looks
                // exactly like `present` doing nothing at all.
                //
                // A one-shot timer is the shortest way to be later than a call
                // that has not returned yet.
                let presents = registry.pendingPresents.compactMap { registry.floatingWindows[$0] }
                // Re-applied once the loop is up, together with the windows.
                //
                // `App.run` builds its own desktop as it starts, which throws
                // away a `desktop.fillStyle` set before it — so the theme was
                // dressing the windows and the desktop was reverting to the
                // terminal's own background. Setting it before *and* after is
                // what makes the color stick.
                let theme = registry.pendingTheme
                if !presents.isEmpty || theme != nil {
                    _ = app.addTimer(every: .milliseconds(1), repeats: false) { [weak app] in
                        guard let app else { return }
                        if let theme {
                            BASICRuntime.applyTUITheme(theme, to: app)
                        }
                        for extra in presents {
                            app.present(extra)
                        }
                    }
                }

                do {
                    try await app.run(window)
                } catch {
                    box.error = error
                }
                box.isFinished = true
            }
            // Pumped rather than waited on when this *is* the main thread —
            // a compiled program calls `run` from it, and the task below is
            // enqueued on the main actor, whose executor is that same
            // thread. Waiting here would be waiting for itself.
            if Thread.isMainThread {
                while started.wait(timeout: .now()) == .timedOut {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
                }
            } else {
                started.wait()
            }

            // Waiting for the application to finish. On the main thread this
            // pumps; on a worker it blocks, because the main thread is already
            // pumping on its behalf.
            if Thread.isMainThread {
                while !box.isFinished {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
                }
            } else {
                while !box.isFinished {
                    usleep(2000)
                }
            }

            // Released when the app stops rather than left to accumulate: a
            // program that shows a dialog in a loop would otherwise retain
            // every window it ever built, and the handles are dead anyway.
            try withTUIRegistry { $0.releaseAll() }

            if let error = box.error {
                if let basic = error as? BASICError { throw basic }
                throw BASICError.runtime("TUI application failed: \(error)")
            }
        }
    }

    /// Result box, since the task's outcome has to cross an actor boundary.
    private final class Box: @unchecked Sendable {
        var isFinished = false
        var error: Error?
    }
}
