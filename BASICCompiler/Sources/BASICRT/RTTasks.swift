import Foundation

// BASICRT tasks — ASYNC FUNCTION, AWAIT, JOIN, CANCEL, BACKGROUND, YIELD,
// ASYNCVALUE, SLEEP, TASKSTATUS$, TASKERROR$.
//
// The interpreter runs an async body on its own thread against a copy of
// the globals taken at launch. Its observable contract is what this
// keeps: a launch takes the next task id (the program is task 1) and a
// copy of every global; the body's writes never reach the caller; the
// caller's statements run before the body's output appears; AWAIT/JOIN
// return the result, or the body's failure as "Awaited task failed: …";
// a result dropped on the floor is an error; tasks never observed are
// warned about when the run ends. The body itself runs when it is first
// awaited or joined, with the snapshot installed as the globals and the
// caller's globals put back afterwards — the compiler emits the capture
// and restore functions for the module's globals and a trampoline per
// async function.

/// A trampoline: unboxes its arguments, runs the body inside an error
/// boundary, and returns the boxed result — or nil when the body failed.
typealias RTTaskTrampoline = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
typealias RTGlobalsCapture = @convention(c) () -> UnsafeMutableRawPointer?
typealias RTGlobalsRestore = @convention(c) (UnsafeMutableRawPointer?) -> Void

package final class RTTask {
    enum State: String { case ready = "READY", running = "RUNNING", suspended = "SUSPENDED", completed = "COMPLETED", cancelled = "CANCELLED", failed = "FAILED" }

    let id: Int
    let name: String
    let parentID: Int
    var state: State
    var trampoline: RTTaskTrampoline?
    /// The boxed arguments, one per parameter.
    var arguments: RTArray?
    /// The globals at launch.
    var snapshot: UnsafeMutableRawPointer?
    var result: RTValue = .empty
    var error: String?
    var observed = false
    var background = false
    var sleepMilliseconds: Int?

    init(id: Int, name: String, parentID: Int, state: State) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.state = state
    }
}

enum RTTasks {
    /// The program is task 1.
    nonisolated(unsafe) static var nextID = 2
    nonisolated(unsafe) static var tasks: [RTTask] = []
    nonisolated(unsafe) static var currentTaskID = 1
    nonisolated(unsafe) static var capture: RTGlobalsCapture?
    nonisolated(unsafe) static var restore: RTGlobalsRestore?
    /// Error boundaries of the bodies being run, innermost last.
    nonisolated(unsafe) static var boundaries: [UnsafeMutableRawPointer] = []
    /// The failure the innermost boundary caught.
    nonisolated(unsafe) static var boundaryError: String?

    static func create(name: String, state: RTTask.State) -> RTTask {
        let task = RTTask(id: nextID, name: name, parentID: currentTaskID, state: state)
        nextID += 1
        tasks.append(task)
        return task
    }

    static func task(_ pointer: UnsafeMutableRawPointer?, _ what: String) -> RTTask {
        guard case .task(let task) = rtValue(pointer) else { basic_rt_fail("\(what) requires a known task handle") }
        return task
    }

    /// Runs a body that has not run yet, against its launch-time globals.
    static func run(_ task: RTTask) {
        guard task.state == .running || task.state == .ready else { return }
        if let milliseconds = task.sleepMilliseconds {
            if milliseconds > 0 { usleep(UInt32(min(milliseconds, 1_000_000)) * 1000) }
            task.result = .number(Double(milliseconds))
            task.state = .completed
            return
        }
        guard let trampoline = task.trampoline else { task.state = .completed; return }
        let live = capture?()
        if let snapshot = task.snapshot { restore?(snapshot) }
        let outerTask = currentTaskID
        currentTaskID = task.id
        let argumentsPointer = task.arguments.map { Unmanaged.passUnretained($0).toOpaque() }
        let produced = trampoline(argumentsPointer)
        currentTaskID = outerTask
        if let live {
            restore?(live)
            basic_rt_snapshot_release(live)
        }
        if let produced {
            task.result = rtValue(produced)
            basic_rt_value_release(produced)
            task.state = .completed
        } else {
            task.error = boundaryError
            boundaryError = nil
            task.state = .failed
        }
    }

    /// The end-of-run report for the program's tasks nobody looked at.
    static func finish() {
        for task in tasks where task.parentID == 1 && !task.observed && !task.background {
            let prefix = "Warning: task #\(task.id) \(task.name)"
            switch task.state {
            case .failed: RTConsole.write("\(prefix) failed without being awaited: \(task.error ?? "")\n")
            case .cancelled: RTConsole.write("\(prefix) was cancelled without being observed\n")
            case .completed: RTConsole.write("\(prefix) completed without being awaited\n")
            default: RTConsole.write("\(prefix) is still running; use AWAIT, JOIN, CANCEL, or BACKGROUND\n")
            }
        }
    }
}

// MARK: - Snapshots (arrays of boxed values)

@_cdecl("basic_rt_snapshot_new")
public func basic_rt_snapshot_new(_ count: Int) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(RTArray(upperBounds: [max(0, count - 1)], isDynamic: false, element: .variant, values: Array(repeating: .empty, count: count))).toOpaque()
}

@_cdecl("basic_rt_snapshot_set")
public func basic_rt_snapshot_set(_ pointer: UnsafeMutableRawPointer, _ index: Int, _ value: UnsafeMutableRawPointer?) {
    rtArray(pointer).values[index] = rtValue(value).copied()
}

