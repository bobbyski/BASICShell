import Foundation
#if canImport(Darwin)
import Darwin
#endif

private final class BASICTimerControlBlock: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let intervalMilliseconds: Int
    private let repeating: Bool
    private let fire: @Sendable (_ sequence: Int, _ intervalMilliseconds: Int) -> Void
    private var source: DispatchSourceTimer?
    private var sequence = 0
    private var isCancelled = false

    init(
        id: Int,
        intervalSeconds: Double,
        repeating: Bool,
        queue: DispatchQueue,
        fire: @escaping @Sendable (_ sequence: Int, _ intervalMilliseconds: Int) -> Void
    ) {
        self.queue = queue
        self.intervalMilliseconds = max(1, Int((intervalSeconds * 1000).rounded()))
        self.repeating = repeating
        self.fire = fire
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(intervalMilliseconds)
        let leeway = DispatchTimeInterval.milliseconds(min(50, max(1, intervalMilliseconds / 20)))
        timer.schedule(
            deadline: .now() + interval,
            repeating: repeating ? interval : .never,
            leeway: leeway
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let sequence: Int
            lock.lock()
            guard !isCancelled else {
                lock.unlock()
                return
            }
            self.sequence += 1
            sequence = self.sequence
            lock.unlock()

            fire(sequence, intervalMilliseconds)
            if !repeating {
                cancel()
            }
        }

        lock.lock()
        source = timer
        isCancelled = false
        sequence = 0
        lock.unlock()
        timer.resume()
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let timer = source
        source = nil
        lock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
    }
}

public final class BASICSession: BASICTimerHost, @unchecked Sendable {
    /// Default graphical prompt template used by BASICStudio.
    public static let defaultPromptTemplate = "\u{001B}[38;5;16;48;5;250m  \u{001B}[38;5;250;48;5;99m\u{001B}[38;5;15;48;5;99m  ${currentdir} \u{001B}[38;5;99;48;5;142m\u{001B}[38;5;16;48;5;142m git  ${gitstatus} \u{001B}[38;5;142;48;5;142m\u{001B}[38;5;16;48;5;142m !1 \u{001B}[38;5;142;48;5;40m\u{001B}[38;5;16;48;5;40m Ready \u{001B}[38;5;40;49m\u{001B}[0m "
    /// Plain text prompt template for hosts without powerline glyph support.
    public static let plainPromptTemplate = "${user}:${currentdir} ${gitstatus}> "
    /// Classic READY prompt template.
    public static let shellPromptTemplate = "READY%nl> "
    /// Legacy default prompt string.
    public static let defaultPrompt = "\(NSUserName()):~ > "
    /// Nerd-font prompt template for shell-style hosts.
    public static let nerdFontPromptTemplate = "    %cwd %gitSegment "

    /// Editable program associated with this session.
    public let program = BASICProgram()
    /// Template used to render prompts.
    public var promptTemplate: String
    /// Current rendered prompt.
    public var prompt: String {
        renderedPrompt()
    }

    private let host: BASICHost
    private let runtime = BASICRuntime()
    private let fileState = BASICFileState()
    private let taskScheduler: BASICTaskScheduler
    private var activeInterpreter: BASICInterpreter?
    /// Optional lane used by synchronous foreground RUN commands.
    public var foregroundRunLane: BASICWorkerLane?
    /// Optional execution control used by interactive foreground RUN commands.
    public var foregroundExecutionControl: BASICExecutionControl?
    /// When true, Ctrl-C-style break requests end a foreground shell run instead of preserving a paused debugger state.
    public var stopsForegroundProgramOnBreak = false
    /// Host callback queue for future async completions and Shell/Studio event-loop integration.
    public let eventLoop: BASICEventLoop
    private let hostEventLock = NSLock()
    private var pendingHostEvents: [BASICEventSelector: BASICValue] = [:]
    private var pendingHostEventOrder: [BASICEventSelector] = []
    private var isHostEventDrainQueued = false
    private let timerLock = NSLock()
    private let timerQueue = DispatchQueue(label: "AIBasic.BASICSession.Timers", qos: .utility)
    private var timerBlocks: [Int: BASICTimerControlBlock] = [:]

    /// Creates a session bound to a host.
    public init(host: BASICHost, promptTemplate: String = BASICSession.defaultPromptTemplate) {
        self.host = host
        self.promptTemplate = promptTemplate
        let eventLoop = BASICEventLoop()
        self.eventLoop = eventLoop
        self.taskScheduler = BASICTaskScheduler(completionEventLoop: eventLoop)
    }

    /// Event handlers registered by the current or most recent program run.
    public var eventHandlers: [BASICEventHandlerRegistration] {
        runtime.eventHandlerRegistrations
    }

