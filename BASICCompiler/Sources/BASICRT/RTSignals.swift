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
// The signals are blocked in every thread and taken by one thread waiting
// for them, so the shutdown is ordinary Swift on an ordinary thread rather
// than the short list of calls a signal handler is allowed to make.

enum RTSignals {
    /// The ways a program is asked to stop that leave time to tidy up.
    /// `SIGKILL` and `SIGSTOP` cannot be caught, and nothing here pretends
    /// otherwise — a program killed outright still leaves the terminal as
    /// it was, and that is the shell's business to repair.
    static let watched: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]

    nonisolated(unsafe) private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var mask = sigset_t()
        sigemptyset(&mask)
        for number in watched { sigaddset(&mask, number) }
        // Blocked before any other runtime thread exists, so they all
        // inherit the block and the waiting thread is the only taker.
        guard pthread_sigmask(SIG_BLOCK, &mask, nil) == 0 else {
            installed = false
            return
        }
        let waiter = Thread { RTSignals.wait(on: mask) }
        waiter.name = "basic-rt-signals"
        waiter.stackSize = 1 << 19
        waiter.start()
    }

    private static func wait(on mask: sigset_t) {
        var mask = mask
        var received: Int32 = 0
        while sigwait(&mask, &received) != 0 {}
        stop(after: received)
    }

    private static func stop(after number: Int32) -> Never {
        // The terminal first: raw mode off, mouse reporting off, the canvas
        // cleared and presented. This is `END`'s shutdown, not a second one
        // that could drift away from it.
        RTGraphics.finish()
        if number == SIGINT {
            // What `RUN` prints. The line is the body statement in progress
            // — the same one `ERL` would report — so a break inside a
            // FUNCTION names the call that is running, not the line within
            // it: statements are only marked in the body, because marking
            // every statement everywhere is what that costs.
            fputs("Break at \(RTError.line)\n", stdout)
        }
        fflush(stdout)
        // Die of the signal rather than of `exit`, so whatever started the
        // program reads the right reason from its wait status.
        signal(number, SIG_DFL)
        var only = sigset_t()
        sigemptyset(&only)
        sigaddset(&only, number)
        pthread_sigmask(SIG_UNBLOCK, &only, nil)
        raise(number)
        _exit(128 &+ number)
    }
}
