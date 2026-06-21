import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum BASICExecutionMode: Sendable {
    /// Run normally until completion, break, or breakpoint.
    case run
    /// Pause after the next executed statement.
    case stepInto
    /// Pause after stepping over calls deeper than the provided call depth.
    case stepOver(depth: Int)
    /// Pause after returning out of the provided call depth.
    case stepOut(depth: Int)
}

/// Thread-safe execution-control object for breaks, breakpoints, and stepping.
public final class BASICExecutionControl: @unchecked Sendable {
    private let lock = NSLock()
    private var breakRequested = false
    private var currentLineNumber: Int?
    private var currentLocation: BASICBreakpointLocation?
    private var breakpoints: [BASICBreakpointLocation] = []
    private var ignoredBreakpointLocation: BASICBreakpointLocation?
    private var mode: BASICExecutionMode = .run
    private var targetTaskID: Int?

    /// Creates an execution control with no pending breakpoints or break request.
    public init() {}

    /// Clears pending break requests and the current source location.
    public func reset() {
        lock.lock()
        breakRequested = false
        currentLineNumber = nil
        currentLocation = nil
        lock.unlock()
    }

    /// Requests a cooperative break on the execution thread.
    public func requestBreak() {
        lock.lock()
        breakRequested = true
        lock.unlock()
    }

    /// Current BASIC display line number, if execution has started.
    public var lineNumber: Int? {
        lock.lock()
        defer { lock.unlock() }
        return currentLineNumber
    }

    /// Current precise breakpoint location, if execution has started.
    public var location: BASICBreakpointLocation? {
        lock.lock()
        defer { lock.unlock() }
        return currentLocation
    }

    /// Replaces the active breakpoint set.
    public func setBreakpoints(_ breakpoints: [BASICBreakpoint]) {
        lock.lock()
        self.breakpoints = breakpoints.filter(\.isEnabled).map(\.location)
        lock.unlock()
    }

    /// Sets the current debugger stepping mode.
    public func setMode(_ mode: BASICExecutionMode) {
        lock.lock()
        self.mode = mode
        lock.unlock()
    }

    /// Restricts debugger stepping pauses to a specific logical BASIC task.
    public func setTargetTaskID(_ taskID: Int?) {
        lock.lock()
        targetTaskID = taskID
        lock.unlock()
    }

    /// Suppresses one breakpoint stop at a matching location.
    public func ignoreBreakpointOnce(at location: BASICBreakpointLocation?) {
        lock.lock()
        ignoredBreakpointLocation = location
        lock.unlock()
    }

    func update(lineNumber: Int?, location: BASICBreakpointLocation) {
        lock.lock()
        currentLineNumber = lineNumber
        currentLocation = location
        lock.unlock()
    }

    func checkBreak() throws {
        lock.lock()
        let shouldBreak = breakRequested
        let line = currentLineNumber
        var matchedBreakpoint: BASICBreakpointLocation?
        if let currentLocation, let breakpoint = breakpoints.first(where: { $0.matches(currentLocation) }) {
            if ignoredBreakpointLocation?.matches(currentLocation) == true {
                ignoredBreakpointLocation = nil
            } else {
                matchedBreakpoint = breakpoint
            }
        }
        lock.unlock()
        if shouldBreak {
            throw BASICError.breakRequested(line)
        }
        if let matchedBreakpoint {
            throw BASICError.breakpoint(matchedBreakpoint)
        }
    }

    func shouldPauseAfterStep(callDepth: Int, taskID: Int?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let targetTaskID, targetTaskID != taskID {
            return false
        }
        switch mode {
        case .run:
            return false
        case .stepInto:
            return true
        case .stepOver(let depth):
            return callDepth <= depth
        case .stepOut(let depth):
            return callDepth <= max(0, depth - 1)
        }
    }
}

