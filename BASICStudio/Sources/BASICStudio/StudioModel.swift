import BASICCore
import AppKit
import CoreText
import GameController
import MarkdownUI
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import VectorTerminalSDK
import WebKit

private struct StudioVTGHitRegion: Equatable {
    var id: String
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var layer: Int?
    var target: String
}

@MainActor
final class StudioModel: ObservableObject {
    @Published var selectedPane: StudioPane = .console
    @Published var inspectorPane: InspectorPane?
    @Published var isCommandBarVisible = false
    @Published var isEditorGutterVisible = false {
        didSet { saveSettings() }
    }
    @Published var editorTheme: EditorTheme = .dark {
        didSet { saveSettings() }
    }
    @Published var editorErrorLine: Int?
    @Published var editorDiagnostics: [BASICDiagnostic] = []
    @Published var editorFindRequest = 0
    @Published var editorReplaceRequest = 0
    @Published var isProgramRunning = false
    @Published var isConsoleOverwriteMode = false
    @Published var areGraphicsLayersVisible = true
    @Published var terminalScreenSize: TerminalScreenSize = .flexible {
        didSet { saveSettings() }
    }
    private var liveTerminalColumns = 80
    private var liveTerminalRows = 25
    private var liveVTGCanvasSize = BASICVectorTerminalCanvasSnapshot(width: 0, height: 0, source: "VectorTerminalView")
    private var liveVTGCellSize: (width: Double, height: Double)?
    private var vtgHitRegions: [StudioVTGHitRegion] = []
    @Published private var workingDirectoryURL = StudioModel.defaultWorkingDirectoryURL() {
        didSet { saveSettings() }
    }
    @Published var promptTemplate = BASICSession.defaultPromptTemplate {
        didSet {
            guard !isLoadingSettings else { return }
            let oldPrompt = session.prompt
            session.promptTemplate = promptTemplate
            let newPrompt = session.prompt
            if consoleText.hasSuffix(oldPrompt) {
                consoleText.removeLast(oldPrompt.count)
                consoleText += newPrompt
            }
            saveSettings()
        }
    }
    @Published var fontFamily = StudioFonts.defaultFamily {
        didSet { saveSettings() }
    }
    @Published var fontSize = 13.0 {
        didSet {
            saveSettings()
            graphicsRevision += 1
        }
    }
    @Published var programText = StudioModel.defaultProgramSource() {
        didSet {
            editorErrorLine = nil
            updateEditorDiagnostics()
        }
    }
    @Published var consoleText = BASICSession.defaultPrompt
    @Published var command = ""
    @Published var graphicsRevision = 0
    @Published var debuggerBreakpoints: [BASICBreakpoint] = []
    @Published var debuggerExecutionLine: Int?
    @Published var showsLiveExecutionLine = false {
        didSet {
            if !showsLiveExecutionLine && isProgramRunning {
                debuggerExecutionLine = nil
            }
        }
    }
    @Published var isProgramPaused = false
    @Published var debuggerCallStack: [BASICCallStackFrame] = []
    @Published var debuggerSelectedCallStackFrameIndex: Int?
    @Published var debuggerLocalVariables: [BASICVariableSnapshot] = []
    @Published var debuggerFrameLocalVariables: [[BASICVariableSnapshot]] = []
    @Published var debuggerGlobalVariables: [BASICVariableSnapshot] = []
    @Published var debuggerTasks: [BASICTaskSnapshot] = []
    @Published var debuggerSelectedTaskID: Int?
    @Published var isLoggingEnabled = true
    @Published var isTraceLoggingEnabled = false
    @Published var logEntries: [StudioLogEntry] = []
    @Published var showUserLogs = true
    @Published var showBasicLogs = false
    @Published var selectedLogLevels: Set<String> = []
    @Published private(set) var windowTitle = "BASICStudio"
    let bundledExamples = StudioModel.availableBundledExamples()

    let graphics = GraphicsFramebuffer()
    var vtgDataSink: ((Data) -> Void)?
    private lazy var vtgOutput = ClosureVTGOutput { [weak self] data in
        Task { @MainActor [weak self] in
            self?.vtgDataSink?(data)
        }
    }
    private lazy var vtgCanvas = VectorTerminalCanvas.hostValidated(output: vtgOutput)
    private var basicGraphicsOperationID = 0
    private var shouldRunStartupProgram = false
    private var isLoadingSettings = true
    private var currentProgramURL: URL?
    private var currentProgramFileName: String?
    private let executionLane = BASICWorkerLane(label: "AIBasic.Studio.Execution")
    private var activeExecutionControl: BASICExecutionControl?
    private let inputCoordinator = StudioInputCoordinator()
    private let consoleInputState = StudioConsoleInputState()
    private let gamepadInputCoordinator = StudioGamepadInputCoordinator()
    private var suppressNextEmptyProgramSubmit = false
    private var suppressNextProgramNewlineKey = false
    private var debuggerTaskRefreshTask: Task<Void, Never>?

    private lazy var session = BASICSession(host: self, promptTemplate: promptTemplate)

    private var prompt: String {
        session.prompt
    }

    init() {
        gamepadInputCoordinator.eventHandler = { [weak self] subtype, controller, control, value in
            Task { @MainActor [weak self] in
                self?.postGamepadEvent(subtype: subtype, controller: controller, control: control, value: value)
            }
        }
        appendLog(
            level: "GAMEPAD",
            issuer: .basic,
            text: "discovery active controllers=\(gamepadInputCoordinator.connectedControllerCount())"
        )
        gamepadInputCoordinator.emitConnectedControllers()
        let settings = StudioSettingsStore.load()
        editorTheme = settings.editorTheme
        isEditorGutterVisible = settings.isEditorGutterVisible
        terminalScreenSize = settings.terminalScreenSize
        workingDirectoryURL = Self.validWorkingDirectory(from: settings.workingDirectoryPath)
        let savedPromptTemplate = settings.promptTemplate == StudioFonts.legacyPlainPromptTemplate
            ? BASICSession.defaultPromptTemplate
            : settings.promptTemplate
        promptTemplate = BASICPromptTemplateStore.load(default: savedPromptTemplate)
        fontFamily = settings.fontFamily == StudioFonts.legacyDefaultFamily ? StudioFonts.defaultFamily : settings.fontFamily
        fontSize = min(max(settings.fontSize, 10), 24)
        isLoadingSettings = false
        BASICPromptTemplateStore.save(promptTemplate)
        consoleText = session.prompt

        let arguments = Array(CommandLine.arguments.dropFirst())
        if let path = arguments.first,
           let source = try? String(contentsOfFile: expandedPath(path), encoding: .utf8) {
            programText = source
            currentProgramURL = URL(fileURLWithPath: expandedPath(path))
            currentProgramFileName = currentProgramURL?.path
            workingDirectoryURL = currentProgramURL?.deletingLastPathComponent().standardizedFileURL ?? workingDirectoryURL
            shouldRunStartupProgram = true
            updateWindowTitle()
        }

        saveSettings()
        updateEditorDiagnostics()
    }

    func runStartupProgramIfNeeded() {
        guard shouldRunStartupProgram else { return }
        shouldRunStartupProgram = false
        runEditorProgram()
    }

    func toggleInspector(_ pane: InspectorPane) {
        inspectorPane = inspectorPane == pane ? nil : pane
    }

    var availableLogLevels: [String] {
        Array(Set(logEntries.map { normalizedLogLevel($0.level) })).sorted()
    }

    var filteredLogEntries: [StudioLogEntry] {
        logEntries.filter { entry in
            if normalizedLogLevel(entry.level) == "TRACE" && !isTraceLoggingEnabled { return false }
            if entry.issuer == .user && !showUserLogs { return false }
            if entry.issuer == .basic && !showBasicLogs { return false }
            return selectedLogLevels.isEmpty || selectedLogLevels.contains(normalizedLogLevel(entry.level))
        }
    }

    func toggleLogLevel(_ level: String) {
        let normalized = normalizedLogLevel(level)
        if selectedLogLevels.contains(normalized) {
            selectedLogLevels.remove(normalized)
        } else {
            selectedLogLevels.insert(normalized)
        }
    }

    func clearLogs() {
        logEntries.removeAll()
        selectedLogLevels.removeAll()
    }

    func toggleTraceLogging() {
        isTraceLoggingEnabled.toggle()
    }

    func appendLog(level: String, issuer: LogIssuer, module: String? = nil, text: String) {
        guard isLoggingEnabled else { return }
        logEntries.append(StudioLogEntry(
            timestamp: Date(),
            issuer: issuer,
            level: normalizedLogLevel(level),
            module: normalizedLogModule(module, issuer: issuer),
            text: text
        ))
        if logEntries.count > 1000 {
            logEntries.removeFirst(logEntries.count - 1000)
        }
    }

    private func normalizedLogLevel(_ level: String) -> String {
        let trimmed = level.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "INFO" : trimmed.uppercased()
    }

    private func normalizedLogModule(_ module: String?, issuer: LogIssuer) -> String {
        let trimmed = module?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        return issuer == .user ? "BASIC" : "BASICStudio.swift"
    }

    func openDebugger() {
        inspectorPane = .debug
    }

    var debuggerBreakpointLines: Set<Int> {
        Set(debuggerBreakpoints
            .filter(\.isEnabled)
            .map(\.location.lineNumber))
    }

    var debuggerSelectedLocalVariables: [BASICVariableSnapshot] {
        guard let index = debuggerSelectedCallStackFrameIndex,
              debuggerFrameLocalVariables.indices.contains(index) else {
            return debuggerLocalVariables
        }
        return debuggerFrameLocalVariables[index]
    }

    var debuggerSelectedTask: BASICTaskSnapshot? {
        guard let debuggerSelectedTaskID else { return nil }
        return debuggerTasks.first { $0.id == debuggerSelectedTaskID }
    }

    func selectDebuggerCallStackFrame(_ frame: BASICCallStackFrame) {
        debuggerSelectedCallStackFrameIndex = frame.index
    }

    func selectDebuggerTask(_ task: BASICTaskSnapshot) {
        debuggerSelectedTaskID = debuggerSelectedTaskID == task.id ? nil : task.id
    }

    func cancelSelectedDebuggerTask() {
        guard let task = debuggerSelectedTask,
              task.state == .ready || task.state == .running || task.state == .suspended else { return }
        _ = session.requestTaskCancellation(id: task.id)
        debuggerTasks = session.debugTasks
        normalizeSelectedDebuggerTask()
    }

    func updateLiveTerminalSize(columns: Int, rows: Int) {
        liveTerminalColumns = max(1, columns)
        liveTerminalRows = max(1, rows)
    }

