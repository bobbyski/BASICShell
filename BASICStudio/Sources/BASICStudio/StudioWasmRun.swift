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

import BASICCompilerKit
import BASICCore
import BASICWasm
import BASICWasmRunner
import Foundation
import VectorTerminalSDK

extension StudioModel {
    /// Compiles the editor's program to WebAssembly and runs it. `echo` is the
    /// command shown at the prompt: RUN or JIT.
    func runAsWebAssembly(echo: String) {
        guard !isProgramRunning, !isJITRunning else { return }
        rebuildProgramFromEditor()
        selectedPane = .console
        echoConsoleCommandForRun(echo)
        let source = BASICJIT.text(of: session.program)
        let name = currentProgramURL.map { $0.deletingPathExtension().lastPathComponent } ?? "program"
        let run = StudioWasmRun(model: self, source: source, name: name, directory: programWorkingDirectoryPath)
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
    private let directory: String
    private let lock = NSLock()
    private var runner: WasmRunner?
    private var stopped = false

    init(model: StudioModel, source: String, name: String, directory: String) {
        self.model = model
        canvas = model.makeCompiledRunCanvas()
        self.source = source
        self.name = name
        self.directory = directory
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
            let ir = try StudioCompiler.llvmIR(source: source, name: name, hostedActiveUI: true)
            let compiled = DispatchTime.now()
            program = try WasmTranslator.translate(llvmIR: ir)
            translated = DispatchTime.now()
            Self.time("compile \(Self.milliseconds(started, compiled)) ms, translate \(Self.milliseconds(compiled, translated)) ms")
        } catch let error as CompileError {
            return .refused(error.diagnostics.map(\.rendered))
        } catch {
            return .refused(["WebAssembly: \(error)"])
        }
        let runner = WasmRunner(program: program)
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
        return WasmHostServices(
            windows: model,
            touchControls: model,
            canvas: canvas,
            canvasSize: { [weak model] in model?.compiledRunCanvasSize() ?? (width: 0, height: 0) },
            screenSize: { [weak model] in (columns: model?.screenColumns() ?? 80, rows: model?.screenRows() ?? 25) },
            keyDown: { [weak model] name in model?.isKeyDown(name) ?? nil },
            readKey: { [weak model] in model?.readBlockingKey() },
            tui: model
        )
    }
}