/// Execution state for a logical BASIC task.
public enum BASICTaskState: String, Sendable {
    /// The task is queued and ready to run.
    case ready
    /// The task is currently executing.
    case running
    /// The task is paused at a debugger stop or future suspension point.
    case suspended
    /// The task reached normal completion.
    case completed
    /// The task stopped because cancellation or break was requested.
    case cancelled
    /// The task stopped with an error.
    case failed
}

/// Reason a logical BASIC task is suspended.
public enum BASICTaskSuspensionReason: Equatable, Sendable {
    /// The task stopped at a debugger boundary.
    case debugger
    /// The task is waiting for a host operation such as file, timer, or network work.
    case hostOperation(String)
    /// The task is waiting for another task to finish.
    case join(taskID: Int)
}

/// Resumable BASIC execution frame captured while a logical task is suspended.
public struct BASICSuspendedFrame: Equatable, Sendable {
    /// Human-readable frame kind, such as Program, Function, Method, or GOSUB.
    public let kind: String
    /// Human-readable frame name.
    public let name: String
    /// Source location where execution should resume.
    public let resumeLocation: BASICBreakpointLocation?
    /// Number of local scopes owned by this frame when it was captured.
    public let localScopeDepth: Int
    /// Local variable snapshot for this frame at the suspension point.
    public let localVariables: [BASICVariableSnapshot]

    /// Creates a suspended frame snapshot.
    public init(
        kind: String,
        name: String,
        resumeLocation: BASICBreakpointLocation? = nil,
        localScopeDepth: Int = 0,
        localVariables: [BASICVariableSnapshot] = []
    ) {
        self.kind = kind
        self.name = name
        self.resumeLocation = resumeLocation
        self.localScopeDepth = localScopeDepth
        self.localVariables = localVariables
    }
}

/// Immutable debugger-facing view of a logical BASIC task.
public struct BASICTaskSnapshot: Identifiable, Equatable, Sendable {
    /// Stable task identifier.
    public let id: Int
    /// Optional parent task identifier for future child tasks.
    public let parentID: Int?
    /// Human-readable task name.
    public let name: String
    /// Current task state.
    public let state: BASICTaskState
    /// Current suspension reason when the task is suspended.
    public let suspensionReason: BASICTaskSuspensionReason?
    /// Current source location, when execution has reached a statement.
    public let location: BASICBreakpointLocation?
    /// Whether cancellation has been requested.
    public let isCancellationRequested: Bool
    /// Number of cooperative yield boundaries reached by this task.
    public let yieldCount: Int
    /// Number of known child tasks parented by this task.
    public let childCount: Int
    /// Number of tasks currently waiting for this task to finish.
    public let waiterCount: Int
    /// Resumable BASIC frames captured while the task is suspended.
    public let suspendedFrames: [BASICSuspendedFrame]
    /// Global variable snapshot captured while the task is suspended.
    public let suspendedGlobalVariables: [BASICVariableSnapshot]
    /// User-facing summary of the result value for completed tasks.
    public let resultDescription: String?
    /// Result value for completed tasks, when available.
    let resultValue: BASICValue?
    /// Optional error text for failed tasks.
    public let errorDescription: String?
}

/// Nonblocking join classification for a logical BASIC task.
public enum BASICTaskJoinState: Equatable, Sendable {
    /// No task with that id is known.
    case missing
    /// The task is not finished yet.
    case waiting
    /// The task reached normal completion.
    case completed
    /// The task was cancelled.
    case cancelled
    /// The task stopped with an error.
    case failed(String?)
}

/// Nonblocking await classification for a logical BASIC task.
enum BASICTaskAwaitState: Equatable, Sendable {
    /// No task with that id is known.
    case missing
    /// The task is not finished yet.
    case waiting
    /// The task completed with a BASIC value.
    case completed(BASICValue)
    /// The task was cancelled.
    case cancelled
    /// The task stopped with an error.
    case failed(String?)
}

/// Host-side work closure used by the async/thread runtime seed.
public typealias BASICTaskHostOperation = @Sendable () async throws -> Void

