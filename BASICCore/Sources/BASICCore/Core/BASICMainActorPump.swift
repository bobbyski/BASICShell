//
//  BASICMainActorPump.swift
//  BASICCore
//

import Foundation

/// Whether a running program needs the main actor to make progress.
///
/// A BASIC program runs on a worker lane while the main thread waits for it.
/// Normally the main thread can simply block — nothing else needs to happen.
/// But a program that drives TUIKit needs the *main actor*, which is the main
/// thread, so the wait has to become a run-loop pump instead.
///
/// It is a request rather than the default because pumping is not free of
/// consequence: servicing the run loop mid-run delivers main-queue work that
/// would otherwise have waited, and doing it unconditionally changed async
/// cancellation timing enough to make an existing test fail intermittently.
/// Programs that never touch the main actor are therefore timed exactly as
/// they were.
///
/// Set once, on the first main-actor hop, and cleared when the program ends.
enum BASICMainActorPump {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requested = false

    /// Whether the main thread should service its run loop while it waits.
    static var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    /// Asks the main thread to start pumping.
    static func request() {
        lock.lock()
        defer { lock.unlock() }
        requested = true
    }

    /// Forgets the request, so the next program starts unpumped.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        requested = false
    }
}
