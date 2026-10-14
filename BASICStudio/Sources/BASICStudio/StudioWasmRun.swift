//
//  StudioWasmRun.swift
//  BASICStudio
//
//  Running a program as WebAssembly in JavaScriptCore (BASIC-45): compiled in
//  process by basicc's core, translated by BASICWasm, and run by
//  BASICWasmRunner against the native runtime, with Studio's console as its
//  console. On iPhone and iPad this is how every program runs; on the Mac it
//  is ⚡ when Settings ▸ Console says WebAssembly.
//
//  The console is the interpreter's: text goes through the model's print,
//  INPUT through its readLine (so the same line editing and Stop), INKEY$
//  through its key queue. So is the rest of what an interpreted program has:
//  its windows (the same AUI bridge), its canvas (the console's VTG view),
//  its touch controls and held keys, and what the user does, which the
//  session sends to the compiled program for the length of the run.
//
//  And so is its debugger (BASIC-46). With breakpoints set, the Debug pane
//  open, or a run started with Step, the program is built for debugging: it
//  stops at breakpoints, steps, pauses, and fills the same panes. A stopped
//  run waits on its own thread; Continue or a step lets it go on.
//

import BASICCompilerKit
import BASICCore
import BASICWasm
import BASICWasmRunner
import Foundation
import VectorTerminalSDK

extension StudioModel {
    /// Compiles the editor's program to WebAssembly and runs it. `echo` is the
    /// command shown at the prompt: RUN or JIT. `debugCommand` starts it in
    /// the debugger: `.stepInto` stops at its first statement.
    /// Runs the editor's program as WebAssembly, or `file` when one is given
    /// (a typed `JIT "file.bas"`), echoing `echo` at the prompt when the
    /// console has not already.
    func runAsWebAssembly(echo: String?, debugCommand: WasmDebugger.Command? = nil, file: String? = nil) {
        guard !isProgramRunning, !isJITRunning else { return }
        rebuildProgramFromEditor()
        selectedPane = .console
        if let echo { echoConsoleCommandForRun(echo) }
        let compiled = BASICJIT.compiledText(of: session.program)
        var source = compiled.text
        var editorLines: [Int?]? = compiled.editorLines
        var name = currentProgramURL.map { $0.deletingPathExtension().lastPathComponent } ?? "program"
        // Where the text belongs, so its IMPORTs are found as the
        // interpreter finds them, and the project it is in.
        var path = compiledRunSourcePath
        if let file {
            source = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            editorLines = nil
            name = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
            path = file
        }
        let projectRoot = projectDirectoryURL.flatMap { project in
            path.hasPrefix(project.standardizedFileURL.path + "/") ? project.path : nil
        }
        // Built for the debugger when it will be wanted: a slower build, so
        // not for every run. Not for a named file: the debugger shows the
        // editor's program, and that file is not it.
        let debugging = file == nil
            && (debugCommand != nil || activeBreakpoints.contains(where: \.isEnabled) || inspectorPane == .debug)
        let run = StudioWasmRun(model: self, source: source, name: name, path: path, projectRoot: projectRoot,
                                directory: programWorkingDirectoryPath,
                                debugCommand: debugging ? debugCommand ?? .run : nil,
                                editorLines: editorLines)
        clearWasmDebuggerState()
        wasmRun = run
        isJITRunning = true
        setCompiledRunInputActive(true)
        beginCompiledRunGraphics()
        // The console's mouse, resizes, gamepads and the program's windows
        // post to the session; for this run they are the compiled program's.
        session.sendsHostEventsToCompiledProgram = true
        run.start()
    }

    /// The end of a WebAssembly run: what it ended with, then the prompt.
    func finishWasmRun(_ ending: StudioWasmRun.Ending) {
        wasmRun = nil
        clearWasmDebuggerState()
        isJITRunning = false
        setCompiledRunInputActive(false)
        session.sendsHostEventsToCompiledProgram = false
        endCompiledRunGraphics(stoppedShort: ending != .finished)
        switch ending {
        case .finished, .failed, .stopped:
            break
        case .refused(let lines):
            for line in lines { appendJITOutput(line + "\n") }
        }
        appendJITOutput(prompt)
    }

    // MARK: The debugger (BASIC-46)

    /// Whether Pause can stop the run in progress: one built for debugging.
    var isWasmRunDebuggable: Bool { wasmRun?.debugger != nil }