/// Host-side work closure that completes a logical task with a BASIC value.
typealias BASICTaskHostResultOperation = @Sendable () async throws -> BASICValue

/// Stable user/runtime handle for a logical BASIC task.
public struct BASICTaskHandle: Identifiable, Equatable, Sendable {
    /// Stable task identifier.
    public let id: Int
    /// Optional parent task identifier for future child tasks.
    public let parentID: Int?
    /// Human-readable task name.
    public let name: String

    /// Creates a task handle.
    public init(id: Int, parentID: Int? = nil, name: String) {
        self.id = id
        self.parentID = parentID
        self.name = name
    }
}

/// Logical BASIC execution unit used by the future thread/async runtime.
public final class BASICTask: @unchecked Sendable {
    private let lock = NSLock()
    private var currentState: BASICTaskState = .ready
    private var currentLocation: BASICBreakpointLocation?
    private var cancellationRequested = false
    private var yieldCountValue = 0
    private var suspensionReason: BASICTaskSuspensionReason?
    private var suspendedFrames: [BASICSuspendedFrame] = []
    private var suspendedGlobalVariables: [BASICVariableSnapshot] = []
    private var resultValue: BASICValue?
    private var errorDescription: String?

    /// Stable task identifier.
    public let id: Int
    /// Optional parent task identifier for future child tasks.
    public let parentID: Int?
    /// Human-readable task name.
    public let name: String

    /// Creates a logical BASIC task.
    public init(id: Int, parentID: Int? = nil, name: String = "Program") {
        self.id = id
        self.parentID = parentID
        self.name = name
    }

    /// Current task state.
    public var state: BASICTaskState {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    /// Current source location, when available.
    public var location: BASICBreakpointLocation? {
        lock.lock()
        defer { lock.unlock() }
        return currentLocation
    }

    /// Stable handle for addressing this task without exposing mutable internals.
    public var handle: BASICTaskHandle {
        BASICTaskHandle(id: id, parentID: parentID, name: name)
    }

    /// Requests cancellation at the next cooperative execution check.
    public func requestCancellation() {
        lock.lock()
        cancellationRequested = true
        lock.unlock()
    }

    /// Whether cancellation has been requested.
    public var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    /// Returns an immutable task snapshot.
    public func snapshot(childCount: Int = 0, waiterCount: Int = 0) -> BASICTaskSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return BASICTaskSnapshot(
            id: id,
            parentID: parentID,
            name: name,
            state: currentState,
            suspensionReason: suspensionReason,
            location: currentLocation,
            isCancellationRequested: cancellationRequested,
            yieldCount: yieldCountValue,
            childCount: childCount,
            waiterCount: waiterCount,
            suspendedFrames: suspendedFrames,
            suspendedGlobalVariables: suspendedGlobalVariables,
            resultDescription: resultValue?.description,
            resultValue: resultValue,
            errorDescription: errorDescription
        )
    }

    func markRunning() {
        lock.lock()
        currentState = .running
        suspensionReason = nil
        suspendedFrames = []
        suspendedGlobalVariables = []
        resultValue = nil
        errorDescription = nil
        lock.unlock()
    }

    func markReady() {
        lock.lock()
        currentState = .ready
        suspensionReason = nil
        suspendedFrames = []
        suspendedGlobalVariables = []
        resultValue = nil
        lock.unlock()
    }

    func update(location: BASICBreakpointLocation) {
        lock.lock()
        currentLocation = location
        lock.unlock()
    }

    func recordYield() {
        lock.lock()
        yieldCountValue += 1
        lock.unlock()
    }

    func markSuspended(
        _ reason: BASICTaskSuspensionReason = .debugger,
        frames: [BASICSuspendedFrame] = [],
        globalVariables: [BASICVariableSnapshot] = []
    ) {
        lock.lock()
        currentState = .suspended
        suspensionReason = reason
        suspendedFrames = frames
        suspendedGlobalVariables = globalVariables
        lock.unlock()
    }

