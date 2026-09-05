import Foundation
#if canImport(Darwin)
import Darwin
#endif

// BASICRT signals: stopping a compiled program the way the interpreter is
// stopped.
//
// A graphics program owns the terminal while it runs — raw mode, mouse
// reporting, and a canvas painted over the screen. Dying on Ctrl-C without
// putting those back leaves the shell that started it typing escape
// sequences at a prompt that cannot read them, under a dashboard that is
// still drawn. The interpreter never did that: a break there unwinds
// through `finishVectorTerminalForegroundRun`, which is the same shutdown
// `basic_rt_finish` already runs when a compiled program reaches `END`. It
// simply never ran when the program was killed instead of ending.
//
// The work happens on a dispatch queue rather than in a signal handler, so
// it is ordinary Swift — `RTGraphics.finish()` allocates, and a handler may
// not — and the same shutdown `END` runs can be called directly.

enum RTSignals {
    /// The ways a program is asked to stop that leave time to tidy up.
    /// `SIGKILL` and `SIGSTOP` cannot be caught, and nothing here pretends
    /// otherwise — a program killed outright still leaves the terminal as
    /// it was, and that is the shell's business to repair.
    static let watched: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]

    /// Held for the life of the program: a source that is released stops
    /// watching, and a program that stopped watching Ctrl-C cannot be
    /// interrupted at all.
    nonisolated(unsafe) private static var sources: [any DispatchSourceSignal] = []
    nonisolated(unsafe) private static var stopping = false
    private static let lock = NSLock()

    static func install() {
        guard sources.isEmpty else { return }
        for number in watched {
            // The default action has to go first, or the process dies of the
            // signal before the source is ever asked about it. `SIG_IGN` is
            // what makes the signal survivable long enough to be handled;
            // `stop` puts the default back before re-raising.
            //
            // Blocking the signals and taking them with `sigwait` on a thread
            // of our own reads better and does not work: on Darwin a
            // process-directed signal never reaches `sigwait`, so the program
            // became one that ignored Ctrl-C entirely. This is the mechanism
            // Darwin actually delivers on.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { RTSignals.stop(after: number) }
            source.resume()
            sources.append(source)
        }
    }

    private static func stop(after number: Int32) {
        lock.lock()
        if stopping {
            lock.unlock()
            return
        }
        stopping = true
        lock.unlock()

        // The terminal first: raw mode off, mouse reporting off, the canvas
        // cleared and presented. This is `END`'s shutdown, not a second one
        // that could drift away from it.
        RTGraphics.finish()
        // What `RUN` prints — but only when the line is actually known. A
        // compiled program marks statements only when something needs them
        // (`ERL`, `RESUME NEXT`), because marking every statement costs
        // something on every statement; without that the line reads 0, and
        // `Break at 0` is a worse answer than no answer. When it is known it
        // is the body statement in progress, the one `ERL` reports, so a
        // break inside a FUNCTION names the call that is running.
        if number == SIGINT, RTError.line > 0 {
            fputs("Break at \(RTError.line)\n", stdout)
        }
        fflush(stdout)
        // Die of the signal rather than of `exit`, so whatever started the
        // program reads the right reason from its wait status.
        signal(number, SIG_DFL)
        raise(number)
        _exit(128 &+ number)
    }
}
