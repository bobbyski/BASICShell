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
//  through its key queue.
//

import BASICCompilerKit
import BASICCore
import BASICWasm
import BASICWasmRunner
import Foundation

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
        run.start()
    }

    /// The end of a WebAssembly run: what it ended with, then the prompt.
    func finishWasmRun(_ ending: StudioWasmRun.Ending) {
        wasmRun = nil
        isJITRunning = false
        setCompiledRunInputActive(false)
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
    private let source: String
    private let name: String
    private let directory: String
    private let lock = NSLock()
    private var runner: WasmRunner?
    private var stopped = false

    init(model: StudioModel, source: String, name: String, directory: String) {
        self.model = model
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
        do {
            let ir = try StudioCompiler.llvmIR(source: source, name: name)
            program = try WasmTranslator.translate(llvmIR: ir)
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

        switch runner.run(host: self) {
        case .finished: return .finished
        case .failed: return .failed
        case .stopped: return .stopped
        case .notLoaded(let reason): return .refused(["WebAssembly: \(reason)"])
        case .trapped(let reason): return .refused(["WebAssembly: the module failed: \(reason)"])
        }
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
}