    func markCompleted(result: BASICValue? = nil) {
        lock.lock()
        currentState = .completed
        suspensionReason = nil
        suspendedFrames = []
        suspendedGlobalVariables = []
        resultValue = result
        lock.unlock()
    }

    func markCancelled() {
        lock.lock()
        currentState = .cancelled
        suspensionReason = nil
        suspendedFrames = []
        suspendedGlobalVariables = []
        resultValue = nil
        lock.unlock()
    }

    func markFailed(_ error: Error) {
        markFailed(message: String(describing: error))
    }

    func markFailed(message: String) {
        lock.lock()
        currentState = .failed
        suspensionReason = nil
        suspendedFrames = []
        suspendedGlobalVariables = []
        resultValue = nil
        errorDescription = message
        lock.unlock()
    }
}

/// Cooperative task registry and scheduler seed for BASIC execution.
public final class BASICTaskScheduler: @unchecked Sendable {
    private enum HostCompletion: Sendable {
        case success(BASICValue)
        case cancelled
        case failure(String)
    }

    private let lock = NSLock()
    private let completionEventLoop: BASICEventLoop?
    private var nextID = 1
    private var tasks: [Int: BASICTask] = [:]
    private var readyQueue: [Int] = []
    private var hostTasks: [Int: Task<Void, Never>] = [:]
    private var awaitersByTaskID: [Int: Set<Int>] = [:]
    private var currentTaskID: Int?

    /// Creates an empty task scheduler.
    public init(completionEventLoop: BASICEventLoop? = nil) {
        self.completionEventLoop = completionEventLoop
    }

    /// Creates and queues a logical BASIC task.
    public func createTask(name: String = "Program", parentID: Int? = nil) -> BASICTask {
        lock.lock()
        defer { lock.unlock() }
        let task = BASICTask(id: nextID, parentID: parentID, name: name)
        nextID += 1
        tasks[task.id] = task
        readyQueue.append(task.id)
        return task
    }

    /// Returns immutable snapshots for all known tasks.
    public var snapshots: [BASICTaskSnapshot] {
        drainCompletionCallbacks()
        lock.lock()
        let ordered = tasks.values.sorted { $0.id < $1.id }
        let childCounts = Dictionary(grouping: tasks.values.compactMap(\.parentID), by: { $0 })
            .mapValues(\.count)
        let waiterCounts = awaitersByTaskID.mapValues(\.count)
        lock.unlock()
        return ordered.map { task in
            task.snapshot(
                childCount: childCounts[task.id] ?? 0,
                waiterCount: waiterCounts[task.id] ?? 0
            )
        }
    }

    /// Current running or suspended task, when one has been selected.
    public var currentTask: BASICTask? {
        drainCompletionCallbacks()
        lock.lock()
        defer { lock.unlock() }
        guard let currentTaskID else { return nil }
        return tasks[currentTaskID]
    }

    /// Stable handles for tasks queued to run.
    public var readyTaskHandles: [BASICTaskHandle] {
        drainCompletionCallbacks()
        lock.lock()
        let queuedIDs = readyQueue
        let queuedTasks = queuedIDs.compactMap { tasks[$0] }
        lock.unlock()
        return queuedTasks.map(\.handle)
    }