/// Owned box.
@_cdecl("basic_rt_snapshot_get")
public func basic_rt_snapshot_get(_ pointer: UnsafeMutableRawPointer, _ index: Int) -> UnsafeMutableRawPointer {
    rtOwned(rtArray(pointer).values[index].copied())
}

@_cdecl("basic_rt_snapshot_release")
public func basic_rt_snapshot_release(_ pointer: UnsafeMutableRawPointer?) {
    basic_rt_array_release(pointer)
}

/// The array a boxed value holds, as an owned copy (restoring an array global).
@_cdecl("basic_rt_value_array_copy")
public func basic_rt_value_array_copy(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard case .array(let array) = rtValue(pointer) else { return nil }
    return Unmanaged.passRetained(array.copy()).toOpaque()
}

// MARK: - The ABI

@_cdecl("basic_rt_tasks_install")
public func basic_rt_tasks_install(_ capture: UnsafeMutableRawPointer, _ restore: UnsafeMutableRawPointer) {
    RTTasks.capture = unsafeBitCast(capture, to: RTGlobalsCapture.self)
    RTTasks.restore = unsafeBitCast(restore, to: RTGlobalsRestore.self)
}

/// Launches an async function: takes the next id and a copy of the
/// globals; the body runs when awaited. Owned task box.
@_cdecl("basic_rt_task_launch")
public func basic_rt_task_launch(_ name: UnsafePointer<CChar>, _ trampoline: UnsafeMutableRawPointer, _ arguments: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    let task = RTTasks.create(name: String(cString: name), state: .running)
    task.trampoline = unsafeBitCast(trampoline, to: RTTaskTrampoline.self)
    task.arguments = arguments.map { rtArray($0) }
    task.snapshot = RTTasks.capture?()
    return rtOwned(.task(task))
}

/// `ASYNCVALUE(x)`: a task already holding its value.
@_cdecl("basic_rt_task_value")
public func basic_rt_task_value(_ value: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    let task = RTTasks.create(name: "ASYNCVALUE", state: .completed)
    task.result = rtValue(value).copied()
    return rtOwned(.task(task))
}

/// `SLEEP(ms)`: a task that sleeps when awaited and yields the milliseconds.
@_cdecl("basic_rt_task_sleep")
public func basic_rt_task_sleep(_ milliseconds: Double) -> UnsafeMutableRawPointer {
    let task = RTTasks.create(name: "SLEEP", state: .running)
    task.sleepMilliseconds = max(0, Int(milliseconds.rounded()))
    return rtOwned(.task(task))
}

/// `AWAIT`: the task's result, running the body first when needed; a
/// non-task value passes through. Owned box.
@_cdecl("basic_rt_task_await")
public func basic_rt_task_await(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    guard case .task(let task) = rtValue(pointer) else { return basic_rt_value_copy(pointer) }
    task.observed = true
    RTTasks.run(task)
    switch task.state {
    case .cancelled: basic_rt_fail("Awaited task was cancelled")
    case .failed: basic_rt_fail(task.error.map { "Awaited task failed: \($0)" } ?? "Awaited task failed")
    default: return rtOwned(task.result.copied())
    }
}

@_cdecl("basic_rt_task_join")
public func basic_rt_task_join(_ pointer: UnsafeMutableRawPointer?) {
    let task = RTTasks.task(pointer, "JOIN")
    task.observed = true
    RTTasks.run(task)
    switch task.state {
    case .cancelled: basic_rt_fail("Joined task was cancelled")
    case .failed: basic_rt_fail(task.error.map { "Joined task failed: \($0)" } ?? "Joined task failed")
    default: break
    }
}

@_cdecl("basic_rt_task_cancel")
public func basic_rt_task_cancel(_ pointer: UnsafeMutableRawPointer?) {
    let task = RTTasks.task(pointer, "CANCEL")
    task.observed = true
    if task.state == .running || task.state == .ready || task.state == .suspended { task.state = .cancelled }
}

@_cdecl("basic_rt_task_background")
public func basic_rt_task_background(_ pointer: UnsafeMutableRawPointer?) {
    guard case .task(let task) = rtValue(pointer) else { basic_rt_fail("BACKGROUND requires an async task") }
    task.observed = true
    task.background = true
}

/// A task produced by a statement and dropped: the interpreter's error.
@_cdecl("basic_rt_task_discard")
public func basic_rt_task_discard(_ pointer: UnsafeMutableRawPointer?) {
    guard case .task(let task) = rtValue(pointer) else { return }
    task.state = .cancelled
    basic_rt_fail("Task result was ignored; use AWAIT, assign it to a TASK variable, or launch it with BACKGROUND")
}

@_cdecl("basic_rt_task_status")
public func basic_rt_task_status(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    let task = RTTasks.task(pointer, "TASKSTATUS$")
    task.observed = true
    return rtOwned(task.state.rawValue)
}

@_cdecl("basic_rt_task_error")
public func basic_rt_task_error(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    let task = RTTasks.task(pointer, "TASKERROR$")
    task.observed = true
    return rtOwned(task.error ?? "")
}

/// A trampoline enters its error boundary before running the body.
@_cdecl("basic_rt_task_boundary_push")
public func basic_rt_task_boundary_push(_ jumpBuffer: UnsafeMutableRawPointer) {
    RTTasks.boundaries.append(jumpBuffer)
}

@_cdecl("basic_rt_task_boundary_pop")
public func basic_rt_task_boundary_pop() {
    _ = RTTasks.boundaries.popLast()
}
