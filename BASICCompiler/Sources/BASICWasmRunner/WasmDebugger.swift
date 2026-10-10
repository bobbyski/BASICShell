#if canImport(JavaScriptCore)
import BASICCore
import BASICRT
import BASICWasm
import Foundation

// A debugger for a run of a module translated with `debug: true` (BASIC-46).
//
// The module calls `__debug(statement, function, frame)` as each statement
// starts, and the runner hands the call here, on the run's own thread. A
// breakpoint, a finished step or Pause stops the run right there: the thread
// waits, which is safe because JavaScriptCore runs the module synchronously
// on it, and the host is told where the run is and what its variables hold.
// Continue, a step, or Stop lets it go on.
//
// The call stack comes from the frames' addresses. The stack grows down, so
// a frame below the current one is a call it made; a frame that is gone (it
// returned, or an error unwound it) is dropped as soon as a statement of an
// outer frame runs.

/// Breakpoints, stepping, Pause, and what a stopped WebAssembly run holds.
public final class WasmDebugger: @unchecked Sendable {
    /// How a stopped run goes on.
    public enum Command: Sendable, Equatable {
        /// To the next breakpoint, or the end.
        case run
        /// To the next statement, wherever it is.
        case stepInto
        /// To the next statement of this call or the one that made it.
        case stepOver
        /// To the next statement of the call that made this one.
        case stepOut
    }

    /// Where a run stopped, and what it holds there.
    public struct Pause: Sendable {
        public let location: BASICBreakpointLocation
        /// The text of the line it stopped on.
        public let source: String
        /// Innermost first; the program's own code last.
        public let callStack: [BASICCallStackFrame]
        /// Each frame's locals, in `callStack`'s order; the program's are none.
        public let frameLocals: [[BASICVariableSnapshot]]
        public let globals: [BASICVariableSnapshot]
    }

    /// Called on the run's thread when it stops. The run waits until
    /// `resume`, or Stop.
    public var onPause: ((Pause) -> Void)?
    /// How the program spells its names, by their uppercased form: basicc
    /// keeps only the uppercased one. A name not here is shown as it is.
    public var spellings: [String: String] = [:]
    /// The editor's line for each line of the text that was compiled, when
    /// the two differ (an editor leaves out blank lines): breakpoints are
    /// given, and stops reported, in the editor's lines.
    public var editorLines: [Int?]?

    private enum Mode { case run, stepInto, stepOver(depth: Int), stepOut(depth: Int) }

    // Set from any thread, under the lock.
    private let condition = NSCondition()
    private var breakpoints: [BASICBreakpointLocation] = []
    private var programLines: [String]?
    private var mode: Mode
    private var pauseRequested = false
    private var resumeCommand: Command?
    private var cancelled = false
    private var waiting = false

    // The run's own, on its thread.
    private var info: WasmDebugInfo?
    private var base: UnsafeMutableRawPointer?
    private var frames: [(function: Int, frame: Int, statement: Int)] = []
    private var lastLine: (line: Int, frame: Int)?

    /// A debugger that starts the run with `command`: `.run` until a
    /// breakpoint, `.stepInto` to stop at the first statement.
    public init(command: Command = .run) {
        mode = command == .stepInto ? .stepInto : .run
    }

    /// Where to stop. `programLines`, when given, is the text the editor ran:
    /// a breakpoint stops only a statement whose line reads the same, so a
    /// file it imports cannot stop at the same line number.
    public func setBreakpoints(_ locations: [BASICBreakpointLocation], programLines: [String]? = nil) {
        condition.lock()
        breakpoints = locations
        self.programLines = programLines
        condition.unlock()
    }

    /// Stops the run at its next statement.
    public func pause() {
        condition.lock()
        pauseRequested = true
        condition.unlock()
    }