    /// Returns a stable handle for a known task id.
    public func handle(for id: Int) -> BASICTaskHandle? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[id]?.handle
    }

    /// Creates a child logical task and returns its stable handle.
    public func createChildTask(name: String, parentID: Int) -> BASICTaskHandle {
        createTask(name: name, parentID: parentID).handle
    }

    /// Returns the nonblocking join state for a task id.
    public func joinState(for id: Int) -> BASICTaskJoinState {
        drainCompletionCallbacks()
        lock.lock()
        let task = tasks[id]
        lock.unlock()
        guard let task else { return .missing }
        let snapshot = task.snapshot()
        if snapshot.isCancellationRequested {
            return .cancelled
        }
        switch snapshot.state {
        case .ready, .running, .suspended:
            return .waiting
        case .completed:
            return .completed
        case .cancelled:
            return .cancelled
        case .failed:
            return .failed(snapshot.errorDescription)
        }
    }

    /// Returns the nonblocking await state and result value for a task id.
    func awaitState(for id: Int) -> BASICTaskAwaitState {
        drainCompletionCallbacks()
        lock.lock()
        let task = tasks[id]
        lock.unlock()
        guard let task else { return .missing }
        let snapshot = task.snapshot()
        if snapshot.isCancellationRequested {
            return .cancelled
        }
        switch snapshot.state {
        case .ready, .running, .suspended:
            return .waiting
        case .completed:
            return .completed(snapshot.resultValue ?? .empty)
        case .cancelled:
            return .cancelled
        case .failed:
            return .failed(snapshot.errorDescription)
        }
    }

    /// Requests cooperative cancellation for a known task.
    @discardableResult
    public func requestCancellation(id: Int) -> Bool {
        lock.lock()
        let task = tasks[id]
        let hostTask = hostTasks[id]
        lock.unlock()
        guard let task else { return false }
        task.requestCancellation()
        hostTask?.cancel()
        wakeAwaiters(for: id)
        return true
    }

    /// Starts a host-backed asynchronous operation represented as a logical BASIC task.
    public func startHostOperationTask(
        name: String,
        parentID: Int? = nil,
        operation: String,
        work: @escaping BASICTaskHostOperation
    ) -> BASICTaskHandle {
        startHostOperationTaskWithResult(name: name, parentID: parentID, operation: operation) {
            try await work()
            return .empty
        }
    }

    /// Starts a host-backed asynchronous operation that returns a BASIC value.
    func startHostOperationTaskWithResult(
        name: String,
        parentID: Int? = nil,
        operation: String,
        work: @escaping BASICTaskHostResultOperation
    ) -> BASICTaskHandle {
        let task = createTask(name: name, parentID: parentID)
        _ = suspendForHostOperation(id: task.id, operation: operation)
        let handle = task.handle
        let swiftTask = Task.detached { [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await work()
                try Task.checkCancellation()
                self?.completeHostOperationTask(id: handle.id, completion: .success(result))
            } catch is CancellationError {
                self?.completeHostOperationTask(id: handle.id, completion: .cancelled)
            } catch {
                self?.completeHostOperationTask(id: handle.id, completion: .failure(String(describing: error)))
            }
        }
        lock.lock()
        hostTasks[handle.id] = swiftTask
        lock.unlock()
        return handle
    }

    /// Suspends a task while a host operation runs outside the interpreter.
    @discardableResult
    public func suspendForHostOperation(id: Int, operation: String) -> Bool {
        lock.lock()
        let task = tasks[id]
        readyQueue.removeAll { $0 == id }
        lock.unlock()
        guard let task else { return false }
        task.markSuspended(.hostOperation(operation))
        return true
    }

    /// Suspends a task while it awaits another logical task.
    @discardableResult
    public func suspendForAwait(id: Int, awaitingTaskID: Int, frame: BASICSuspendedFrame) -> Bool {
        suspendForAwait(id: id, awaitingTaskID: awaitingTaskID, frames: [frame])
    }

    /// Suspends a task while it awaits another logical task and captures its resumable stack.
    @discardableResult
    public func suspendForAwait(
        id: Int,
        awaitingTaskID: Int,
        frames: [BASICSuspendedFrame],
        globalVariables: [BASICVariableSnapshot] = []
    ) -> Bool {
        lock.lock()
        let task = tasks[id]
        let awaitedTask = tasks[awaitingTaskID]
        readyQueue.removeAll { $0 == id }
        if task != nil, awaitedTask != nil {
            awaitersByTaskID[awaitingTaskID, default: []].insert(id)
        }
        lock.unlock()
        guard let task, let awaitedTask else { return false }
        let awaitedSnapshot = awaitedTask.snapshot()
        guard awaitedSnapshot.state == .ready || awaitedSnapshot.state == .running || awaitedSnapshot.state == .suspended else {
            lock.lock()
            awaitersByTaskID[awaitingTaskID]?.remove(id)
            lock.unlock()
            return false
        }
        task.markSuspended(.join(taskID: awaitingTaskID), frames: frames, globalVariables: globalVariables)
        return true
    }

    /// Moves a suspended task back to the ready queue after its wait condition is satisfied.
    @discardableResult
    public func resumeTask(id: Int) -> Bool {
        lock.lock()
        guard let task = tasks[id] else {
            lock.unlock()
            return false
        }
        let isAlreadyQueued = readyQueue.contains(id)
        lock.unlock()

        let snapshot = task.snapshot()
        guard snapshot.state == .suspended, !snapshot.isCancellationRequested else {
            return false
        }

        task.markReady()
        lock.lock()
        removeAwaiter(id)
        if !isAlreadyQueued {
            readyQueue.append(id)
        }
        lock.unlock()
        return true
    }

    func markRunning(_ task: BASICTask) {
        lock.lock()
        currentTaskID = task.id
        readyQueue.removeAll { $0 == task.id }
        lock.unlock()
        task.markRunning()
    }

    func markSuspended(_ task: BASICTask, reason: BASICTaskSuspensionReason = .debugger) {
        task.markSuspended(reason)
    }

    func markCompleted(_ task: BASICTask) {
        task.markCompleted()
        wakeAwaiters(for: task.id)
    }

    func markCancelled(_ task: BASICTask) {
        task.markCancelled()
        wakeAwaiters(for: task.id)
    }

    func markFailed(_ task: BASICTask, error: Error) {
        task.markFailed(error)
        wakeAwaiters(for: task.id)
    }

    private func drainCompletionCallbacks() {
        guard completionEventLoop?.hasPendingError != true else { return }
        _ = completionEventLoop?.runUntilIdle(limit: 64)
    }

    private func completeHostOperationTask(id: Int, completion: HostCompletion) {
        guard let completionEventLoop else {
            finishHostOperationTask(id: id, completion: completion)
            return
        }
        completionEventLoop.post { [weak self] in
            self?.finishHostOperationTask(id: id, completion: completion)
        }
    }

    private func finishHostOperationTask(id: Int, completion: HostCompletion) {
        lock.lock()
        let task = tasks[id]
        hostTasks[id] = nil
        lock.unlock()
        guard let task else { return }
        if task.isCancellationRequested {
            task.markCancelled()
        } else {
            switch completion {
            case .success(let result):
                task.markCompleted(result: result)
            case .cancelled:
                task.markCancelled()
            case .failure(let message):
                task.markFailed(message: message)
            }
        }
        wakeAwaiters(for: id)
    }

    private func removeAwaiter(_ taskID: Int) {
        for awaitedID in awaitersByTaskID.keys {
            awaitersByTaskID[awaitedID]?.remove(taskID)
            if awaitersByTaskID[awaitedID]?.isEmpty == true {
                awaitersByTaskID[awaitedID] = nil
            }
        }
    }

    private func wakeAwaiters(for taskID: Int) {
        lock.lock()
        let waiterIDs = Array(awaitersByTaskID[taskID] ?? [])
        awaitersByTaskID[taskID] = nil
        let waiters = waiterIDs.compactMap { tasks[$0] }
        lock.unlock()

        for waiter in waiters {
            let snapshot = waiter.snapshot()
            guard snapshot.state == .suspended,
                  snapshot.suspensionReason == .join(taskID: taskID),
                  !snapshot.isCancellationRequested else {
                continue
            }
            waiter.markReady()
            lock.lock()
            if !readyQueue.contains(waiter.id) {
                readyQueue.append(waiter.id)
            }
            lock.unlock()
        }
    }
}

