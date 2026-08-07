import Foundation

/// Lock-protected mirror of the Studio state that `BASICCore` queries from the
/// interpreter thread on every executed statement.
///
/// `StudioModel` is `@MainActor`, so answering `isBASICLoggingEnabled` and
/// `isBASICTraceEnabled` directly from the model forced a `DispatchQueue.main.sync`
/// hop per statement. This box holds the same values behind an uncontended lock so
/// the interpreter can read them without leaving its own thread. The model pushes a
/// new snapshot whenever any of the source values change.
final class StudioHostFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var loggingEnabled = false
    private var traceEnabled = false
    private var debuggerOpen = false

    var isLoggingEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loggingEnabled
    }

    var isTraceEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loggingEnabled && traceEnabled
    }

    var isDebuggerOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return debuggerOpen
    }

    func update(loggingEnabled: Bool, traceEnabled: Bool, debuggerOpen: Bool) {
        lock.lock()
        self.loggingEnabled = loggingEnabled
        self.traceEnabled = traceEnabled
        self.debuggerOpen = debuggerOpen
        lock.unlock()
    }
}

/// Thread-safe hand-off buffer for log entries produced on the interpreter thread.
///
/// The interpreter appends here without blocking; `StudioModel` drains the buffer on
/// the main actor at a bounded rate, so a chatty program produces one coalesced
/// SwiftUI update instead of one per `LOG` statement.
final class StudioLogBuffer: @unchecked Sendable {
    struct PendingEntry {
        let timestamp: Date
        let level: String
        let issuer: String
        let module: String
        let text: String
    }

    /// Cap on unread entries. The log view keeps only the newest 1000 anyway, so
    /// dropping the oldest overflow costs nothing a reader could have seen.
    private static let capacity = 4000

    private let lock = NSLock()
    private var pending: [PendingEntry] = []
    private var overflowCount = 0

    /// Appends an entry and reports whether the buffer went from empty to non-empty,
    /// which is the signal the model uses to schedule exactly one drain.
    func append(_ entry: PendingEntry) -> Bool {
        lock.lock()
        let wasEmpty = pending.isEmpty
        pending.append(entry)
        if pending.count > Self.capacity {
            let excess = pending.count - Self.capacity
            pending.removeFirst(excess)
            overflowCount += excess
        }
        lock.unlock()
        return wasEmpty
    }

    func drain() -> (entries: [PendingEntry], dropped: Int) {
        lock.lock()
        let entries = pending
        let dropped = overflowCount
        pending.removeAll(keepingCapacity: true)
        overflowCount = 0
        lock.unlock()
        return (entries, dropped)
    }

    func removeAll() {
        lock.lock()
        pending.removeAll(keepingCapacity: true)
        overflowCount = 0
        lock.unlock()
    }
}