    /// Submits one console line, returning false when the caller should exit.
    @discardableResult
    public func submit(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        if let numbered = Self.splitNumberedLine(trimmed) {
            program.setLine(number: numbered.number, source: numbered.source)
            return true
        }

        do {
            if let path = try Self.loadPath(from: trimmed) {
                guard let fileHost = host as? BASICFileHost else {
                    throw BASICError.runtime("LOAD is not supported by this host")
                }
                do {
                    program.loadSource(try fileHost.loadTextFile(path: path), fileName: path)
                    fileState.lastFilePath = path
                } catch {
                    throw BASICError.runtime("Could not load \(path): \(error.localizedDescription)")
                }
                return true
            }
            if let saveCommand = try Self.savePath(from: trimmed) {
                guard let fileHost = host as? BASICFileHost else {
                    throw BASICError.runtime("SAVE is not supported by this host")
                }
                guard let path = saveCommand ?? fileState.lastFilePath else {
                    throw BASICError.syntax("Expected path after SAVE")
                }
                do {
                    try fileHost.saveTextFile(path: path, text: program.listing())
                    fileState.lastFilePath = path
                } catch let error as BASICError {
                    throw error
                } catch {
                    throw BASICError.runtime("Could not save \(path): \(error.localizedDescription)")
                }
                return true
            }
            if let cdCommand = try Self.cdPath(from: trimmed) {
                guard let fileHost = host as? BASICFileHost else {
                    throw BASICError.runtime("CD is not supported by this host")
                }
                if let path = cdCommand {
                    do {
                        try fileHost.changeDirectory(path: path)
                    } catch let error as BASICError {
                        throw error
                    } catch {
                        throw BASICError.runtime("Could not change directory to \(path): \(error.localizedDescription)")
                    }
                } else {
                    host.printLine(try fileHost.currentDirectoryPath())
                }
                return true
            }
            if let promptCommand = try Self.promptString(from: trimmed) {
                if let promptCommand {
                    promptTemplate = promptCommand
                } else {
                    host.printLine(promptTemplate)
                }
                return true
            }
            if Self.isFilesCommand(trimmed) {
                guard let fileHost = host as? BASICFileHost else {
                    throw BASICError.runtime("FILES is not supported by this host")
                }
                do {
                    let files = try fileHost.listFiles()
                    if !files.isEmpty {
                        let columns = (host as? BASICConsoleHost)?.screenColumns() ?? 80
                        host.printLine(BASICFileListFormatter.columns(files, terminalColumns: columns))
                    }
                } catch let error as BASICError {
                    throw error
                } catch {
                    throw BASICError.runtime("Could not list files: \(error.localizedDescription)")
                }
                return true
            }

            if let path = try Self.runPath(from: trimmed) {
                guard let fileHost = host as? BASICFileHost else {
                    throw BASICError.runtime("RUN from file is not supported by this host")
                }
                do {
                    program.loadSource(try fileHost.loadTextFile(path: path), fileName: path)
                    fileState.lastFilePath = path
                    let diagnostics = self.diagnostics()
                    if diagnostics.isEmpty {
                        try runProgramInForeground(executionControl: foregroundExecutionControl)
                    } else {
                        printDiagnostics()
                    }
                } catch let error as BASICError {
                    throw error
                } catch {
                    throw BASICError.runtime("Could not run \(path): \(error.localizedDescription)")
                }
                return true
            }

            if let startLine = try Self.runStartLine(from: trimmed) {
                try runProgramInForeground(startLine: startLine, executionControl: foregroundExecutionControl)
                return true
            }

            if let listCommand = try Self.listCommand(from: trimmed) {
                let colored = (host as? BASICListingStyleHost)?.usesColoredListing == true
                let listing = program.listing(begin: listCommand.begin, end: listCommand.end, colorized: colored)
                if !listing.isEmpty { host.printLine(listing) }
                if listCommand.check {
                    printDiagnostics()
                }
                return true
            }

            let upper = trimmed.uppercased()
            if upper == "TASKS" || upper == "TASKS DETAIL" {
                printTaskStatus(detail: upper == "TASKS DETAIL")
                return true
            }
            let taskParts = trimmed.split(whereSeparator: { $0.isWhitespace })
            if taskParts.count == 2,
               taskParts[0].caseInsensitiveCompare("TASK") == .orderedSame,
               let taskID = Int(taskParts[1]) {
                printTaskDetail(id: taskID)
                return true
            }

            switch trimmed.uppercased() {
            case "NEW":
                stopAllTimers()
                program.clear()
                runtime.clearAll()
                fileState.lastFilePath = nil
            case "CLEAR":
                stopAllTimers()
                runtime.clearAll()
            case "HELP":
                host.printLine("Commands: RUN, LIST, LOAD, SAVE, CD, PROMPT, FILES, SYSTEM, TASKS, TASK <id>, NEW, CLEAR, HELP, QUIT")
                host.printLine("Statements: PRINT, LET, GLOBAL, LOCAL, OPTION, INPUT, GOTO, GOSUB, RETURN, IF expr THEN target, LABEL, END, REM")
            case "QUIT", "EXIT":
                return false
            default:
                try BASICInterpreter(program: immediateProgram(for: trimmed), host: host, runtime: runtime, fileState: fileState, timerHost: self).run()
            }
        } catch let error as BASICError {
            (host as? BASICRunDisplayHost)?.prepareToPrintRunResult()
            host.printLine(error.description)
        } catch {
            (host as? BASICRunDisplayHost)?.prepareToPrintRunResult()
            host.printLine("Unexpected error: \(error)")
        }

        return true
    }