/// Result reported when a BASIC program submitted to a worker lane finishes.
public enum BASICWorkerLaneRunResult: Equatable, Sendable {
    /// The submitted program completed normally.
    case success
    /// The submitted program failed, broke, or stopped with a user-visible error.
    case failure(String)
}

/// Serialized execution lane for running BASIC work away from a caller thread.
public final class BASICWorkerLane: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var running = false

    /// Creates a worker lane backed by a serial dispatch queue.
    public init(label: String = "AIBasic.BASICWorkerLane") {
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// True while a submitted operation is active on the lane.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Submits one operation to the lane, returning false if another operation is active.
    @discardableResult
    public func submit(_ operation: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard !running else {
            lock.unlock()
            return false
        }
        running = true
        lock.unlock()

        queue.async { [weak self] in
            operation()
            self?.finishOperation()
        }
        return true
    }

    private func finishOperation() {
        lock.lock()
        running = false
        lock.unlock()
    }
}

final class BASICWorkerLaneResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<Void, Error>?

    func store(_ result: Result<Void, Error>) {
        lock.lock()
        storedResult = result
        lock.unlock()
    }

    var result: Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }
}

/// Thread-safe FIFO event loop for host callbacks that must re-enter a BASIC session at safe boundaries.
public final class BASICEventLoop: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [@Sendable () -> Void] = []
    private var pendingError: Error?
    private var isRunning = false

    /// Creates an empty event loop.
    public init() {}

    /// Number of callbacks waiting to run.
    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queue.count
    }

    /// Whether the loop has no pending callbacks.
    public var isEmpty: Bool {
        pendingCount == 0
    }

    /// Whether a callback has reported an error that must be rethrown at the next safe point.
    public var hasPendingError: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingError != nil
    }

    /// Adds a callback to the tail of the event queue.
    public func post(_ operation: @escaping @Sendable () -> Void) {
        lock.lock()
        queue.append(operation)
        lock.unlock()
    }

    /// Records an error raised by a callback so the interpreter can rethrow it at
    /// the safe point that drained the event queue.
    public func reportError(_ error: Error) {
        lock.lock()
        if pendingError == nil {
            pendingError = error
        }
        lock.unlock()
    }

    /// Throws and clears the first callback error reported during event draining.
    public func throwPendingError() throws {
        lock.lock()
        let error = pendingError
        pendingError = nil
        lock.unlock()
        if let error {
            throw error
        }
    }

    /// Runs one pending callback, returning false when the queue is empty.
    @discardableResult
    public func runOne() -> Bool {
        let operation: (@Sendable () -> Void)?
        lock.lock()
        if pendingError != nil || queue.isEmpty {
            operation = nil
        } else {
            operation = queue.removeFirst()
        }
        lock.unlock()

        guard let operation else { return false }
        operation()
        return true
    }

    /// Runs callbacks already queued at the start of this drain pass.
    ///
    /// Callbacks posted by callbacks are intentionally left for a later safe point. This avoids
    /// host-event redraw paths recursively monopolizing the interpreter.
    @discardableResult
    public func runPending(limit: Int = .max) -> Int {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return 0
        }
        isRunning = true
        let budget = min(limit, queue.count)
        lock.unlock()

        defer {
            lock.lock()
            isRunning = false
            lock.unlock()
        }

        var count = 0
        while count < budget, runOne() {
            count += 1
        }
        return count
    }

    /// Runs pending callbacks until the queue is empty, including callbacks posted by callbacks.
    @discardableResult
    public func runUntilIdle(limit: Int = .max) -> Int {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return 0
        }
        isRunning = true
        lock.unlock()

        defer {
            lock.lock()
            isRunning = false
            lock.unlock()
        }

        var count = 0
        while count < limit, runOne() {
            count += 1
        }
        return count
    }
}