    func updateLiveVTGCanvasSize(width: Int, height: Int) {
        liveVTGCanvasSize = BASICVectorTerminalCanvasSnapshot(
            width: max(1, width),
            height: max(1, height),
            source: "VectorTerminalView"
        )
    }

    func updateLiveVTGCellSize(width: Double, height: Double) {
        guard width > 0, height > 0 else { return }
        liveVTGCellSize = (width: max(1, width), height: max(1, height))
    }

    func postVTGResizeEvent(width: Int, height: Int) {
        session.postResizeEvent(width: max(1, width), height: max(1, height))
    }

    func postVTGMouseEvent(
        subtype: String,
        x: Double,
        y: Double,
        button: Int,
        buttons: Int,
        duration: Double,
        deltaX: Double = 0,
        deltaY: Double = 0,
        hitID: String = "",
        target: String = ""
    ) {
        session.postMouseEvent(
            subtype: subtype,
            x: x,
            y: y,
            button: button,
            buttons: buttons,
            duration: duration,
            deltaX: deltaX,
            deltaY: deltaY,
            hitID: hitID,
            target: target
        )
    }

    func hitRegion(atX x: Double, y: Double) -> (id: String, target: String)? {
        let px = Int(x.rounded(.down))
        let py = Int(y.rounded(.down))
        for region in vtgHitRegions.reversed() {
            guard px >= region.x,
                  py >= region.y,
                  px < region.x + region.width,
                  py < region.y + region.height else {
                continue
            }
            return (region.id, region.target)
        }
        return nil
    }

    func postGamepadEvent(subtype: String, controller: Int, control: String, value: Double) {
        guard session.acceptsHostInputEvent(type: "GAMEPAD", subtype: subtype) else { return }
        appendLog(
            level: "GAMEPAD",
            issuer: .basic,
            text: "event subtype=\(subtype) controller=\(controller) control=\(control) value=\(value)"
        )
        session.postGamepadEvent(subtype: subtype, controller: controller, control: control, value: value)
    }

    func toggleDebuggerBreakpoint(atSourceLine lineNumber: Int) {
        let location = BASICBreakpointLocation(
            fileName: debuggerFileName,
            lineNumber: lineNumber,
            statementNumber: 0
        )
        if let index = debuggerBreakpoints.firstIndex(where: { $0.location == location }) {
            debuggerBreakpoints.remove(at: index)
        } else {
            debuggerBreakpoints.append(BASICBreakpoint(location: location))
        }
    }

    func showFind() {
        selectedPane = .editor
        editorFindRequest += 1
    }

    func showFindAndReplace() {
        selectedPane = .editor
        editorReplaceRequest += 1
    }