    private func printTaskStatus(detail: Bool) {
        let tasks = debugTasks.sorted { $0.id < $1.id }
        guard !tasks.isEmpty else {
            host.printLine("No tasks.")
            return
        }
        host.printLine("Tasks:")
        for task in tasks {
            host.printLine(taskSummaryLine(task))
            if detail {
                for line in taskDetailLines(task).dropFirst() {
                    host.printLine(line)
                }
            }
        }
    }

    private func printTaskDetail(id: Int) {
        guard let task = debugTasks.first(where: { $0.id == id }) else {
            host.printLine("Task #\(id) not found.")
            return
        }
        for line in taskDetailLines(task) {
            host.printLine(line)
        }
    }

    private func taskSummaryLine(_ task: BASICTaskSnapshot) -> String {
        var pieces = ["#\(task.id)", task.state.rawValue.uppercased(), task.name]
        if let parentID = task.parentID {
            pieces.append("parent=#\(parentID)")
        }
        if let location = task.location {
            pieces.append(taskLocationDescription(location))
        }
        pieces.append("yields=\(task.yieldCount)")
        if task.childCount > 0 {
            pieces.append("children=\(task.childCount)")
        }
        if task.waiterCount > 0 {
            pieces.append("waiters=\(task.waiterCount)")
        }
        if let result = task.resultDescription {
            pieces.append("result=\(shortTaskText(result))")
        }
        if let error = task.errorDescription {
            pieces.append("error=\(shortTaskText(error))")
        }
        return pieces.joined(separator: " ")
    }

    private func taskDetailLines(_ task: BASICTaskSnapshot) -> [String] {
        var lines = [taskSummaryLine(task)]
        if let reason = task.suspensionReason {
            lines.append("  Waiting: \(taskSuspensionDescription(reason))")
        }
        if !task.suspendedFrames.isEmpty {
            lines.append("  Frames:")
            for (index, frame) in task.suspendedFrames.enumerated() {
                var frameLine = "    \(index): \(frame.kind) \(frame.name)"
                if let location = frame.resumeLocation {
                    frameLine += " \(taskLocationDescription(location))"
                }
                if frame.localScopeDepth > 0 {
                    frameLine += " scopes=\(frame.localScopeDepth)"
                }
                lines.append(frameLine)
                for variable in frame.localVariables {
                    lines.append(contentsOf: taskVariableLines(variable, indent: "      "))
                }
            }
        }
        if !task.suspendedGlobalVariables.isEmpty {
            lines.append("  Captured Globals:")
            for variable in task.suspendedGlobalVariables {
                lines.append(contentsOf: taskVariableLines(variable, indent: "    "))
            }
        }
        return lines
    }

    private func taskVariableLines(_ variable: BASICVariableSnapshot, indent: String) -> [String] {
        var lines = ["\(indent)\(variable.name) \(variable.typeName) = \(shortTaskText(variable.value))"]
        for child in variable.children {
            lines.append(contentsOf: taskVariableLines(child, indent: indent + "  "))
        }
        return lines
    }

    private func taskLocationDescription(_ location: BASICBreakpointLocation) -> String {
        var text = "line=\(location.lineNumber)"
        if location.statementNumber > 0 {
            text += ":\(location.statementNumber)"
        }
        if let fileName = location.fileName, !fileName.isEmpty {
            text += " file=\(fileName)"
        }
        return text
    }

    private func taskSuspensionDescription(_ reason: BASICTaskSuspensionReason) -> String {
        switch reason {
        case .debugger:
            return "debugger"
        case .hostOperation(let operation):
            return "host operation \(operation)"
        case .join(let taskID):
            return "task #\(taskID)"
        }
    }