    /// The run stopped: where, and what it holds, into the debugger's panes.
    func wasmRunPaused(_ pause: WasmDebugger.Pause, in run: StudioWasmRun) {
        guard run === wasmRun else { return }
        isProgramPaused = true
        let lines = programText.split(separator: "\n", omittingEmptySubsequences: false)
        let line = pause.location.lineNumber
        // Only a line of the editor's own text: a file it imports has its
        // own line numbers.
        let inEditor = lines.indices.contains(line - 1)
            && lines[line - 1].trimmingCharacters(in: .whitespaces) == pause.source.trimmingCharacters(in: .whitespaces)
        debuggerExecutionLine = inEditor ? line : nil
        debuggerCallStack = pause.callStack
        debuggerFrameLocalVariables = pause.frameLocals
        debuggerLocalVariables = pause.frameLocals.first ?? []
        debuggerSelectedCallStackFrameIndex = pause.callStack.first?.index
        debuggerGlobalVariables = pause.globals
        appendLog(level: "PAUSE", issuer: .basic, text: "WebAssembly run paused at \(line)")
        showDebuggerForStop()
    }

    /// Continue or a step, for a stopped run.
    func resumeWasmRun(_ command: WasmDebugger.Command) {
        guard isProgramPaused, let run = wasmRun else { return }
        isProgramPaused = false
        if !showsLiveExecutionLine { debuggerExecutionLine = nil }
        run.resume(command)
    }

    /// Breakpoints changed: a run in the debugger stops at the new ones.
    func updateWasmRunBreakpoints() {
        wasmRun?.setBreakpoints(activeBreakpoints, programText: programText)
    }

    private func clearWasmDebuggerState() {
        isProgramPaused = false
        debuggerExecutionLine = nil
        debuggerCallStack = []
        debuggerSelectedCallStackFrameIndex = nil
        debuggerLocalVariables = []
        debuggerFrameLocalVariables = []
    }
}

/// One WebAssembly run, on a thread of its own.
final class StudioWasmRun: WasmHost, @unchecked Sendable {
    enum Ending: Equatable {
        case finished
        case failed
        case stopped
        /// It never ran: what the compiler, translator or runner said.
        case refused([String])
    }

    private weak var model: StudioModel?
    /// The console's canvas, for this run's graphics.
    private let canvas: VectorTerminalCanvas
    private let source: String
    private let name: String
    /// The file the source belongs to, and the project it is in, for IMPORT.
    private let path: String
    private let projectRoot: String?
    private let directory: String
    private let lock = NSLock()
    private var runner: WasmRunner?
    private var stopped = false
    /// The map's entries for this run (BASIC-45), made once.
    private lazy var frameworkEntries = StudioFrameworkMap.entries(for: model, title: name)
    /// The run's debugger, when it is built for one (BASIC-46).
    var debugger: WasmDebugger? {
        lock.lock()
        defer { lock.unlock() }
        return debuggerStorage
    }
    private var debuggerStorage: WasmDebugger?

    @MainActor
    init(model: StudioModel, source: String, name: String, path: String, projectRoot: String?, directory: String,
         debugCommand: WasmDebugger.Command? = nil, editorLines: [Int?]? = nil) {
        self.model = model
        canvas = model.makeCompiledRunCanvas()
        self.source = source
        self.name = name
        self.path = path
        self.projectRoot = projectRoot
        self.directory = directory
        if let debugCommand {
            let debugger = WasmDebugger(command: debugCommand)
            debugger.spellings = Self.spellings(in: source)
            // The compiled text leaves out the editor's blank lines.
            debugger.editorLines = editorLines
            debugger.onPause = { [weak self, weak model] pause in
                guard let self else { return }
                Task { @MainActor in model?.wasmRunPaused(pause, in: self) }
            }
            debuggerStorage = debugger
            setBreakpoints(model.activeBreakpoints, programText: model.programText)
        }
    }

    /// Where the debugger stops: the enabled breakpoints, on lines that read
    /// as the editor's do.
    func setBreakpoints(_ breakpoints: [BASICBreakpoint], programText: String) {
        debugger?.setBreakpoints(breakpoints.filter(\.isEnabled).map(\.location),
                                 programLines: programText.components(separatedBy: "\n"))
    }

    func pause() { debugger?.pause() }

    func resume(_ command: WasmDebugger.Command) { debugger?.resume(command) }