    func loadProgramFromMenu() {
        let panel = NSOpenPanel()
        panel.title = "Load BASIC Program"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.basicProgramContentTypes
        panel.directoryURL = currentProgramURL?.deletingLastPathComponent() ?? workingDirectoryURL

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            programText = source
            currentProgramURL = url
            currentProgramFileName = url.path
            workingDirectoryURL = url.deletingLastPathComponent().standardizedFileURL
            updateWindowTitle()
            editorErrorLine = nil
            rebuildProgramFromEditor()
            selectedPane = .editor
        } catch {
            presentFileError("Unable to load \(url.lastPathComponent).", error: error)
        }
    }

    func loadBundledExample(_ example: BundledExample) {
        guard let source = Self.bundledDemoSource(named: example.path) else {
            let alert = NSAlert()
            alert.messageText = "Unable to load \(example.menuTitle)."
            alert.informativeText = "The bundled example could not be found."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        programText = source
        currentProgramURL = nil
        currentProgramFileName = Self.demoFileName(for: example.path)
        updateWindowTitle()
        editorErrorLine = nil
        debuggerExecutionLine = nil
        debuggerBreakpoints = []
        rebuildProgramFromEditor()
        selectedPane = .editor
    }

    func saveProgramFromMenu() {
        if let currentProgramURL {
            saveProgram(to: currentProgramURL)
        } else {
            saveProgramAsFromMenu()
        }
    }

    func saveProgramAsFromMenu() {
        let panel = NSSavePanel()
        panel.title = "Save BASIC Program"
        panel.allowedContentTypes = Self.basicProgramContentTypes
        panel.nameFieldStringValue = currentProgramURL?.lastPathComponent ?? "Untitled.bas"
        panel.directoryURL = currentProgramURL?.deletingLastPathComponent() ?? workingDirectoryURL

        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveProgram(to: url)
    }

    func setWorkingDirectoryFromMenu() {
        let panel = NSOpenPanel()
        panel.title = "Set BASIC Working Directory"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = workingDirectoryURL

        guard panel.runModal() == .OK, let url = panel.url else { return }
        workingDirectoryURL = url.standardizedFileURL
    }

    func runEditorProgram() {
        guard !isProgramRunning else { return }
        rebuildProgramFromEditor()
        selectedPane = .console
        echoConsoleCommand("RUN")
        startProgramRun(startLine: nil)
    }

    func listProgram() {
        rebuildProgramFromEditor()
        selectedPane = .console
        submitConsoleCommand("LIST", echo: true)
    }

    func clearProgram() {
        guard !isProgramRunning else { return }
        _ = session.submit("NEW")
        programText = ""
        currentProgramURL = nil
        currentProgramFileName = nil
        updateWindowTitle()
        consoleText = prompt
        graphics.clear(color: nil)
        graphicsRevision += 1
        isProgramPaused = false
        debuggerExecutionLine = nil
        debuggerCallStack = []
        debuggerSelectedCallStackFrameIndex = nil
        debuggerLocalVariables = []
        debuggerFrameLocalVariables = []
        debuggerGlobalVariables = []
        debuggerTasks = session.debugTasks
        debuggerSelectedTaskID = nil
        activeExecutionControl = nil
    }

    func submitCommand() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectedPane = .console
        submitConsoleCommand(trimmed, echo: true)
        command = ""
    }

    func setConsoleOverwriteMode(_ value: Bool) {
        consoleInputState.setOverwriteMode(value)
        isConsoleOverwriteMode = value
    }

    func toggleConsoleOverwriteModeFromTerminal() -> Bool {
        let value = consoleInputState.toggleOverwriteMode()
        isConsoleOverwriteMode = value
        return value
    }

    func setGraphicsLayersVisible(_ isVisible: Bool) {
        areGraphicsLayersVisible = isVisible
    }

    func toggleGraphicsLayersVisible() {
        areGraphicsLayersVisible.toggle()
    }

    func stopProgram() {
        activeExecutionControl?.requestBreak()
        inputCoordinator.cancelLineInput()
        inputCoordinator.endRawKeyInput()
    }

    func continueDebugging() {
        guard isProgramPaused else { return }
        startProgramRun(startLine: nil, command: .continueExecution)
    }

    func stepDebugging() {
        if !isProgramPaused {
            rebuildProgramFromEditor()
        }
        startProgramRun(startLine: nil, command: isProgramPaused ? .stepInto : .runStep)
    }

    func stepOverDebugging() {
        if !isProgramPaused {
            rebuildProgramFromEditor()
        }
        startProgramRun(startLine: nil, command: isProgramPaused ? .stepOver : .runStep)
    }

    func stepOutDebugging() {
        guard isProgramPaused else { return }
        startProgramRun(startLine: nil, command: .stepOut)
    }

    func handleTerminalInput(_ operations: [TerminalInputOperation]) {
        for operation in operations {
            switch operation {
            case .append(let text):
                if inputCoordinator.shouldCaptureKeyOnly() {
                    appendLog(level: "INPUT", issuer: .basic, text: "queued printable key while program is running")
                    inputCoordinator.pushKey(text)
                } else {
                    consoleText += text
                }
            case .submit(let command):
                appendLog(level: "INPUT", issuer: .basic, text: "submit \(command.isEmpty ? "<empty>" : command)")
                if inputCoordinator.awaitingLineInput() {
                    if inputCoordinator.activeLineInputOptions().fieldLength == nil {
                        consoleText += "\n"
                    }
                    inputCoordinator.submitLine(command)
                } else if inputCoordinator.shouldCaptureKeyOnly() {
                    if command.isEmpty && suppressNextEmptyProgramSubmit {
                        appendLog(level: "INPUT", issuer: .basic, text: "suppressed empty submit after program launch")
                        suppressNextEmptyProgramSubmit = false
                    } else {
                        suppressNextEmptyProgramSubmit = false
                        inputCoordinator.pushKey("\n")
                    }
                } else {
                    consoleText += "\n"
                    submitConsoleCommand(command, echo: false)
                    if isProgramRunning {
                        suppressNextEmptyProgramSubmit = true
                    }
                }
            case .lineInputExit(let line, let key):
                appendLog(level: "INPUT", issuer: .basic, text: "line input exit key \(key) with \(line.count) chars")
                if inputCoordinator.awaitingLineInput() {
                    if inputCoordinator.activeLineInputOptions().fieldLength == nil {
                        consoleText += "\n"
                    }
                    inputCoordinator.submitLineInputExit(line: line, key: key)
                } else {
                    suppressNextProgramNewlineKey = false
                    inputCoordinator.pushKey(key)
                }
            case .key(let text):
                appendLog(level: "INPUT", issuer: .basic, text: "key \(debugKeyDescription(text))")
                if text == "\n" && suppressNextProgramNewlineKey {
                    appendLog(level: "INPUT", issuer: .basic, text: "suppressed newline key after program launch")
                    suppressNextProgramNewlineKey = false
                } else {
                    suppressNextProgramNewlineKey = false
                    inputCoordinator.pushKey(text)
                }
            }
        }
    }

    private func debugKeyDescription(_ key: String) -> String {
        switch key {
        case "\n": return "\\n"
        case "\t": return "\\t"
        case "\u{1B}": return "ESC"
        default: return key.isEmpty ? "<empty>" : key
        }
    }

    nonisolated func shouldCaptureTerminalKeyOnly() -> Bool {
        inputCoordinator.shouldCaptureKeyOnly()
    }

    nonisolated func shouldProgramStopOnTerminalInterrupt() -> Bool {
        inputCoordinator.shouldCaptureKeyOnly()
            || inputCoordinator.awaitingLineInput()
            || inputCoordinator.rawKeyInputActive()
    }

    nonisolated func shouldExitLineInputOnSpecialKey() -> Bool {
        inputCoordinator.shouldExitLineInputOnSpecialKey()
    }

    nonisolated func shouldUseTerminalCommandHistory() -> Bool {
        !inputCoordinator.awaitingLineInput()
            && !inputCoordinator.shouldCaptureKeyOnly()
    }

    nonisolated func activeLineInputOptions() -> BASICLineInputOptions {
        inputCoordinator.activeLineInputOptions()
    }

    func consoleCompletionAliasWords() -> [String] {
        session.aliasNames
    }

    func consoleCompletionSymbolWords() -> [String] {
        let program = BASICProgram()
        program.loadSource(programText, fileName: currentProgramFileName)
        return BASICCompletionEngine.programSymbolWords(in: program)
    }

    func consoleCompletionIncludesExternalCommands() -> Bool {
        session.shellModeEnabled
    }

    func consoleCompletionWorkingDirectoryPath() -> String {
        (try? currentDirectoryPath()) ?? FileManager.default.currentDirectoryPath
    }

    private func rebuildProgramFromEditor() {
        session.program.loadSource(programText, fileName: currentProgramFileName)
        updateEditorDiagnostics()
    }

    private func updateEditorDiagnostics() {
        let program = BASICProgram()
        program.loadSource(programText, fileName: currentProgramFileName)
        editorDiagnostics = BASICInterpreter(program: program, host: self).diagnostics()
    }

    private func saveProgram(to url: URL) {
        do {
            try programText.write(to: url, atomically: true, encoding: .utf8)
            currentProgramURL = url
            currentProgramFileName = url.path
            workingDirectoryURL = url.deletingLastPathComponent().standardizedFileURL
            updateWindowTitle()
            rebuildProgramFromEditor()
        } catch {
            presentFileError("Unable to save \(url.lastPathComponent).", error: error)
        }
    }

    private func updateWindowTitle() {
        if let currentProgramURL {
            windowTitle = "BASICStudio - \(currentProgramURL.lastPathComponent)"
            return
        }

        if let currentProgramFileName, !currentProgramFileName.isEmpty {
            let displayName = URL(fileURLWithPath: currentProgramFileName).lastPathComponent
            windowTitle = "BASICStudio - \(displayName)"
            return
        }

        windowTitle = "BASICStudio"
    }

    private func presentFileError(_ message: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func appendConsoleOutput(_ text: String, terminator: String = "\n") {
        consoleText += text + terminator
    }

    private func echoConsoleCommand(_ command: String) {
        if !consoleText.hasSuffix(prompt) {
            consoleText += prompt
        }
        consoleText += command + "\n"
    }

    private func submitConsoleCommand(_ command: String, echo: Bool) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        editorErrorLine = nil
        if shouldUseEditorProgram(for: trimmed) {
            rebuildProgramFromEditor()
        }

        if echo {
            echoConsoleCommand(command)
        }

        if trimmed.uppercased() == "EDIT" {
            graphics.clear(color: nil)
            graphicsRevision += 1
            selectedPane = .editor
            return
        }

        if let startLine = runStartLine(from: trimmed) {
            startProgramRun(startLine: startLine, command: .run)
            return
        }

        if !trimmed.isEmpty {
            let shouldContinue = session.submit(command)
            if promptTemplate != session.promptTemplate {
                promptTemplate = session.promptTemplate
            }
            if shouldSyncEditorAfterCommand(trimmed) {
                syncEditorFromSession()
                syncProgramIdentityAfterConsoleCommand(trimmed)
            }
            if !shouldContinue {
                appendConsoleOutput("BYE")
                return
            }
        }

        consoleText += prompt
    }

    private enum DebugRunCommand: Sendable {
        case run
        case continueExecution
        case stepInto
        case stepOver
        case stepOut
        case runStep

        var isStepCommand: Bool {
            switch self {
            case .stepInto, .stepOver, .stepOut, .runStep:
                return true
            case .run, .continueExecution:
                return false
            }
        }
    }

    private func startProgramRun(startLine: Int?, command: DebugRunCommand = .run) {
        guard !isProgramRunning else { return }
        inputCoordinator.clearKeys()
        suppressNextEmptyProgramSubmit = false
        suppressNextProgramNewlineKey = command == .run || command == .runStep
        appendLog(level: "RUN", issuer: .basic, text: "starting \(command) \(startLine.map { "at \($0)" } ?? "")")
        let control = BASICExecutionControl()
        control.setBreakpoints(debuggerBreakpoints)
        switch command {
        case .run, .continueExecution:
            control.setMode(.run)
        case .stepInto, .runStep:
            control.setMode(.stepInto)
        case .stepOver:
            control.setMode(.stepOver(depth: session.debugCallDepth))
        case .stepOut:
            control.setMode(.stepOut(depth: session.debugCallDepth))
        }
        if command.isStepCommand {
            let targetTaskID = debuggerTargetTaskID(for: command)
            control.setTargetTaskID(targetTaskID)
            if let targetTaskID {
                debuggerSelectedTaskID = targetTaskID
            }
        }
        if command == .continueExecution || command == .stepInto || command == .stepOver || command == .stepOut {
            control.ignoreBreakpointOnce(at: activeExecutionControl?.location)
        }
        activeExecutionControl = control
        isProgramRunning = true
        debuggerTasks = session.debugTasks
        normalizeSelectedDebuggerTask()
        startDebuggerTaskRefresh()
        inputCoordinator.setProgramRunning(true)
        isProgramPaused = false
        if !showsLiveExecutionLine || command == .run || command == .runStep {
            debuggerExecutionLine = nil
        }
        let session = session

        let accepted = executionLane.submit { [weak self, session, control, startLine, command] in
            let result: Result<Void, Error>
            do {
                switch command {
                case .run, .runStep:
                    try session.runProgram(startLine: startLine, executionControl: control)
                case .continueExecution, .stepInto, .stepOver, .stepOut:
                    try session.continueProgram(executionControl: control)
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self?.finishProgramRun(result)
            }
        }
        if !accepted {
            finishProgramRun(.failure(BASICError.runtime("Program is already running")))
        }
    }

    private func finishProgramRun(_ result: Result<Void, Error>) {
        var paused = false
        var consoleMessage: String?
        switch result {
        case .success:
            debuggerExecutionLine = nil
            isProgramPaused = false
            debuggerCallStack = []
            debuggerSelectedCallStackFrameIndex = nil
            debuggerLocalVariables = []
            debuggerFrameLocalVariables = []
            debuggerGlobalVariables = session.debugGlobalVariables
            break
        case .failure(let error as BASICError):
            switch error {
            case .breakRequested(let line):
                debuggerExecutionLine = activeExecutionControl?.location.flatMap(debuggerSourceLineNumber(for:))
                    ?? line.flatMap(sourceLineNumber(forBasicLineNumber:))
                paused = true
            case .breakpoint(let location):
                debuggerExecutionLine = debuggerSourceLineNumber(for: location)
                paused = true
            case .stepComplete(let location):
                debuggerExecutionLine = debuggerSourceLineNumber(for: location)
                paused = true
            default:
                isProgramPaused = false
                break
            }
            consoleMessage = session.debugPauseDescription(for: error)
        case .failure(let error):
            isProgramPaused = false
            consoleMessage = "Unexpected error: \(error)"
        }

        isProgramPaused = paused
        debuggerTasks = session.debugTasks
        normalizeSelectedDebuggerTask()
        stopDebuggerTaskRefresh()
        if paused {
            debuggerCallStack = session.debugCallStack
            debuggerLocalVariables = session.debugLocalVariables
            debuggerFrameLocalVariables = session.debugFrameLocalVariables
            if debuggerSelectedCallStackFrameIndex == nil ||
                !debuggerCallStack.contains(where: { $0.index == debuggerSelectedCallStackFrameIndex }) {
                debuggerSelectedCallStackFrameIndex = debuggerCallStack.first?.index
            }
            debuggerGlobalVariables = session.debugGlobalVariables
        }
        if !paused {
            debuggerCallStack = []
            debuggerSelectedCallStackFrameIndex = nil
            debuggerFrameLocalVariables = []
            activeExecutionControl = nil
        }
        isProgramRunning = false
        inputCoordinator.setProgramRunning(false)
        appendLog(level: paused ? "PAUSE" : "RUN", issuer: .basic, text: paused ? "program paused" : "program finished")

        let debuggerIsActive = inspectorPane == .debug
        let shouldSuppressConsolePause = paused && debuggerIsActive
        if let consoleMessage, !shouldSuppressConsolePause {
            appendConsoleOutput(consoleMessage)
        }
        if !shouldSuppressConsolePause {
            consoleText += prompt
        }
    }

    private func startDebuggerTaskRefresh() {
        debuggerTaskRefreshTask?.cancel()
        debuggerTaskRefreshTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                guard self.isProgramRunning else { break }
                self.debuggerTasks = self.session.debugTasks
                self.normalizeSelectedDebuggerTask()
                if self.showsLiveExecutionLine {
                    self.refreshDebuggerExecutionLine()
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func stopDebuggerTaskRefresh() {
        debuggerTaskRefreshTask?.cancel()
        debuggerTaskRefreshTask = nil
    }

    private func normalizeSelectedDebuggerTask() {
        guard let selectedID = debuggerSelectedTaskID,
              debuggerTasks.contains(where: { $0.id == selectedID }) else {
            debuggerSelectedTaskID = debuggerTasks.first(where: { $0.state == .suspended })?.id ?? debuggerTasks.first?.id
            return
        }
    }

    private func debuggerTargetTaskID(for command: DebugRunCommand) -> Int? {
        guard command.isStepCommand else { return nil }
        let tasks = session.debugTasks
        if let selectedID = debuggerSelectedTaskID,
           tasks.contains(where: { $0.id == selectedID && $0.state == .suspended }) {
            return selectedID
        }
        if let currentID = session.currentTaskHandle?.id,
           tasks.contains(where: { $0.id == currentID }) {
            return currentID
        }
        return tasks.first(where: { $0.state == .suspended })?.id ?? tasks.first?.id
    }

    private func runStartLine(from command: String) -> Int?? {
        let uppercased = command.uppercased()
        guard uppercased == "RUN" || uppercased.hasPrefix("RUN ") else { return nil }
        let rest = command.dropFirst(3).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return .some(nil) }
        guard let line = Int(rest) else { return nil }
        return .some(line)
    }

    private func shouldUseEditorProgram(for command: String) -> Bool {
        let keyword = command.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return keyword == "LIST" || matchesCommandKeyword("RUN", in: keyword) || matchesCommandKeyword("SAVE", in: keyword)
    }

    private func shouldSyncEditorAfterCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let uppercased = trimmed.uppercased()
        return trimmed.first?.isNumber == true || uppercased == "NEW" || matchesCommandKeyword("LOAD", in: uppercased)
    }

    private func matchesCommandKeyword(_ keyword: String, in command: String) -> Bool {
        guard command.count >= keyword.count else { return false }
        let end = command.index(command.startIndex, offsetBy: keyword.count)
        guard command[command.startIndex..<end] == keyword[...] else { return false }
        guard end < command.endIndex else { return true }
        return command[end].isWhitespace || command[end] == "\""
    }

    private func syncEditorFromSession() {
        programText = session.program.listing()
    }

    private func syncProgramIdentityAfterConsoleCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercased = trimmed.uppercased()

        if uppercased == "NEW" {
            currentProgramURL = nil
            currentProgramFileName = nil
            updateWindowTitle()
            return
        }

        if let path = pathArgument(for: "LOAD", in: trimmed)
            ?? pathArgument(for: "RUN", in: trimmed)
            ?? pathArgument(for: "SAVE", in: trimmed) {
            let expanded = expandedPath(path)
            currentProgramURL = URL(fileURLWithPath: expanded)
            currentProgramFileName = expanded
            updateWindowTitle()
        }
    }

    private func pathArgument(for keyword: String, in command: String) -> String? {
        guard matchesCommandKeyword(keyword, in: command.uppercased()) else { return nil }

        let keywordEnd = command.index(command.startIndex, offsetBy: keyword.count)
        let argument = command[keywordEnd...].trimmingCharacters(in: .whitespaces)
        guard !argument.isEmpty else { return nil }

        if argument.first == "\"" {
            var result = ""
            var index = argument.index(after: argument.startIndex)
            while index < argument.endIndex {
                let character = argument[index]
                if character == "\"" {
                    return result
                }
                result.append(character)
                index = argument.index(after: index)
            }
            return nil
        }

        return argument.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    private var debuggerFileName: String? {
        currentProgramFileName
    }

    private func refreshDebuggerExecutionLine() {
        debuggerExecutionLine = activeExecutionControl?.location.flatMap(debuggerSourceLineNumber(for:))
    }

    private func debuggerSourceLineNumber(for location: BASICBreakpointLocation) -> Int? {
        guard location.lineNumber > 0 else { return nil }
        guard let fileName = location.fileName, !fileName.isEmpty else {
            return location.lineNumber
        }
        guard let currentProgramFileName, !currentProgramFileName.isEmpty else {
            return location.lineNumber
        }
        return sourceFileNamesMatch(fileName, currentProgramFileName) ? location.lineNumber : nil
    }

    private func sourceFileNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let lhsURL = URL(fileURLWithPath: lhs).standardizedFileURL
        let rhsURL = URL(fileURLWithPath: rhs).standardizedFileURL
        if lhsURL.path == rhsURL.path { return true }
        return lhsURL.lastPathComponent == rhsURL.lastPathComponent && !lhsURL.lastPathComponent.isEmpty
    }

    private func sourceLineNumber(forBasicLineNumber lineNumber: Int) -> Int? {
        let lines = programText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.firstIndex { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("\(lineNumber) ")
                || line.trimmingCharacters(in: .whitespaces) == "\(lineNumber)"
        }.map { $0 + 1 }
    }

    private func saveSettings() {
        BASICPromptTemplateStore.save(promptTemplate)
        StudioSettingsStore.save(
            StudioSettings(
                editorTheme: editorTheme,
                isEditorGutterVisible: isEditorGutterVisible,
                terminalScreenSize: terminalScreenSize,
                workingDirectoryPath: workingDirectoryURL.path,
                promptTemplate: promptTemplate,
                fontFamily: fontFamily,
                fontSize: fontSize
            )
        )
    }

    private static func defaultWorkingDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    private static func validWorkingDirectory(from path: String?) -> URL {
        guard let path, !path.isEmpty else { return defaultWorkingDirectoryURL() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return defaultWorkingDirectoryURL()
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private func highlightErrorIfPresent(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3,
              lines[1].contains("^"),
              lines[2].hasPrefix("Syntax error:") else { return }

        let source = lines[0].trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return }

        let programLines = programText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let index = programLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == source }) {
            editorErrorLine = index + 1
        }
    }

    nonisolated private func expandedPath(_ path: String) -> String {
        if path == "~" || path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst())
        }
        if path.hasPrefix("/") {
            return path
        }
        if let url = URL(string: path), url.isFileURL {
            return url.path
        }
        return workingDirectorySnapshot().appendingPathComponent(path).standardizedFileURL.path
    }

    nonisolated private func ensureParentDirectory(for path: String) throws {
        let url = URL(fileURLWithPath: expandedPath(path))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    nonisolated private func workingDirectorySnapshot() -> URL {
        valueOnMainSync {
            workingDirectoryURL
        }
    }

    nonisolated private func runOnMainSync(_ body: @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                body()
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    body()
                }
            }
        }
    }

    nonisolated private func valueOnMainSync<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                body()
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                body()
            }
        }
    }

    private static var basicProgramContentTypes: [UTType] {
        var types: [UTType] = [.plainText, .text, .sourceCode]
        if let basic = UTType(filenameExtension: "bas") {
            types.append(basic)
        }
        return types
    }

    private static func defaultProgramSource() -> String {
        let fileManager = FileManager.default
        if let source = bundledDemoSource(named: "test-suite") {
            return source
        }

        let relativePath = "basicPrograms/demos/test-suite.bas"
        let sourcePath = String(#filePath)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let candidates = [
            fileManager.currentDirectoryPath + "/" + relativePath,
            fileManager.currentDirectoryPath + "/../../" + relativePath,
            sourceURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(relativePath)
                .path
        ]

        for path in candidates {
            if let source = try? String(contentsOfFile: path, encoding: .utf8) {
                return source
            }
        }

        return """
        print "AIBASIC SWIFTTERM"
        screen 1
        color 2
        line (10,10)-(310,10), 2
        line (310,10)-(310,190), 3
        line (310,190)-(10,190), 1
        line (10,190)-(10,10), 2
        pset (160,100), 3
        print "CENTER =", point(160,100)
        end
        """
    }

    private static func bundledDemoSource(named name: String) -> String? {
        let normalized = normalizedBundledDemoPath(name)
        let url = URL(fileURLWithPath: normalized.hasSuffix(".bas") ? String(normalized.dropLast(4)) : normalized)
        let directory = url.deletingLastPathComponent().relativePath
        let subdirectory = directory == "." || directory.isEmpty ? "Demos" : "Demos/\(directory)"
        for resource in demoResourceCandidates(named: url.lastPathComponent, subdirectory: subdirectory) {
            if let source = try? String(contentsOf: resource, encoding: .utf8) {
                return source
            }
        }
        return nil
    }

    private static func demoFileName(for name: String) -> String {
        name.hasSuffix(".bas") ? name : "\(name).bas"
    }

    private static func availableBundledExamples() -> [BundledExample] {
        var examplesByPath: [String: BundledExample] = [:]
        for root in demoRootCandidates() {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                continue
            }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "bas" {
                guard let path = pathRelativeToDemoRoot(url, root: root) else { continue }
                examplesByPath[path] = BundledExample(path: path)
            }
        }

        return examplesByPath.values.sorted {
            $0.menuTitle.localizedStandardCompare($1.menuTitle) == .orderedAscending
        }
    }

    private static func demoRootCandidates() -> [URL] {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: String(#filePath))
        let packageRoot = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundleDemoRoot = Bundle.main.resourceURL?.appendingPathComponent("Demos")
        let bundleRootFallback = bundleDemoRoot.map { fileManager.fileExists(atPath: $0.path) } == true
            ? nil
            : Bundle.main.resourceURL

        let candidateURLs = [
            bundleDemoRoot,
            bundleRootFallback,
            packageRoot.appendingPathComponent("Sources/BASICStudio/Resources/Demos"),
            packageRoot
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("basicPrograms/demos"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Resources/Demos")
        ].compactMap { $0 }

        var seen: Set<String> = []
        return candidateURLs.filter { url in
            let key = url.standardizedFileURL.path
            guard fileManager.fileExists(atPath: key), !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private static func pathRelativeToDemoRoot(_ url: URL, root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(path.dropFirst(rootPath.count + 1))
        guard relative.hasSuffix(".bas") else { return nil }
        return String(relative.dropLast(4))
    }

    private static func demoResourceCandidates(named name: String, subdirectory: String) -> [URL] {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: String(#filePath))
        let packageRoot = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        return [
            Bundle.main.url(forResource: name, withExtension: "bas"),
            Bundle.main.url(forResource: name, withExtension: "bas", subdirectory: subdirectory),
            Bundle.main.resourceURL?
                .appendingPathComponent(subdirectory)
                .appendingPathComponent("\(name).bas"),
            packageRoot
                .appendingPathComponent("Sources/BASICStudio/Resources")
                .appendingPathComponent(subdirectory)
                .appendingPathComponent("\(name).bas"),
            packageRoot
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("basicPrograms/demos")
                .appendingPathComponent(String(subdirectory.dropFirst("Demos".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                .appendingPathComponent("\(name).bas"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Resources")
                .appendingPathComponent(subdirectory)
                .appendingPathComponent("\(name).bas")
        ].compactMap { $0 }
    }

    var programLineCount: Int {
        programText.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var consoleLineCount: Int {
        guard !consoleText.isEmpty else { return 0 }
        return consoleText.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

extension StudioModel: StudioDebuggerInterface {}

extension StudioModel: BASICHost, BASICKeyboardHost, BASICBlockingKeyboardHost, BASICConsoleHost, BASICConfiguredLineInputHost, BASICLoggingHost, BASICListingStyleHost, BASICMainActorHost {
    nonisolated var usesColoredListing: Bool { true }

    nonisolated func runOnMainActorSync(_ operation: @MainActor () -> Void) {
        runOnMainSync(operation)
    }

    nonisolated var isBASICLoggingEnabled: Bool {
        valueOnMainSync { isLoggingEnabled }
    }

    nonisolated var isBASICTraceEnabled: Bool {
        valueOnMainSync { isLoggingEnabled && isTraceLoggingEnabled }
    }

    nonisolated func log(level: String, issuer: String, module: String, text: String) {
        runOnMainSync {
            appendLog(level: level, issuer: issuer.uppercased() == "U" ? .user : .basic, module: module, text: text)
        }
    }

    nonisolated func print(_ text: String, terminator: String) {
        runOnMainSync {
            highlightErrorIfPresent(text)
            appendConsoleOutput(text, terminator: terminator)
        }
    }

    nonisolated func printLine(_ text: String) {
        runOnMainSync {
            highlightErrorIfPresent(text)
            appendConsoleOutput(text)
        }
    }

    nonisolated func readLine(prompt: String) -> String? {
        inputCoordinator.beginLineInput()
        runOnMainSync {
            appendConsoleOutput(prompt, terminator: "")
        }
        return inputCoordinator.waitForLine()
    }

    nonisolated func readLine(prompt: String, exitOnSpecialKey: Bool) -> BASICLineInputResult? {
        inputCoordinator.beginLineInput(exitOnSpecialKey: exitOnSpecialKey)
        runOnMainSync {
            appendConsoleOutput(prompt, terminator: "")
        }
        return inputCoordinator.waitForLineInput()
    }

    nonisolated func readLine(prompt: String, exitOnSpecialKey: Bool, options: BASICLineInputOptions) -> BASICLineInputResult? {
        inputCoordinator.beginLineInput(exitOnSpecialKey: exitOnSpecialKey, options: options)
        runOnMainSync {
            appendConsoleOutput(prompt, terminator: "")
            let defaultText = options.maxLength.map { String((options.defaultText ?? "").prefix($0)) } ?? (options.defaultText ?? "")
            if let length = options.fieldLength {
                let visible = String(defaultText.prefix(length))
                appendConsoleOutput(
                    visible
                    + String(repeating: " ", count: max(0, length - visible.count))
                    + String(repeating: "\u{1B}[D", count: max(0, length - visible.count)),
                    terminator: ""
                )
            } else if !defaultText.isEmpty {
                appendConsoleOutput(defaultText, terminator: "")
            }
        }
        return inputCoordinator.waitForLineInput()
    }

    nonisolated func screenColumns() -> Int {
        valueOnMainSync {
            terminalScreenSize.dimensions?.cols ?? liveTerminalColumns
        }
    }

    nonisolated func screenRows() -> Int {
        valueOnMainSync {
            terminalScreenSize.dimensions?.rows ?? liveTerminalRows
        }
    }

    nonisolated func readKey() -> String? {
        inputCoordinator.readKey() ?? gamepadInputCoordinator.readKey()
    }

    nonisolated func readBlockingKey() -> String? {
        if let key = inputCoordinator.readKey() ?? gamepadInputCoordinator.readKey() {
            return key
        }
        inputCoordinator.beginRawKeyInput()
        defer { inputCoordinator.endRawKeyInput() }

        if Thread.isMainThread {
            while true {
                if let key = inputCoordinator.readKey() ?? gamepadInputCoordinator.readKey() {
                    return key
                }
                if !inputCoordinator.rawKeyInputActive() {
                    return nil
                }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        }

        while true {
            if let key = gamepadInputCoordinator.readKey() {
                return key
            }
            if let key = inputCoordinator.waitForRawKey() {
                return key
            }
            if let key = gamepadInputCoordinator.readKey() {
                return key
            }
            return nil
        }
    }
}

extension StudioModel: BASICFileHost, BASICSystemHost, BASICProcessHost, BASICExecutableResolverHost {
    nonisolated func loadTextFile(path: String) throws -> String {
        do {
            return try String(contentsOfFile: expandedPath(path), encoding: .utf8)
        } catch {
            guard let url = bundledDemoURL(path: path) else { throw error }
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    nonisolated func saveTextFile(path: String, text: String) throws {
        try ensureParentDirectory(for: path)
        try text.write(toFile: expandedPath(path), atomically: true, encoding: .utf8)
    }

    nonisolated func fileExists(path: String) throws -> Bool {
        FileManager.default.fileExists(atPath: expandedPath(path))
    }

    nonisolated func currentDirectoryPath() throws -> String {
        workingDirectorySnapshot().path
    }

    nonisolated func changeDirectory(path: String) throws {
        let resolvedPath = expandedPath(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BASICError.runtime("Could not change directory to \(path)")
        }
        runOnMainSync {
            workingDirectoryURL = URL(fileURLWithPath: resolvedPath, isDirectory: true).standardizedFileURL
        }
    }

    nonisolated func listFiles() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: workingDirectorySnapshot().path)
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    nonisolated func listFiles(path: String) throws -> [String] {
        let root = URL(fileURLWithPath: expandedPath(path), isDirectory: true).standardizedFileURL
        if let diskFiles = try recursiveFiles(at: root) {
            return diskFiles
        }

        for root in bundledDemoRootCandidates(path: path) {
            if let files = try recursiveFiles(at: root.standardizedFileURL) {
                return files
            }
        }
        return []
    }

    nonisolated func resolveExecutable(_ command: String, environment: BASICEnvironmentPatch) throws -> String? {
        let expandedCommand = expandedPath(command)
        if expandedCommand.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expandedCommand) ? expandedCommand : nil
        }

        let patchedEnvironment = environment.applying(to: ProcessInfo.processInfo.environment)
        let pathValue = patchedEnvironment["PATH"] ?? patchedEnvironment["Path"] ?? patchedEnvironment["path"] ?? ""
        for directory in pathValue.split(separator: ":", omittingEmptySubsequences: false) {
            let base = directory.isEmpty ? "." : String(directory)
            let candidate = URL(fileURLWithPath: expandedPath(base), isDirectory: true)
                .appendingPathComponent(command)
                .standardizedFileURL
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    nonisolated private func recursiveFiles(at root: URL) throws -> [String]? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return try enumerator
            .compactMap { $0 as? URL }
            .filter { url in
                try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            }
            .map { url in
                String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    nonisolated private func bundledDemoURL(path: String) -> URL? {
        for root in bundledDemoRootCandidates(path: "") {
            let url = root.appendingPathComponent(normalizedDemoPath(path))
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    nonisolated private func bundledDemoRootCandidates(path: String) -> [URL] {
        let normalized = normalizedDemoPath(path)
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: String(#filePath))
        let packageRoot = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        return [
            Bundle.main.resourceURL?.appendingPathComponent("Demos").appendingPathComponent(normalized),
            Bundle.main.resourceURL?.appendingPathComponent(normalized),
            packageRoot.appendingPathComponent("Sources/BASICStudio/Resources/Demos").appendingPathComponent(normalized),
            packageRoot
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("basicPrograms/demos")
                .appendingPathComponent(normalized)
        ]
        .compactMap { $0 }
        .filter { fileManager.fileExists(atPath: $0.path) }
    }

    nonisolated private static func normalizedBundledDemoPath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        let legacyPrefixes = [
            "basicPrograms/demos/",
            "basicPrograms/shell/",
            "basicPrograms/BASICStudio/",
            "shell/",
            "studio/"
        ]
        var didStrip = true
        while didStrip {
            didStrip = false
            for prefix in legacyPrefixes where normalized.hasPrefix(prefix) {
                normalized.removeFirst(prefix.count)
                didStrip = true
            }
        }
        return normalized
    }

    nonisolated private func normalizedDemoPath(_ path: String) -> String {
        Self.normalizedBundledDemoPath(path)
    }

    nonisolated func runSystemCommand(_ command: String) throws -> String {
        try runSystemCommandResult(command, environment: .empty).output
    }

    nonisolated func runSystemCommandResult(_ command: String, environment: BASICEnvironmentPatch) throws -> BASICSystemCommandResult {
        try BASICSystemCommand.runResult(
            command,
            workingDirectory: workingDirectorySnapshot(),
            columns: screenColumns(),
            rows: screenRows(),
            environment: environment
        )
    }
}

extension StudioModel: BASICVectorTerminalHost {
    nonisolated private func useVTGCanvas(_ operation: @MainActor (VectorTerminalCanvas) -> Void) {
        runOnMainActorSync {
            operation(vtgCanvas)
        }
    }

    nonisolated private func vtgColor(_ value: String?) -> VectorTerminalSDK.VTGColor? {
        guard let value, value.lowercased() != "none" else { return nil }
        return VectorTerminalSDK.VTGColor(value)
    }

    nonisolated private func vtgLineCap(_ value: String?) -> VectorTerminalSDK.VTGLineCap? {
        guard let value else { return nil }
        return VectorTerminalSDK.VTGLineCap(rawValue: value.lowercased())
    }

    nonisolated private func vtgLineJoin(_ value: String?) -> VectorTerminalSDK.VTGLineJoin? {
        guard let value else { return nil }
        return VectorTerminalSDK.VTGLineJoin(rawValue: value.lowercased())
    }

    nonisolated private func vtgSpriteFilter(_ value: String) -> VectorTerminalSDK.VTGSpriteFilter {
        VectorTerminalSDK.VTGSpriteFilter(rawValue: value.lowercased()) ?? .smooth
    }

    nonisolated private func ansiColor(_ value: String) throws -> VectorTerminalSDK.ANSIColor {
        switch value.lowercased() {
        case "black": return .black
        case "red": return .red
        case "green": return .green
        case "yellow": return .yellow
        case "blue": return .blue
        case "magenta": return .magenta
        case "cyan": return .cyan
        case "white": return .white
        default: throw BASICError.runtime("Unknown ANSI color \(value)")
        }
    }

    nonisolated private func canvasSnapshot(_ canvas: VectorTerminalSDK.VTGCanvas?) -> BASICVectorTerminalCanvasSnapshot? {
        guard let canvas else { return nil }
        return BASICVectorTerminalCanvasSnapshot(
            width: canvas.width,
            height: canvas.height,
            source: canvas.source,
            rawResponse: canvas.rawResponse
        )
    }

    nonisolated private func capabilityJSON(_ capabilities: VectorTerminalSDK.VTGCapabilities?) -> String? {
        guard let capabilities else { return nil }
        var object: [String: Any] = [
            "commands": capabilities.commands,
            "planned": capabilities.planned,
            "primitives": capabilities.primitives,
            "underTextPrimitives": capabilities.underTextPrimitives,
            "formats": capabilities.formats,
            "raster": capabilities.raster,
            "sprites": capabilities.sprites,
            "events": capabilities.events,
            "colors": capabilities.colors,
            "textPlaneStatus": capabilities.textPlaneStatus.rawValue,
            "rawResponse": capabilities.rawResponse
        ]
        object["protocolName"] = capabilities.protocolName
        object["schema"] = capabilities.schema
        object["version"] = capabilities.version
        object["renderer"] = capabilities.renderer
        object["layers"] = capabilities.layers
        object["defaultLayer"] = capabilities.defaultLayer
        object["textPlane"] = capabilities.textPlane
        object["layerScroll"] = capabilities.layerScroll
        object["layerAlpha"] = capabilities.layerAlpha
        object["clip"] = capabilities.clip
        object["hit"] = capabilities.hit
        if let canvas = capabilities.canvas {
            object["canvas"] = ["width": canvas.width, "height": canvas.height, "source": canvas.source ?? ""]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    nonisolated func vectorTerminalClear() throws {
        useVTGCanvas { $0.clear() }
    }

    nonisolated func vectorTerminalPresent() throws {
        useVTGCanvas { $0.present() }
    }

    nonisolated func vectorTerminalDelete(id: String) throws {
        useVTGCanvas { $0.delete(id: id) }
    }

    nonisolated func vectorTerminalClearRect(id: String, x: Int, y: Int, width: Int, height: Int, layer: Int?) throws {
        useVTGCanvas { $0.clearRect(id: id, x: x, y: y, width: width, height: height, layer: layer) }
    }

    nonisolated func vectorTerminalPixel(id: String, x: Int, y: Int, color: String, layer: Int?) throws {
        useVTGCanvas { $0.pixel(id: id, x: x, y: y, color: VectorTerminalSDK.VTGColor(color), layer: layer) }
    }

    nonisolated func vectorTerminalLine(id: String, x1: Int, y1: Int, x2: Int, y2: Int, stroke: String, width: Int, lineCap: String?, layer: Int?) throws {
        useVTGCanvas { $0.line(id: id, x1: x1, y1: y1, x2: x2, y2: y2, stroke: VectorTerminalSDK.VTGColor(stroke), width: width, lineCap: vtgLineCap(lineCap), layer: layer) }
    }

    nonisolated func vectorTerminalDraw(id: String, points: [(x: Int, y: Int)], stroke: String, width: Int, lineCap: String?, lineJoin: String?, layer: Int?) throws {
        useVTGCanvas { $0.draw(id: id, points: points.map { VTGPoint(x: $0.x, y: $0.y) }, stroke: VectorTerminalSDK.VTGColor(stroke), width: width, lineCap: vtgLineCap(lineCap), lineJoin: vtgLineJoin(lineJoin), layer: layer) }
    }

    nonisolated func vectorTerminalQuadraticCurve(id: String, x1: Int, y1: Int, cx: Int, cy: Int, x2: Int, y2: Int, stroke: String, width: Int, lineCap: String?, lineJoin: String?, layer: Int?) throws {
        useVTGCanvas { $0.quadraticCurve(id: id, x1: x1, y1: y1, cx: cx, cy: cy, x2: x2, y2: y2, stroke: VectorTerminalSDK.VTGColor(stroke), width: width, lineCap: vtgLineCap(lineCap), lineJoin: vtgLineJoin(lineJoin), layer: layer) }
    }

    nonisolated func vectorTerminalCubicCurve(id: String, x1: Int, y1: Int, c1x: Int, c1y: Int, c2x: Int, c2y: Int, x2: Int, y2: Int, stroke: String, width: Int, lineCap: String?, lineJoin: String?, layer: Int?) throws {
        useVTGCanvas { $0.cubicCurve(id: id, x1: x1, y1: y1, c1x: c1x, c1y: c1y, c2x: c2x, c2y: c2y, x2: x2, y2: y2, stroke: VectorTerminalSDK.VTGColor(stroke), width: width, lineCap: vtgLineCap(lineCap), lineJoin: vtgLineJoin(lineJoin), layer: layer) }
    }

    nonisolated func vectorTerminalPath(id: String, payload: String, stroke: String?, fill: String?, lineWidth: Int, lineCap: String?, lineJoin: String?, layer: Int?) throws {
        useVTGCanvas { $0.path(id: id, payload: payload, stroke: vtgColor(stroke), fill: vtgColor(fill), lineWidth: lineWidth, lineCap: vtgLineCap(lineCap), lineJoin: vtgLineJoin(lineJoin), layer: layer) }
    }

    nonisolated func vectorTerminalTriangle(id: String, x1: Int, y1: Int, x2: Int, y2: Int, x3: Int, y3: Int, stroke: String?, fill: String?, lineWidth: Int, radius: Int, lineJoin: String?, layer: Int?) throws {
        useVTGCanvas { $0.triangle(id: id, p1: VTGPoint(x: x1, y: y1), p2: VTGPoint(x: x2, y: y2), p3: VTGPoint(x: x3, y: y3), stroke: vtgColor(stroke), fill: vtgColor(fill), lineWidth: lineWidth, radius: radius, lineJoin: vtgLineJoin(lineJoin), layer: layer) }
    }

    nonisolated func vectorTerminalRect(id: String, x: Int, y: Int, width: Int, height: Int, stroke: String?, fill: String?, lineWidth: Int, radius: Int, corners: String?, lineJoin: String?, layer: Int?) throws {
        useVTGCanvas { $0.rect(id: id, x: x, y: y, width: width, height: height, stroke: vtgColor(stroke), fill: vtgColor(fill), lineWidth: lineWidth, radius: radius, corners: corners, lineJoin: vtgLineJoin(lineJoin), layer: layer) }
    }

    nonisolated func vectorTerminalCircle(id: String, cx: Int, cy: Int, radius: Int, stroke: String?, fill: String?, lineWidth: Int, layer: Int?) throws {
        useVTGCanvas { $0.circle(id: id, cx: cx, cy: cy, radius: radius, stroke: vtgColor(stroke), fill: vtgColor(fill), lineWidth: lineWidth, layer: layer) }
    }

    nonisolated func vectorTerminalEllipse(id: String, cx: Int, cy: Int, rx: Int, ry: Int, stroke: String?, fill: String?, lineWidth: Int, layer: Int?) throws {
        useVTGCanvas { $0.ellipse(id: id, cx: cx, cy: cy, rx: rx, ry: ry, stroke: vtgColor(stroke), fill: vtgColor(fill), lineWidth: lineWidth, layer: layer) }
    }

    nonisolated func vectorTerminalText(id: String, x: Int, y: Int, value: String, color: String, size: Int, layer: Int?) throws {
        useVTGCanvas { $0.text(id: id, x: x, y: y, value: value, color: VectorTerminalSDK.VTGColor(color), size: size, layer: layer) }
    }

    nonisolated func vectorTerminalVectorPrint(id: String, x: Int, y: Int, height: Int, value: String, stroke: String, width: Int, layer: Int?) throws {
        useVTGCanvas { $0.vectorPrint(id: id, x: x, y: y, height: height, value: value, stroke: VectorTerminalSDK.VTGColor(stroke), width: width, layer: layer) }
    }

    nonisolated func vectorTerminalVectorTextSize(height: Int, value: String) throws -> BASICVectorTerminalCanvasSnapshot {
        let size = VectorTerminalSDK.VectorTerminalCanvas.vectorTextSize(height: height, value: value)
        return BASICVectorTerminalCanvasSnapshot(width: size.width, height: size.height, source: "VectorTerminalSDK")
    }

    nonisolated func vectorTerminalPillButton(id: String, text: String, fill: String, stroke: String?, lineWidth: Int, layer: Int?, target: String?, timeoutMilliseconds: Int) throws -> BASICVectorTerminalLayoutSnapshot? {
        var result: BASICVectorTerminalLayoutSnapshot?
        useVTGCanvas {
            guard let layout = $0.pillButton(
                id: id,
                text: text,
                fill: VectorTerminalSDK.VTGColor(fill),
                stroke: vtgColor(stroke),
                lineWidth: lineWidth,
                layer: layer,
                target: target,
                timeoutMilliseconds: timeoutMilliseconds
            ) else { return }
            result = BASICVectorTerminalLayoutSnapshot(
                x: layout.x,
                y: layout.y,
                width: layout.width,
                height: layout.height,
                row: layout.row,
                column: layout.column
            )
        }
        return result
    }

    nonisolated func vectorTerminalImagePNG(id: String, x: Int, y: Int, width: Int, height: Int, data: Data, filter: String, layer: Int?) throws {
        useVTGCanvas { $0.image(id: id, x: x, y: y, width: width, height: height, pngData: data, filter: vtgSpriteFilter(filter), layer: layer) }
    }

    nonisolated func vectorTerminalImageJPEG(id: String, x: Int, y: Int, width: Int, height: Int, data: Data, filter: String, layer: Int?) throws {
        useVTGCanvas { $0.image(id: id, x: x, y: y, width: width, height: height, jpegData: data, filter: vtgSpriteFilter(filter), layer: layer) }
    }

    nonisolated func vectorTerminalUploadSpritePNG(id: String, width: Int, height: Int, data: Data, filter: String) throws {
        useVTGCanvas { $0.uploadSprite(id: id, width: width, height: height, pngData: data, filter: vtgSpriteFilter(filter)) }
    }

    nonisolated func vectorTerminalUploadSpriteJPEG(id: String, width: Int, height: Int, data: Data, filter: String) throws {
        useVTGCanvas { $0.uploadSprite(id: id, width: width, height: height, jpegData: data, filter: vtgSpriteFilter(filter)) }
    }

    nonisolated func vectorTerminalUploadVectorSprite(id: String, width: Int, height: Int, path: String, stroke: String?, fill: String?, lineWidth: Double) throws {
        useVTGCanvas { $0.uploadVectorSprite(id: id, width: width, height: height, path: path, stroke: vtgColor(stroke), fill: vtgColor(fill), lineWidth: lineWidth) }
    }

    nonisolated func vectorTerminalUploadIndexedSprite(id: String, width: Int, height: Int, pixels: [Int], palette: [String], transparentIndex: Int?, filter: String) throws {
        useVTGCanvas { $0.uploadIndexedSprite(id: id, width: width, height: height, pixels: pixels, palette: palette.map { VectorTerminalSDK.VTGColor($0) }, transparentIndex: transparentIndex, filter: vtgSpriteFilter(filter)) }
    }

    nonisolated func vectorTerminalSprite(id: String, imageID: String, x: Int, y: Int, rotation: Double, scale: Double, anchorX: Double, anchorY: Double, layer: Int?) throws {
        useVTGCanvas { $0.sprite(id: id, imageID: imageID, x: x, y: y, rotation: rotation, scale: scale, anchorX: anchorX, anchorY: anchorY, layer: layer) }
    }

    nonisolated func vectorTerminalMoveSprite(id: String, x: Int, y: Int) throws {
        useVTGCanvas { $0.moveSprite(id: id, x: x, y: y) }
    }

    nonisolated func vectorTerminalRotateSprite(id: String, rotation: Double) throws {
        useVTGCanvas { $0.rotateSprite(id: id, rotation: rotation) }
    }

    nonisolated func vectorTerminalAnchorSprite(id: String, anchorX: Double, anchorY: Double) throws {
        useVTGCanvas { $0.anchorSprite(id: id, anchorX: anchorX, anchorY: anchorY) }
    }

    nonisolated func vectorTerminalTransformSprite(id: String, x: Int, y: Int, rotation: Double, scale: Double, anchorX: Double?, anchorY: Double?) throws {
        useVTGCanvas { $0.transformSprite(id: id, x: x, y: y, rotation: rotation, scale: scale, anchorX: anchorX, anchorY: anchorY) }
    }

    nonisolated func vectorTerminalRemoveSprite(id: String) throws {
        useVTGCanvas { $0.removeSprite(id: id) }
    }

    nonisolated func vectorTerminalClearSprites() throws {
        useVTGCanvas { $0.clearSprites() }
    }

    nonisolated func vectorTerminalSetDefaultLayer(_ layer: Int) throws {
        useVTGCanvas { $0.setDefaultLayer(layer) }
    }

    nonisolated func vectorTerminalSetLayer(id: String, layer: Int) throws {
        useVTGCanvas { $0.setLayer(id: id, layer: layer) }
    }

    nonisolated func vectorTerminalScrollLayer(_ layer: Int, x: Int, y: Int) throws {
        useVTGCanvas { $0.scrollLayer(layer, x: x, y: y) }
    }

    nonisolated func vectorTerminalSetLayerAlpha(_ layer: Int, alpha: Double) throws {
        useVTGCanvas { $0.setLayerAlpha(layer, alpha: alpha) }
    }

    nonisolated func vectorTerminalClipLayer(_ layer: Int, x: Int, y: Int, width: Int, height: Int) throws {
        useVTGCanvas { $0.clipLayer(layer, x: x, y: y, width: width, height: height) }
    }

    nonisolated func vectorTerminalClearLayerClip(_ layer: Int) throws {
        useVTGCanvas { $0.clearLayerClip(layer) }
    }

    nonisolated func vectorTerminalSetViewportMode(layer: Int, width: Int, height: Int, scale: String) throws {
        let mode = VectorTerminalSDK.VTGViewportScaleMode(rawValue: scale.lowercased()) ?? .fit
        useVTGCanvas { $0.setViewportMode(layer: layer, width: width, height: height, scale: mode) }
    }

    nonisolated func vectorTerminalClearViewportMode(layer: Int) throws {
        useVTGCanvas { $0.clearViewportMode(layer: layer) }
    }

    nonisolated func vectorTerminalSetViewportScale(layer: Int, scale: Double, x: Int, y: Int) throws {
        useVTGCanvas { $0.setViewportScale(layer: layer, scale: scale, x: x, y: y) }
    }

    nonisolated func vectorTerminalHitRegion(id: String, x: Int, y: Int, width: Int, height: Int, layer: Int?, target: String?) throws {
        useVTGCanvas { canvas in
            canvas.hitRegion(id: id, x: x, y: y, width: width, height: height, layer: layer, target: target)
            vtgHitRegions.removeAll { $0.id == id && $0.layer == layer }
            vtgHitRegions.append(StudioVTGHitRegion(
                id: id,
                x: x,
                y: y,
                width: width,
                height: height,
                layer: layer,
                target: target ?? ""
            ))
        }
    }

    nonisolated func vectorTerminalClearHitRegions(id: String?, layer: Int?) throws {
        useVTGCanvas { canvas in
            canvas.clearHitRegions(id: id, layer: layer)
            vtgHitRegions.removeAll { region in
                let idMatches = id == nil || region.id == id
                let layerMatches = layer == nil || region.layer == layer
                return idMatches && layerMatches
            }
        }
    }

    nonisolated func vectorTerminalStartFrame(id: String, timeoutMilliseconds: Int) throws {
        useVTGCanvas { $0.startFrame(id: id, timeoutMilliseconds: timeoutMilliseconds) }
    }

    nonisolated func vectorTerminalEndFrame(id: String) throws {
        useVTGCanvas { $0.endFrame(id: id) }
    }

    nonisolated func vectorTerminalCancelFrame(id: String) throws {
        useVTGCanvas { $0.cancelFrame(id: id) }
    }

    nonisolated func vectorTerminalQueryCapabilities(timeoutMilliseconds: Int) throws -> String? {
        var result: String?
        runOnMainSync { result = vtgCanvas.queryCapabilities(timeoutMilliseconds: timeoutMilliseconds) }
        return result
    }

    nonisolated func vectorTerminalQueryCapabilityInfo(timeoutMilliseconds: Int) throws -> String? {
        var result: String?
        runOnMainSync { result = capabilityJSON(vtgCanvas.queryCapabilityInfo(timeoutMilliseconds: timeoutMilliseconds)) }
        return result
    }

    nonisolated func vectorTerminalQueryCanvas(timeoutMilliseconds: Int) throws -> BASICVectorTerminalCanvasSnapshot? {
        var result = BASICVectorTerminalCanvasSnapshot(width: 1, height: 1, source: "VectorTerminalView")
        runOnMainSync {
            result = liveVTGCanvasSize
            guard timeoutMilliseconds > 0 else { return }
            if let queried = canvasSnapshot(vtgCanvas.queryCanvas(timeoutMilliseconds: timeoutMilliseconds)) {
                result = queried
            }
        }
        return result
    }

    nonisolated func vectorTerminalQuerySize(timeoutMilliseconds: Int) throws -> BASICVectorTerminalCanvasSnapshot? {
        var result = BASICVectorTerminalCanvasSnapshot(width: 1, height: 1, source: "VectorTerminalView")
        runOnMainSync {
            result = liveVTGCanvasSize
            guard timeoutMilliseconds > 0 else { return }
            if let queried = canvasSnapshot(vtgCanvas.querySize(timeoutMilliseconds: timeoutMilliseconds)) {
                result = queried
            }
        }
        return result
    }

    nonisolated func vectorTerminalQueryCurrentCanvas(timeoutMilliseconds: Int) throws -> BASICVectorTerminalCanvasSnapshot? {
        var result = BASICVectorTerminalCanvasSnapshot(width: 1, height: 1, source: "VectorTerminalView")
        runOnMainSync {
            result = liveVTGCanvasSize
            guard timeoutMilliseconds > 0 else { return }
            if let queried = canvasSnapshot(vtgCanvas.queryCurrentCanvas(timeoutMilliseconds: timeoutMilliseconds)) {
                result = queried
            }
        }
        return result
    }

    nonisolated func vectorTerminalQueryTerminalCellSize() throws -> BASICVectorTerminalCellSnapshot? {
        valueOnMainSync {
            BASICVectorTerminalCellSnapshot(
                columns: screenColumns(),
                rows: screenRows(),
                width: liveVTGCellSize?.width,
                height: liveVTGCellSize?.height
            )
        }
    }

    nonisolated func vectorTerminalEnableResizeEvents() throws {
        useVTGCanvas { $0.enableResizeEvents() }
    }

    nonisolated func vectorTerminalDisableResizeEvents() throws {
        useVTGCanvas { $0.disableResizeEvents() }
    }

    nonisolated func vectorTerminalEnableMouseReporting(mode: String?) throws {
        useVTGCanvas {
            if let mode {
                $0.enableMouseReporting(mode: mode)
            } else {
                $0.enableMouseReporting()
            }
        }
    }

    nonisolated func vectorTerminalDisableMouseReporting() throws {
        useVTGCanvas { $0.disableMouseReporting() }
    }

    nonisolated func vectorTerminalReadEvent(timeoutMilliseconds: Int) throws -> String? {
        var result: String?
        runOnMainSync { result = vtgCanvas.readEvent(timeoutMilliseconds: timeoutMilliseconds).map { "\($0)" } }
        return result
    }

    nonisolated func vectorTerminalEnterAlternateScreen() throws {
        useVTGCanvas { $0.enterAlternateScreen() }
    }

    nonisolated func vectorTerminalLeaveAlternateScreen() throws {
        useVTGCanvas { $0.leaveAlternateScreen() }
    }

    nonisolated func vectorTerminalEnableBracketedPaste() throws {
        useVTGCanvas { $0.enableBracketedPaste() }
    }

    nonisolated func vectorTerminalDisableBracketedPaste() throws {
        useVTGCanvas { $0.disableBracketedPaste() }
    }

    nonisolated func vectorTerminalEnableFocusReporting() throws {
        useVTGCanvas { $0.enableFocusReporting() }
    }

    nonisolated func vectorTerminalDisableFocusReporting() throws {
        useVTGCanvas { $0.disableFocusReporting() }
    }

    nonisolated func vectorTerminalClearScreen() throws {
        useVTGCanvas { $0.clearScreen() }
    }

    nonisolated func vectorTerminalClearScrollbackAndScreen() throws {
        useVTGCanvas { $0.clearScrollbackAndScreen() }
    }

    nonisolated func vectorTerminalClearLine() throws {
        useVTGCanvas { $0.clearLine() }
    }

    nonisolated func vectorTerminalClearToEndOfLine() throws {
        useVTGCanvas { $0.clearToEndOfLine() }
    }

    nonisolated func vectorTerminalWriteText(_ value: String) throws {
        useVTGCanvas { $0.writeText(value) }
    }

    nonisolated func vectorTerminalMoveCursor(row: Int, column: Int) throws {
        useVTGCanvas { $0.moveCursor(row: row, column: column) }
    }

    nonisolated func vectorTerminalSetCursor(row: Int, column: Int) throws {
        useVTGCanvas { $0.setCursor(row: row, column: column) }
    }

    nonisolated func vectorTerminalMoveCursorUp(_ count: Int) throws {
        useVTGCanvas { $0.moveCursorUp(count) }
    }

    nonisolated func vectorTerminalMoveCursorDown(_ count: Int) throws {
        useVTGCanvas { $0.moveCursorDown(count) }
    }

    nonisolated func vectorTerminalMoveCursorForward(_ count: Int) throws {
        useVTGCanvas { $0.moveCursorForward(count) }
    }

    nonisolated func vectorTerminalMoveCursorBackward(_ count: Int) throws {
        useVTGCanvas { $0.moveCursorBackward(count) }
    }

    nonisolated func vectorTerminalSaveCursor() throws {
        useVTGCanvas { $0.saveCursor() }
    }

    nonisolated func vectorTerminalRestoreCursor() throws {
        useVTGCanvas { $0.restoreCursor() }
    }

    nonisolated func vectorTerminalHideCursor() throws {
        useVTGCanvas { $0.hideCursor() }
    }

    nonisolated func vectorTerminalShowCursor() throws {
        useVTGCanvas { $0.showCursor() }
    }

    nonisolated func vectorTerminalResetTextAttributes() throws {
        useVTGCanvas { $0.resetTextAttributes() }
    }

    nonisolated func vectorTerminalBold(_ enabled: Bool) throws {
        useVTGCanvas { $0.bold(enabled) }
    }

    nonisolated func vectorTerminalUnderline(_ enabled: Bool) throws {
        useVTGCanvas { $0.underline(enabled) }
    }

    nonisolated func vectorTerminalInverse(_ enabled: Bool) throws {
        useVTGCanvas { $0.inverse(enabled) }
    }

    nonisolated func vectorTerminalSetForeground(_ color: String, bright: Bool) throws {
        let parsed = try ansiColor(color)
        useVTGCanvas { $0.setForeground(parsed, bright: bright) }
    }

    nonisolated func vectorTerminalSetBackground(_ color: String, bright: Bool) throws {
        let parsed = try ansiColor(color)
        useVTGCanvas { $0.setBackground(parsed, bright: bright) }
    }

    nonisolated func vectorTerminalSetForegroundRGB(red: Int, green: Int, blue: Int) throws {
        useVTGCanvas { $0.setForegroundRGB(red: red, green: green, blue: blue) }
    }

    nonisolated func vectorTerminalSetBackgroundRGB(red: Int, green: Int, blue: Int) throws {
        useVTGCanvas { $0.setBackgroundRGB(red: red, green: green, blue: blue) }
    }

    nonisolated func vectorTerminalBell() throws {
        useVTGCanvas { $0.bell() }
    }
}

extension StudioModel: BASICGraphicsHost {
    nonisolated private func mutateGraphics(_ operation: @MainActor (GraphicsFramebuffer) -> Void) {
        runOnMainActorSync {
            operation(graphics)
            graphicsRevision += 1
        }
    }

    nonisolated private func readGraphicsValue<T: Sendable>(_ operation: @MainActor (GraphicsFramebuffer) -> T) -> T {
        valueOnMainSync {
            operation(graphics)
        }
    }

    nonisolated private func basicGraphicsColor(_ color: Int) -> VectorTerminalSDK.VTGColor {
        let palette = [
            "#000000", "#60a5fa", "#22c55e", "#06b6d4",
            "#ef4444", "#d946ef", "#f59e0b", "#e5e7eb",
            "#6b7280", "#93c5fd", "#86efac", "#67e8f9",
            "#fca5a5", "#f0abfc", "#fde047", "#ffffff"
        ]
        let index = ((color % palette.count) + palette.count) % palette.count
        return VectorTerminalSDK.VTGColor(palette[index])
    }

    nonisolated private func basicGraphicsColor(_ color: BASICColor) -> VectorTerminalSDK.VTGColor {
        VectorTerminalSDK.VTGColor(color.cssHex)
    }

    @MainActor
    private func nextBasicGraphicsID(_ prefix: String) -> String {
        basicGraphicsOperationID += 1
        return "basic-\(prefix)-\(basicGraphicsOperationID)"
    }

    nonisolated func setScreenMode(_ mode: BASICScreenMode) {
        runOnMainActorSync {
            graphics.setScreenModeIfNeeded(mode)
            graphicsRevision += 1
        }
    }

    nonisolated func setGraphicsColor(_ color: Int) {
        runOnMainActorSync {
            graphics.currentColor = color
        }
    }

    nonisolated func setGraphicsColor(_ color: BASICColor) {
        runOnMainActorSync {
            graphics.currentColor = color.legacyIndex ?? 1
        }
    }

    nonisolated func clearGraphics(color: Int?) {
        runOnMainActorSync {
            graphics.clear(color: color)
            graphicsRevision += 1
            basicGraphicsOperationID = 0
            vtgCanvas.clear()
            vtgCanvas.present()
        }
    }

    nonisolated func setPixel(x: Int, y: Int, color: Int) {
        runOnMainActorSync {
            graphics.setPixel(x: x, y: y, color: color)
            graphicsRevision += 1
            vtgCanvas.pixel(id: nextBasicGraphicsID("pixel"), x: x, y: y, color: basicGraphicsColor(color), layer: nil)
            vtgCanvas.present()
        }
    }

    nonisolated func setPixel(x: Int, y: Int, color: BASICColor) {
        runOnMainActorSync {
            graphics.setPixel(x: x, y: y, color: color.legacyIndex ?? 1)
            graphicsRevision += 1
            vtgCanvas.pixel(id: nextBasicGraphicsID("pixel"), x: x, y: y, color: basicGraphicsColor(color), layer: nil)
            vtgCanvas.present()
        }
    }

    nonisolated func getPixel(x: Int, y: Int) -> Int {
        readGraphicsValue { graphics in
            graphics.getPixel(x: x, y: y)
        }
    }

    nonisolated func drawLine(x1: Int, y1: Int, x2: Int, y2: Int, color: Int) {
        runOnMainActorSync {
            graphics.drawLine(x1: x1, y1: y1, x2: x2, y2: y2, color: color)
            graphicsRevision += 1
            vtgCanvas.line(id: nextBasicGraphicsID("line"), x1: x1, y1: y1, x2: x2, y2: y2, stroke: basicGraphicsColor(color), width: 2, layer: nil)
            vtgCanvas.present()
        }
    }

    nonisolated func drawLine(x1: Int, y1: Int, x2: Int, y2: Int, color: BASICColor) {
        runOnMainActorSync {
            graphics.drawLine(x1: x1, y1: y1, x2: x2, y2: y2, color: color.legacyIndex ?? 1)
            graphicsRevision += 1
            vtgCanvas.line(id: nextBasicGraphicsID("line"), x1: x1, y1: y1, x2: x2, y2: y2, stroke: basicGraphicsColor(color), width: 2, layer: nil)
            vtgCanvas.present()
        }
    }

    nonisolated func drawPath(points: [BASICGraphicsPoint], color: Int) {
        guard points.count >= 2 else { return }
        runOnMainActorSync {
            for index in points.indices.dropLast() {
                let start = points[index]
                let end = points[points.index(after: index)]
                graphics.drawLine(x1: start.x, y1: start.y, x2: end.x, y2: end.y, color: color)
            }
            graphicsRevision += 1
            vtgCanvas.draw(
                id: nextBasicGraphicsID("draw"),
                points: points.map { VTGPoint(x: $0.x, y: $0.y) },
                stroke: basicGraphicsColor(color),
                width: 2,
                lineCap: nil,
                lineJoin: nil,
                layer: nil
            )
            vtgCanvas.present()
        }
    }

    nonisolated func drawPath(points: [BASICGraphicsPoint], color: BASICColor) {
        guard points.count >= 2 else { return }
        runOnMainActorSync {
            for index in points.indices.dropLast() {
                let start = points[index]
                let end = points[points.index(after: index)]
                graphics.drawLine(x1: start.x, y1: start.y, x2: end.x, y2: end.y, color: color.legacyIndex ?? 1)
            }
            graphicsRevision += 1
            vtgCanvas.draw(
                id: nextBasicGraphicsID("draw"),
                points: points.map { VTGPoint(x: $0.x, y: $0.y) },
                stroke: basicGraphicsColor(color),
                width: 2,
                lineCap: nil,
                lineJoin: nil,
                layer: nil
            )
            vtgCanvas.present()
        }
    }

    nonisolated func drawCircle(cx: Int, cy: Int, radius: Int, color: Int) {
        runOnMainActorSync {
            graphics.drawCircle(cx: cx, cy: cy, radius: radius, color: color)
            graphicsRevision += 1
            vtgCanvas.circle(id: nextBasicGraphicsID("circle"), cx: cx, cy: cy, radius: radius, stroke: basicGraphicsColor(color), fill: nil, lineWidth: 2, layer: nil)
            vtgCanvas.present()
        }
    }

    nonisolated func drawCircle(cx: Int, cy: Int, radius: Int, color: BASICColor) {
        runOnMainActorSync {
            graphics.drawCircle(cx: cx, cy: cy, radius: radius, color: color.legacyIndex ?? 1)
            graphicsRevision += 1
            vtgCanvas.circle(id: nextBasicGraphicsID("circle"), cx: cx, cy: cy, radius: radius, stroke: basicGraphicsColor(color), fill: nil, lineWidth: 2, layer: nil)
            vtgCanvas.present()
        }
    }

    nonisolated func drawEllipse(cx: Int, cy: Int, radiusX: Int, radiusY: Int, color: Int) {
        runOnMainActorSync {
            graphics.drawEllipse(cx: cx, cy: cy, radiusX: radiusX, radiusY: radiusY, color: color)
            graphicsRevision += 1
            vtgCanvas.ellipse(id: nextBasicGraphicsID("ellipse"), cx: cx, cy: cy, rx: radiusX, ry: radiusY, stroke: basicGraphicsColor(color), fill: nil, lineWidth: 2, layer: nil)
            vtgCanvas.present()
        }
    }

    nonisolated func drawEllipse(cx: Int, cy: Int, radiusX: Int, radiusY: Int, color: BASICColor) {
        runOnMainActorSync {
            graphics.drawEllipse(cx: cx, cy: cy, radiusX: radiusX, radiusY: radiusY, color: color.legacyIndex ?? 1)
            graphicsRevision += 1
            vtgCanvas.ellipse(id: nextBasicGraphicsID("ellipse"), cx: cx, cy: cy, rx: radiusX, ry: radiusY, stroke: basicGraphicsColor(color), fill: nil, lineWidth: 2, layer: nil)
            vtgCanvas.present()
        }
    }

    nonisolated func paintFill(x: Int, y: Int, color: Int, borderColor: Int?) {
        runOnMainActorSync {
            let changed = graphics.paintFill(x: x, y: y, color: color, borderColor: borderColor)
            graphicsRevision += 1
            for run in BASICGraphicsBatcher.horizontalRuns(from: changed.map { BASICGraphicsPoint(x: $0.x, y: $0.y) }) {
                if run.x1 == run.x2 {
                    vtgCanvas.pixel(id: nextBasicGraphicsID("paint"), x: run.x1, y: run.y, color: basicGraphicsColor(color), layer: nil)
                } else {
                    vtgCanvas.line(id: nextBasicGraphicsID("paint"), x1: run.x1, y1: run.y, x2: run.x2, y2: run.y, stroke: basicGraphicsColor(color), width: 1, layer: nil)
                }
            }
            vtgCanvas.present()
        }
    }

    nonisolated func paintFill(x: Int, y: Int, color: BASICColor, borderColor: BASICColor?) {
        runOnMainActorSync {
            let changed = graphics.paintFill(x: x, y: y, color: color.legacyIndex ?? 1, borderColor: borderColor?.legacyIndex)
            graphicsRevision += 1
            for run in BASICGraphicsBatcher.horizontalRuns(from: changed.map { BASICGraphicsPoint(x: $0.x, y: $0.y) }) {
                if run.x1 == run.x2 {
                    vtgCanvas.pixel(id: nextBasicGraphicsID("paint"), x: run.x1, y: run.y, color: basicGraphicsColor(color), layer: nil)
                } else {
                    vtgCanvas.line(id: nextBasicGraphicsID("paint"), x1: run.x1, y1: run.y, x2: run.x2, y2: run.y, stroke: basicGraphicsColor(color), width: 1, layer: nil)
                }
            }
            vtgCanvas.present()
        }
    }
}