    private func shortTaskText(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: "\\n")
        guard collapsed.count > 48 else { return collapsed }
        return String(collapsed.prefix(45)) + "..."
    }

    /// Starts the program from the beginning or an optional numbered line.
    public func runProgram(startLine: Int? = nil, executionControl: BASICExecutionControl? = nil) throws {
        stopAllTimers()
        runtime.resetForRun()
        let task = taskScheduler.createTask(name: "Program")
        let interpreter = BASICInterpreter(
            program: program,
            host: host,
            runtime: runtime,
            fileState: fileState,
            executionControl: executionControl,
            task: task,
            taskScheduler: taskScheduler,
            timerHost: self,
            eventLoop: eventLoop
        )
        activeInterpreter = interpreter
        do {
            try interpreter.run(startLine: startLine)
            stopAllTimers()
            activeInterpreter = nil
        } catch let error as BASICError {
            switch error {
            case .breakRequested, .breakpoint, .stepComplete:
                if case .breakRequested = error, stopsForegroundProgramOnBreak {
                    stopAllTimers()
                    activeInterpreter = nil
                } else {
                    pauseRuntimeTimersForDebugger()
                }
            default:
                stopAllTimers()
                activeInterpreter = nil
            }
            throw error
        } catch {
            stopAllTimers()
            activeInterpreter = nil
            throw error
        }
    }

    /// Posts a host resize event to the running program, if it registered an `ON RESIZE CALL` handler.
    public func postResizeEvent(width: Int, height: Int) {
        postEvent(
            selector: BASICEventSelector(type: "RESIZE"),
            fields: [
                "type": .string(BASICString("RESIZE")),
                "subtype": .string(BASICString("")),
                "width": .number(Double(width)),
                "height": .number(Double(height))
            ]
        )
    }

    /// Posts a host mouse event to the running program, if it registered an `ON MOUSE ... CALL` handler.
    public func postMouseEvent(
        subtype: String,
        x: Double,
        y: Double,
        button: Int,
        buttons: Int,
        duration: Double
    ) {
        let normalizedSubtype = subtype.uppercased()
        postEvent(
            selector: BASICEventSelector(type: "MOUSE", subtype: normalizedSubtype),
            fields: [
                "type": .string(BASICString("MOUSE")),
                "subtype": .string(BASICString(normalizedSubtype)),
                "x": .number(x),
                "y": .number(y),
                "button": .number(Double(button)),
                "buttons": .number(Double(buttons)),
                "duration": .number(duration)
            ]
        )
    }

    func startTimer(id: Int, intervalSeconds: Double, repeating: Bool) {
        let controlBlock = BASICTimerControlBlock(
            id: id,
            intervalSeconds: intervalSeconds,
            repeating: repeating,
            queue: timerQueue
        ) { [weak self] sequence, intervalMilliseconds in
            self?.postTimerEvent(timerID: id, sequence: sequence, intervalMilliseconds: intervalMilliseconds)
        }
        timerLock.lock()
        let oldBlock = timerBlocks.updateValue(controlBlock, forKey: id)
        timerLock.unlock()
        logTarget(
            module: "BASICSession.swift",
            text: "timer control added id=\(id) interval=\(intervalSeconds)s repeating=\(repeating)"
        )
        if oldBlock != nil {
            logTarget(module: "BASICSession.swift", text: "timer control purged id=\(id) reason=replaced")
        }
        oldBlock?.cancel()
        controlBlock.start()
    }

    func stopTimer(id: Int) {
        timerLock.lock()
        let controlBlock = timerBlocks.removeValue(forKey: id)
        timerLock.unlock()
        if controlBlock != nil {
            logTarget(module: "BASICSession.swift", text: "timer control purged id=\(id) reason=stop")
        }
        controlBlock?.cancel()
    }

    private func stopAllTimers() {
        timerLock.lock()
        let controlBlocks = Array(timerBlocks.values)
        let count = timerBlocks.count
        timerBlocks.removeAll()
        timerLock.unlock()
        if count > 0 {
            logTarget(module: "BASICSession.swift", text: "timer controls purged count=\(count) reason=stop-all")
        }
        controlBlocks.forEach { $0.cancel() }
    }

    private func pauseRuntimeTimersForDebugger() {
        timerLock.lock()
        let controlBlocks = Array(timerBlocks.values)
        let count = timerBlocks.count
        timerBlocks.removeAll()
        timerLock.unlock()
        if count > 0 {
            logTarget(module: "BASICSession.swift", text: "timer controls purged count=\(count) reason=debug-pause")
        }
        clearPendingHostEvents(reason: "debug-pause")
        controlBlocks.forEach { $0.cancel() }
    }

    private func restartRunningTimers() {
        for timer in runtime.runningSecondsTimers() {
            startTimer(id: timer.id, intervalSeconds: timer.intervalSeconds, repeating: timer.repeating)
        }
    }

    /// Posts due timer events for a BASIC `SecondsTimer` object.
    private func postTimerEvent(timerID: Int, sequence: Int, intervalMilliseconds: Int) {
        timerLock.lock()
        let isTimerActive = timerBlocks[timerID] != nil
        timerLock.unlock()
        guard isTimerActive else {
            logTarget(
                module: "BASICSession.swift",
                text: "timer event purged id=\(timerID) sequence=\(sequence) reason=inactive"
            )
            return
        }

        let registrations = runtime.timerHandlerRegistrations(forTimerID: timerID)
        guard !registrations.isEmpty else {
            logTarget(
                module: "BASICSession.swift",
                text: "timer event purged id=\(timerID) sequence=\(sequence) reason=no-handler"
            )
            return
        }
        for item in registrations where sequence % item.ticks == 0 {
            let fields: [String: BASICValue] = [
                "type": .string(BASICString("TIMER")),
                "subtype": .string(BASICString(item.registration.selector.subtype ?? "")),
                "timerID": .number(Double(timerID)),
                "timerId": .number(Double(timerID)),
                "sequence": .number(Double(sequence)),
                "tick": .number(Double(item.ticks)),
                "ticks": .number(Double(item.ticks)),
                "interval": .number(Double(intervalMilliseconds)),
                "baseInterval": .number(Double(intervalMilliseconds)),
                "elapsed": .number(Double(sequence) * Double(intervalMilliseconds) / 1000.0)
            ]
            logTarget(
                module: "BASICSession.swift",
                text: "timer event added id=\(timerID) sequence=\(sequence) tick=\(item.ticks) selector=\(item.registration.selector.description)"
            )
            postEvent(selector: item.registration.selector, fields: fields)
        }
    }

    private func postEvent(selector: BASICEventSelector, fields: [String: BASICValue]) {
        guard !eventLoop.hasPendingError else {
            if selector.type == "TIMER" {
                logTarget(module: "BASICSession.swift", text: "timer event purged selector=\(selector.description) reason=pending-error")
            }
            return
        }
        let data = BASICValue.dictionary(BASICDictionary(values: fields))
        hostEventLock.lock()
        let replacesExisting = pendingHostEvents[selector] != nil
        if !replacesExisting {
            pendingHostEventOrder.append(selector)
        }
        pendingHostEvents[selector] = data
        guard !isHostEventDrainQueued else {
            hostEventLock.unlock()
            if selector.type == "TIMER", replacesExisting {
                logTarget(module: "BASICSession.swift", text: "timer event purged selector=\(selector.description) reason=replaced-pending")
            }
            return
        }
        isHostEventDrainQueued = true
        hostEventLock.unlock()

        eventLoop.post { [weak self] in
            self?.drainHostEvents()
        }
    }

    private func drainHostEvents() {
        guard !eventLoop.hasPendingError else { return }
        hostEventLock.lock()
        let orderedSelectors = pendingHostEventOrder.sorted { lhs, rhs in
            eventDeliveryPriority(lhs) < eventDeliveryPriority(rhs)
        }
        let events = orderedSelectors.compactMap { selector in
            pendingHostEvents[selector].map { (selector, $0) }
        }
        pendingHostEvents.removeAll()
        pendingHostEventOrder.removeAll()
        isHostEventDrainQueued = false
        hostEventLock.unlock()

        guard let activeInterpreter else { return }
        for (selector, data) in events {
            do {
            if selector.type == "TIMER" {
                logTarget(
                    module: "BASICSession.swift",
                    text: "timer event dispatching selector=\(selector.description) data=\(timerEventLogSummary(data))"
                )
            }
                try activeInterpreter.dispatchEvent(selector: selector, data: data)
            } catch BASICError.breakRequested {
                if stopsForegroundProgramOnBreak {
                    stopAllTimers()
                    self.activeInterpreter = nil
                } else {
                    pauseRuntimeTimersForDebugger()
                }
                eventLoop.reportError(BASICError.breakRequested(nil))
                return
            } catch let error as BASICError where error.isDebugPause {
                pauseRuntimeTimersForDebugger()
                eventLoop.reportError(error)
                return
            } catch {
                host.printLine("Runtime error: \(error)")
            }
        }
    }

    private func clearPendingHostEvents(reason: String = "clear") {
        hostEventLock.lock()
        let timerCount = pendingHostEvents.keys.filter { $0.type == "TIMER" }.count
        pendingHostEvents.removeAll()
        pendingHostEventOrder.removeAll()
        isHostEventDrainQueued = false
        hostEventLock.unlock()
        if timerCount > 0 {
            logTarget(module: "BASICSession.swift", text: "timer events purged count=\(timerCount) reason=\(reason)")
        }
    }

    private func eventDeliveryPriority(_ selector: BASICEventSelector) -> Int {
        switch selector.type {
        case "RESIZE":
            return 0
        case "MOUSE":
            return 1
        default:
            return 2
        }
    }

    private func logTarget(module: String, text: String) {
        guard let loggingHost = host as? BASICLoggingHost,
              loggingHost.isBASICLoggingEnabled else {
            return
        }
        loggingHost.log(level: "TARGET", issuer: "B", module: module, text: text)
    }

    private func timerEventLogSummary(_ data: BASICValue) -> String {
        guard case .dictionary(let dictionary) = data else {
            return data.description
        }
        func number(_ key: String) -> String {
            guard let value = dictionary.values[key], let number = value.number else { return "?" }
            return String(Int(number))
        }
        return "id=\(number("timerID")) sequence=\(number("sequence")) tick=\(number("tick")) interval=\(number("interval"))"
    }

    /// Runs the program synchronously, using the configured foreground lane when present.
    public func runProgramInForeground(startLine: Int? = nil, executionControl: BASICExecutionControl? = nil) throws {
        executionControl?.reset()
        guard let foregroundRunLane else {
            try runProgram(startLine: startLine, executionControl: executionControl)
            return
        }
        try runProgramSynchronously(on: foregroundRunLane, startLine: startLine, executionControl: executionControl)
    }

    /// Submits a program run to a serialized worker lane.
    @discardableResult
    public func runProgram(
        on lane: BASICWorkerLane,
        startLine: Int? = nil,
        executionControl: BASICExecutionControl? = nil,
        completion: @escaping @Sendable (BASICWorkerLaneRunResult) -> Void
    ) -> Bool {
        lane.submit { [self] in
            do {
                try runProgram(startLine: startLine, executionControl: executionControl)
                completion(.success)
            } catch {
                completion(.failure(String(describing: error)))
            }
        }
    }

    /// Submits a program run to a serialized worker lane and blocks until it finishes.
    public func runProgramSynchronously(
        on lane: BASICWorkerLane,
        startLine: Int? = nil,
        executionControl: BASICExecutionControl? = nil
    ) throws {
        let finished = DispatchSemaphore(value: 0)
        let resultBox = BASICWorkerLaneResultBox()
        let accepted = lane.submit { [self] in
            do {
                try runProgram(startLine: startLine, executionControl: executionControl)
                resultBox.store(.success(()))
            } catch {
                resultBox.store(.failure(error))
            }
            finished.signal()
        }
        guard accepted else {
            throw BASICError.runtime("Program is already running")
        }
        finished.wait()
        switch resultBox.result {
        case .success:
            return
        case .failure(let error):
            throw error
        case .none:
            throw BASICError.runtime("Program finished without a result")
        }
    }

    /// Continues an interrupted program, or runs from the start when no program is paused.
    public func continueProgram(executionControl: BASICExecutionControl? = nil) throws {
        guard let activeInterpreter else {
            try runProgram(executionControl: executionControl)
            return
        }
        activeInterpreter.setExecutionControl(executionControl)
        restartRunningTimers()
        do {
            try activeInterpreter.continueExecution()
            stopAllTimers()
            self.activeInterpreter = nil
        } catch let error as BASICError {
            switch error {
            case .breakRequested, .breakpoint, .stepComplete:
                pauseRuntimeTimersForDebugger()
                break
            default:
                stopAllTimers()
                self.activeInterpreter = nil
            }
            throw error
        } catch {
            stopAllTimers()
            self.activeInterpreter = nil
            throw error
        }
    }

    /// Local variables visible in the active debugger frame.
    public var debugLocalVariables: [BASICVariableSnapshot] {
        activeInterpreter?.debugLocalVariables ?? runtime.localSnapshots()
    }

    /// Global variables visible to the program.
    public var debugGlobalVariables: [BASICVariableSnapshot] {
        activeInterpreter?.debugGlobalVariables ?? runtime.globalSnapshots()
    }

    /// Parses and validates the current program without running it.
    public func diagnostics() -> [BASICDiagnostic] {
        BASICInterpreter(program: program, host: host, runtime: runtime, fileState: fileState).diagnostics()
    }

    private func printDiagnostics() {
        let diagnostics = self.diagnostics()
        guard !diagnostics.isEmpty else {
            host.printLine("No diagnostics.")
            return
        }

        host.printLine("Diagnostics:")
        let indexedLines = program.orderedLines.enumerated().map { index, line in
            (
                sourceLineNumber: line.sourceLineNumber ?? index + 1,
                displayLineNumber: line.number ?? line.sourceLineNumber ?? index + 1,
                source: line.number.map { "\($0) \(line.source)" } ?? line.source
            )
        }
        for diagnostic in diagnostics {
            let source = diagnostic.fileName == nil
                ? indexedLines.first { $0.sourceLineNumber == diagnostic.lineNumber }
                : nil
            let displayLineNumber = source?.displayLineNumber ?? diagnostic.lineNumber
            let filePrefix = diagnostic.fileName.map { "\($0):" } ?? ""
            host.printLine("\(filePrefix)Line \(displayLineNumber), column \(diagnostic.column + 1): \(diagnostic.message)")
            if let sourceText = source?.source {
                host.printLine(sourceText)
                host.printLine(String(repeating: " ", count: max(0, diagnostic.column)) + "^")
            }
        }
    }

    /// Current debugger call stack.
    public var debugCallStack: [BASICCallStackFrame] {
        activeInterpreter?.debugCallStack ?? []
    }

    /// Logical BASIC task snapshots known to this session.
    public var debugTasks: [BASICTaskSnapshot] {
        taskScheduler.snapshots
    }

    /// Handles for logical BASIC tasks queued to run.
    public var readyTaskHandles: [BASICTaskHandle] {
        taskScheduler.readyTaskHandles
    }

    /// Handle for the current logical task, when one is selected.
    public var currentTaskHandle: BASICTaskHandle? {
        taskScheduler.currentTask?.handle
    }

    /// Creates a child logical task under an existing or current parent task.
    public func createChildTask(name: String, parentID: Int? = nil) -> BASICTaskHandle? {
        let resolvedParentID: Int?
        if let parentID {
            resolvedParentID = parentID
        } else {
            resolvedParentID = currentTaskHandle?.id
        }
        guard let resolvedParentID else { return nil }
        return taskScheduler.createChildTask(name: name, parentID: resolvedParentID)
    }

    /// Returns a nonblocking join classification for a logical task.
    public func taskJoinState(id: Int) -> BASICTaskJoinState {
        taskScheduler.joinState(for: id)
    }

    /// Returns the nonblocking await classification and result for a logical task.
    func taskAwaitState(id: Int) -> BASICTaskAwaitState {
        taskScheduler.awaitState(for: id)
    }

    /// Suspends a logical task while a host operation runs outside BASIC.
    @discardableResult
    public func suspendTaskForHostOperation(id: Int, operation: String) -> Bool {
        taskScheduler.suspendForHostOperation(id: id, operation: operation)
    }

    /// Suspends a logical task while it awaits another logical task.
    @discardableResult
    public func suspendTaskForAwait(id: Int, awaitingTaskID: Int, frame: BASICSuspendedFrame) -> Bool {
        taskScheduler.suspendForAwait(id: id, awaitingTaskID: awaitingTaskID, frame: frame)
    }

    /// Suspends a logical task while it awaits another logical task and captures debugger snapshots.
    @discardableResult
    public func suspendTaskForAwait(
        id: Int,
        awaitingTaskID: Int,
        frames: [BASICSuspendedFrame],
        globalVariables: [BASICVariableSnapshot] = []
    ) -> Bool {
        taskScheduler.suspendForAwait(
            id: id,
            awaitingTaskID: awaitingTaskID,
            frames: frames,
            globalVariables: globalVariables
        )
    }

    /// Resumes a suspended logical task after its wait condition is satisfied.
    @discardableResult
    public func resumeTask(id: Int) -> Bool {
        taskScheduler.resumeTask(id: id)
    }

    /// Starts host async work represented as a logical BASIC child task.
    public func startHostOperationTask(
        name: String,
        parentID: Int? = nil,
        operation: String,
        work: @escaping BASICTaskHostOperation
    ) -> BASICTaskHandle {
        let resolvedParentID = parentID ?? currentTaskHandle?.id
        return taskScheduler.startHostOperationTask(
            name: name,
            parentID: resolvedParentID,
            operation: operation,
            work: work
        )
    }

    /// Starts host async work that completes with a BASIC value.
    func startHostOperationTaskWithResult(
        name: String,
        parentID: Int? = nil,
        operation: String,
        work: @escaping BASICTaskHostResultOperation
    ) -> BASICTaskHandle {
        let resolvedParentID = parentID ?? currentTaskHandle?.id
        return taskScheduler.startHostOperationTaskWithResult(
            name: name,
            parentID: resolvedParentID,
            operation: operation,
            work: work
        )
    }

    /// Requests cooperative cancellation for a logical task.
    @discardableResult
    public func requestTaskCancellation(id: Int) -> Bool {
        taskScheduler.requestCancellation(id: id)
    }

    /// Local variables for each debugger stack frame.
    public var debugFrameLocalVariables: [[BASICVariableSnapshot]] {
        activeInterpreter?.debugFrameLocalVariables ?? []
    }

    /// Current debugger call depth.
    public var debugCallDepth: Int {
        activeInterpreter?.debugCallDepth ?? 0
    }

    /// Returns a user-facing pause message for break and step errors.
    public func debugPauseDescription(for error: BASICError) -> String {
        let baseDescription: String
        switch error {
        case .breakRequested(let line):
            if let line {
                baseDescription = "Break at \(line)"
            } else {
                baseDescription = "Break at unnumbered line"
            }
        case .breakpoint(let location), .stepComplete(let location):
            baseDescription = "Break at \(location.lineNumber)"
        default:
            return error.description
        }

        guard let frame = debugCallStack.first, frame.kind != "Program" else {
            return baseDescription
        }
        return "\(baseDescription) in \(frame.kind) \(frame.name)"
    }

    private func immediateProgram(for source: String) -> BASICProgram {
        let program = BASICProgram()
        program.loadSource(Self.normalizedImmediateSource(source))
        return program
    }

    private static func normalizedImmediateSource(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("?") else { return source }
        let rest = trimmed.dropFirst()
        if rest.first?.isWhitespace == true || rest.isEmpty {
            return "PRINT" + rest
        }
        return "PRINT " + rest
    }

    private static func splitNumberedLine(_ source: String) -> (number: Int, source: String)? {
        var digits = ""
        var index = source.startIndex
        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
        while index < source.endIndex, source[index].isNumber {
            digits.append(source[index])
            index = source.index(after: index)
        }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        if index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
        let rest = String(source[index...])
        return (number, rest)
    }

    private static func loadPath(from source: String) throws -> String? {
        try commandPath(keyword: "LOAD", from: source, requiresPath: true)
    }

    private static func runPath(from source: String) throws -> String? {
        guard keywordPrefix("RUN", matches: source) else { return nil }
        let start = source.index(source.startIndex, offsetBy: 3)
        let rest = source[start...].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("\"") else { return nil }
        return try commandPath(keyword: "RUN", from: source, requiresPath: true)
    }

    private static func savePath(from source: String) throws -> String?? {
        guard keywordPrefix("SAVE", matches: source) else { return nil }
        return try commandPath(keyword: "SAVE", from: source, requiresPath: false)
    }

    private static func cdPath(from source: String) throws -> String?? {
        guard keywordPrefix("CD", matches: source) else { return nil }
        return try commandPath(keyword: "CD", from: source, requiresPath: false)
    }

    private static func promptString(from source: String) throws -> String?? {
        guard keywordPrefix("PROMPT", matches: source) else { return nil }
        return try commandPath(keyword: "PROMPT", from: source, requiresPath: false)
    }

    private struct ListCommand {
        var begin: Int?
        var end: Int?
        var check = false
    }

    private static func listCommand(from source: String) throws -> ListCommand? {
        guard keywordPrefix("LIST", matches: source) else { return nil }
        let start = source.index(source.startIndex, offsetBy: 4)
        var rest = source[start...].trimmingCharacters(in: .whitespaces)
        var command = ListCommand()

        if rest.uppercased().hasSuffix("CHECK") {
            let checkStart = rest.index(rest.endIndex, offsetBy: -5)
            let beforeCheck = rest[..<checkStart]
            if beforeCheck.isEmpty || beforeCheck.last?.isWhitespace == true {
                command.check = true
                rest = beforeCheck.trimmingCharacters(in: .whitespaces)
            }
        }

        guard !rest.isEmpty else { return command }
        if let dash = rest.firstIndex(of: "-") {
            let lower = rest[..<dash].trimmingCharacters(in: .whitespaces)
            let upper = rest[rest.index(after: dash)...].trimmingCharacters(in: .whitespaces)
            if !lower.isEmpty {
                guard let begin = Int(lower) else { throw BASICError.syntax("Expected beginning line number in LIST") }
                command.begin = begin
            }
            if !upper.isEmpty {
                guard let end = Int(upper) else { throw BASICError.syntax("Expected ending line number in LIST") }
                command.end = end
            }
            return command
        }

        guard let line = Int(rest) else { throw BASICError.syntax("Expected line range after LIST") }
        command.begin = line
        command.end = line
        return command
    }

    private static func commandPath(keyword: String, from source: String, requiresPath: Bool) throws -> String? {
        guard keywordPrefix(keyword, matches: source) else { return nil }
        let start = source.index(source.startIndex, offsetBy: keyword.count)
        let rest = source[start...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else {
            if requiresPath {
                throw BASICError.syntax("Expected path after \(keyword)")
            }
            return nil
        }

        if rest.hasPrefix("\"") {
            guard rest.hasSuffix("\""), rest.count >= 2 else {
                throw BASICError.syntax("Unterminated \(keyword) path")
            }
            return String(rest.dropFirst().dropLast())
        }

        return rest
    }

    private static func isFilesCommand(_ source: String) -> Bool {
        source.uppercased() == "FILES"
    }

    private static func runStartLine(from source: String) throws -> Int?? {
        guard keywordPrefix("RUN", matches: source) else { return nil }
        let start = source.index(source.startIndex, offsetBy: 3)
        let rest = source[start...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return .some(nil) }
        guard let line = Int(rest) else { throw BASICError.syntax("Expected line number after RUN") }
        return .some(line)
    }

    private static func keywordPrefix(_ keyword: String, matches source: String) -> Bool {
        guard source.count >= keyword.count else { return false }
        let end = source.index(source.startIndex, offsetBy: keyword.count)
        guard source[source.startIndex..<end].uppercased() == keyword else { return false }
        guard end < source.endIndex else { return true }
        return source[end].isWhitespace || source[end] == "\""
    }

    private func renderedPrompt() -> String {
        let cwd = currentWorkingDirectoryForPrompt()
        var rendered = promptTemplate
        rendered = rendered.replacingOccurrences(of: "${currentdir}", with: abbreviatedPath(cwd))
        rendered = rendered.replacingOccurrences(of: "${gitstatus}", with: gitPrompt(for: cwd))
        rendered = rendered.replacingOccurrences(of: "${user}", with: NSUserName())
        rendered = rendered.replacingOccurrences(of: "%cwd", with: abbreviatedPath(cwd))
        rendered = rendered.replacingOccurrences(of: "%gitSegment", with: gitSegment(for: cwd))
        rendered = rendered.replacingOccurrences(of: "%git", with: gitPrompt(for: cwd))
        rendered = rendered.replacingOccurrences(of: "%nl", with: "\n")
        rendered = rendered.replacingOccurrences(of: "%%", with: "%")
        return rendered
    }

    private func currentWorkingDirectoryForPrompt() -> String {
        guard let fileHost = host as? BASICFileHost,
              let path = try? fileHost.currentDirectoryPath() else {
            return FileManager.default.currentDirectoryPath
        }
        return path
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func gitSegment(for path: String) -> String {
        let git = gitPrompt(for: path)
        guard !git.isEmpty else { return "" }
        return "   \(git) "
    }

    private func gitPrompt(for path: String) -> String {
        guard let branch = Self.gitOutput(arguments: ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !branch.isEmpty,
              branch != "HEAD" else { return "" }

        let status = Self.gitOutput(arguments: ["-C", path, "status", "--porcelain=v2", "--branch"]) ?? ""
        var suffix = ""
        for line in status.split(separator: "\n") where line.hasPrefix("# branch.ab ") {
            let pieces = line.split(separator: " ")
            for piece in pieces {
                if piece.hasPrefix("+"), piece.count > 1, piece != "+0" {
                    suffix += " ⇡\(piece.dropFirst())"
                } else if piece.hasPrefix("-"), piece.count > 1, piece != "-0" {
                    suffix += " ⇣\(piece.dropFirst())"
                }
            }
        }
        return branch + suffix
    }

    private static func gitOutput(arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Low-level interpreter for a prepared `BASICProgram`.