    /// Whether the run is stopped, waiting for `resume`.
    public var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return waiting
    }

    /// Lets a stopped run go on.
    public func resume(_ command: Command) {
        condition.lock()
        resumeCommand = command
        condition.signal()
        condition.unlock()
    }

    /// Stop: a stopped run wakes, and ends.
    func cancel() {
        condition.lock()
        cancelled = true
        condition.signal()
        condition.unlock()
    }

    /// The start of a run: its table, and its memory's address.
    func begin(info: WasmDebugInfo?, base: UnsafeMutableRawPointer) {
        self.info = info
        self.base = base
        frames = []
        lastLine = nil
    }

    /// A statement is starting. False when the run must end: Stop.
    func statement(_ index: Int, function: Int, frame: Int) -> Bool {
        // Frames below this one have returned; one at it is this call.
        while let last = frames.last, last.frame < frame { frames.removeLast() }
        if let last = frames.last, last.frame == frame {
            frames[frames.count - 1] = (function, frame, index)
        } else {
            frames.append((function, frame, index))
        }
        let depth = frames.count
        let location = self.location(of: index)
        let line = (line: location.lineNumber, frame: frame)
        defer { lastLine = line }

        condition.lock()
        if cancelled {
            condition.unlock()
            return false
        }
        var stop = pauseRequested
        switch mode {
        case .run: break
        case .stepInto: stop = true
        case .stepOver(let at): stop = stop || depth <= at
        case .stepOut(let at): stop = stop || depth < at
        }
        // A breakpoint stops a line as the run comes to it, not again at
        // each statement after the first.
        if !stop, lastLine.map({ $0 != line }) ?? true,
           breakpoints.contains(where: { $0.matches(location) }), reads(index, as: location.lineNumber) {
            stop = true
        }
        guard stop else {
            condition.unlock()
            return true
        }
        pauseRequested = false
        resumeCommand = nil
        waiting = true
        condition.unlock()

        onPause?(snapshot(at: index, location: location))

        condition.lock()
        while resumeCommand == nil, !cancelled { condition.wait() }
        waiting = false
        let command = resumeCommand
        switch command {
        case .stepInto?: mode = .stepInto
        case .stepOver?: mode = .stepOver(depth: depth)
        case .stepOut?: mode = .stepOut(depth: depth)
        case .run?, nil: mode = .run
        }
        let ended = cancelled
        condition.unlock()
        return !ended
    }

    // MARK: Where, and what

    private func location(of index: Int) -> BASICBreakpointLocation {
        guard let statement = info?.statements[safe: index] else { return BASICBreakpointLocation(lineNumber: 0) }
        let line = editorLines.map { $0[safe: statement.line - 1].flatMap { $0 } ?? 0 } ?? statement.line
        return BASICBreakpointLocation(lineNumber: line, statementNumber: statement.indexOnLine)
    }

    /// Whether a statement is on the editor's line: the line reads the same.
    private func reads(_ index: Int, as line: Int) -> Bool {
        guard let programLines else { return true }
        guard let statement = info?.statements[safe: index], let text = programLines[safe: line - 1] else { return false }
        return statement.source.trimmingCharacters(in: .whitespaces) == text.trimmingCharacters(in: .whitespaces)
    }

    private func spelled(_ name: String) -> String { spellings[name] ?? name }

    private func snapshot(at index: Int, location: BASICBreakpointLocation) -> Pause {
        let source = info?.statements[safe: index]?.source ?? ""
        var callStack: [BASICCallStackFrame] = []
        var frameLocals: [[BASICVariableSnapshot]] = []
        for (position, entry) in frames.reversed().enumerated() {
            let function = info?.functions[safe: entry.function]
            let isProgram = function?.isProgram ?? false
            callStack.append(BASICCallStackFrame(
                index: position,
                kind: isProgram ? "Program" : "Function",
                name: isProgram ? "[main]" : spelled(function?.name ?? "?"),
                location: self.location(of: entry.statement)))
            let locals = isProgram ? [] : (function?.locals ?? []).map { variable in
                self.variable(variable, at: entry.frame + variable.offset, scope: .local)
            }
            frameLocals.append(locals.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        let globals = (info?.globals ?? []).map { variable($0, at: $0.offset, scope: .global) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Pause(location: location, source: source, callStack: callStack, frameLocals: frameLocals, globals: globals)
    }

    /// A variable's value, read from the module's memory at `address`.
    private func variable(_ variable: WasmDebugInfo.Variable, at address: Int, scope: BASICVariableScope) -> BASICVariableSnapshot {
        let name = spelled(variable.name)
        let value: RTDebugValue
        if let base {
            let place = base + address
            switch variable.storage {
            case .double:
                value = RTDebugValue(name: name, typeName: variable.typeName.isEmpty ? "DOUBLE" : variable.typeName,
                                     value: RTDebug.number(place.loadUnaligned(as: Double.self)))
            case .boolean:
                value = RTDebugValue(name: name, typeName: "BOOLEAN", value: place.load(as: UInt8.self) & 1 == 1 ? "TRUE" : "FALSE")
            case .int32:
                value = RTDebugValue(name: name, typeName: variable.typeName, value: String(place.loadUnaligned(as: Int32.self)))
            case .int64:
                value = RTDebugValue(name: name, typeName: variable.typeName, value: String(place.loadUnaligned(as: Int64.self)))
            case .pointer:
                let pointer = UnsafeMutableRawPointer(bitPattern: UInt(place.loadUnaligned(as: UInt64.self)))
                value = RTDebug.describe(name: name, typeName: variable.typeName, pointer: pointer)
            }
        } else {
            value = RTDebugValue(name: name, typeName: variable.typeName, value: "")
        }
        return Self.snapshot(value, scope: scope, path: "\(scope.rawValue):\(name)")
    }

    static func snapshot(_ value: RTDebugValue, scope: BASICVariableScope, path: String) -> BASICVariableSnapshot {
        BASICVariableSnapshot(
            path: path, name: value.name, typeName: value.typeName, value: value.value, scope: scope,
            children: value.children.map { child in
                let childPath: String
                if child.name.hasPrefix("(") {
                    childPath = path + child.name
                } else if child.name.hasPrefix("\"") {
                    childPath = path + "(" + child.name + ")"
                } else {
                    childPath = path + "." + child.name
                }
                return snapshot(child, scope: scope, path: childPath)
            })
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