    /// How the program spells each name, by its uppercased form: the first
    /// time it is written. basicc keeps only the uppercased one.
    static func spellings(in source: String) -> [String: String] {
        var spellings: [String: String] = [:]
        let pattern = try! NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]*[$%&!#]?")
        let text = source as NSString
        for match in pattern.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            let word = text.substring(with: match.range)
            let key = word.uppercased()
            if spellings[key] == nil { spellings[key] = word }
        }
        return spellings
    }

    /// Starts the run. The front end and the runtime both recurse, so the
    /// thread gets the stack the interpreter's lane has.
    func start() {
        let thread = Thread { [self] in
            let ending = self.go()
            Task { @MainActor [model] in model?.finishWasmRun(ending) }
        }
        thread.name = "BASIC WebAssembly run"
        thread.stackSize = 64 << 20
        thread.start()
    }

    /// Stop: the module stops at its next loop, and an INPUT waiting wakes.
    func stop() {
        lock.lock()
        stopped = true
        let runner = runner
        lock.unlock()
        runner?.requestStop()
        model?.setCompiledRunInputActive(false)
        model?.setCompiledRunInputActive(true)
    }

    private func go() -> Ending {
        let program: WasmProgram
        let started = DispatchTime.now()
        var translated = started
        do {
            // Its ActiveUI windows are Studio's.
            func ir(debugInfo: Bool) throws -> String {
                try StudioCompiler.llvmIR(source: source, name: name, hostedActiveUI: true,
                                          path: path, projectRoot: projectRoot, debugInfo: debugInfo)
            }
            var debuggable: WasmProgram?
            if debugger != nil {
                debuggable = try? WasmTranslator.translate(llvmIR: try ir(debugInfo: true), debug: true)
            }
            let compiled = DispatchTime.now()
            if let debuggable {
                program = debuggable
            } else {
                // A program the debugger cannot look into still runs, as
                // it would without one.
                lock.lock()
                debuggerStorage = nil
                lock.unlock()
                program = try WasmTranslator.translate(llvmIR: try ir(debugInfo: false))
            }
            translated = DispatchTime.now()
            Self.time("compile \(Self.milliseconds(started, compiled)) ms, translate \(Self.milliseconds(compiled, translated)) ms")
        } catch let error as CompileError {
            return .refused(error.diagnostics.map(\.rendered))
        } catch {
            return .refused(["WebAssembly: \(error)"])
        }
        let runner = WasmRunner(program: program)
        runner.debugger = debugger
        // A CHAIN's program is found in the program's folder, as the
        // interpreter finds it, and compiled as a chain target (A7.5).
        runner.chainProgram = { [directory, projectRoot] file in
            let names = (file as NSString).pathExtension.isEmpty ? [file + ".bas", file] : [file]
            guard let source = names.map({ (directory as NSString).appendingPathComponent($0) })
                .first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                throw StudioChainError(errorDescription: "File not found: \(file)")
            }
            let text = try String(contentsOfFile: source, encoding: .utf8)
            return try WasmTranslator.translate(llvmIR: try StudioCompiler.llvmIR(
                source: text, name: ((source as NSString).lastPathComponent as NSString).deletingPathExtension,
                hostedActiveUI: true, path: source, projectRoot: projectRoot, chainTarget: true))
        }
        lock.lock()
        self.runner = runner
        let stopEarly = stopped
        lock.unlock()
        if stopEarly { return .stopped }

        // The runtime's files are relative to the process's folder: the
        // program's, for this run.
        let previous = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(directory)
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }

        let outcome = runner.run(host: self)
        Self.time("run \(Self.milliseconds(translated, DispatchTime.now())) ms")
        switch outcome {
        case .finished: return .finished
        case .failed: return .failed
        case .stopped: return .stopped
        case .notLoaded(let reason): return .refused(["WebAssembly: \(reason)"])
        case .trapped(let reason): return .refused(["WebAssembly: the module failed: \(reason)"])
        }
    }

    /// With `BASICSTUDIO_WASM_TIMING` set, how long each step took, on
    /// stderr: for comparing engines and devices (WASM_BACKEND.md), never
    /// in the console.
    private static func time(_ text: String) {
        guard ProcessInfo.processInfo.environment["BASICSTUDIO_WASM_TIMING"] != nil else { return }
        FileHandle.standardError.write(Data("BASIC-45 timing: \(text)\n".utf8))
    }

    private static func milliseconds(_ from: DispatchTime, _ to: DispatchTime) -> String {
        String(format: "%.1f", Double(to.uptimeNanoseconds - from.uptimeNanoseconds) / 1_000_000)
    }

    // MARK: WasmHost — the interpreter's console

    func write(_ text: String) {
        model?.print(text, terminator: "")
    }

    func readLine(prompt: String) -> String? {
        model?.readLine(prompt: prompt)
    }

    func inkey() -> String {
        model?.readKey() ?? ""
    }

    /// Studio's windows, canvas, touch controls and keys, which the
    /// interpreter's programs use too.
    var services: WasmHostServices {
        guard let model else { return WasmHostServices() }
        var services = WasmHostServices(
            windows: model,
            touchControls: model,
            canvas: canvas,
            canvasSize: { [weak model] in model?.compiledRunCanvasSize() ?? (width: 0, height: 0) },
            screenSize: { [weak model] in (columns: model?.screenColumns() ?? 80, rows: model?.screenRows() ?? 25) },
            keyDown: { [weak model] name in model?.isKeyDown(name) ?? nil },
            readKey: { [weak model] in model?.readBlockingKey() },
            tui: model
        )
        // The frameworks Studio contains, for a program that imports them.
        services.entries = frameworkEntries
        return services
    }
}

/// Why a `CHAIN` in a WebAssembly run could not have its program.
private struct StudioChainError: LocalizedError {
    let errorDescription: String?
}
