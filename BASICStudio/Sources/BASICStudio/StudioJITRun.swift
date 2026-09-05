//
//  StudioJITRun.swift
//  BASICStudio
//
//  Running the program compiled rather than interpreted.
//

import BASICCore
import Foundation

extension StudioModel {

    /// Compiles the program in the editor and runs the binary, streaming
    /// what it prints into the console.
    ///
    /// `Run` interprets and always will. This is the same program going the
    /// other way — the compiler is held to the interpreter's output byte for
    /// byte, so which one you pick is a speed decision rather than a
    /// semantic one, and on arithmetic it is about a hundred times.
    ///
    /// Three things it does not do, all for the same reason: a compiled
    /// program is a separate process with no interpreter inside it.
    ///
    /// - **No debugger.** Breakpoints, stepping, and the variable panes
    ///   belong to the interpreter, and there is no DWARF yet for anything
    ///   else to read. The panes are left alone rather than shown as empty.
    /// - **No graphics overlay.** VTG reaches Studio's canvas through the
    ///   host; a separate process writes escape sequences to a pipe, and
    ///   nothing here reads them back.
    /// - **No TUI window.** Same reason, and a TUI application would find
    ///   the pipe is not a terminal and say so, exactly as it does under the
    ///   shell without one.
    func jitEditorProgram() {
        guard !isProgramRunning, jitProcess == nil else { return }
        rebuildProgramFromEditor()
        selectedPane = .console
        echoConsoleCommandForJIT()

        let source = BASICJIT.text(of: session.program)
        let path = currentProgramURL?.path
        switch BASICJIT.compile(source: source, path: path) {
        case .unavailable(let reason):
            appendJITOutput("JIT: \(reason)\n")
            appendJITOutput(prompt)
        case .refused(let diagnostics):
            for line in diagnostics { appendJITOutput(line + "\n") }
            appendJITOutput(prompt)
        case .built(let binary):
            start(binary: binary)
        }
    }

    /// Stops a compiled run, as Stop does an interpreted one.
    func stopJITProgram() {
        jitProcess?.terminate()
    }

    private func start(binary: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = input

        // Read as it comes rather than at the end, so a long program shows
        // its work the way an interpreted one does.
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.appendJITOutput(text) }
        }

        process.terminationHandler = { [weak self] finished in
            output.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            Task { @MainActor in
                self?.finishJITRun(status: status, binary: binary)
            }
        }

        do {
            try process.run()
        } catch {
            appendJITOutput("JIT: \(error)\n")
            appendJITOutput(prompt)
            BASICJIT.discard(binary: binary)
            return
        }
        jitProcess = process
        jitInput = input
        isJITRunning = true
    }

    private func finishJITRun(status: Int32, binary: String) {
        jitProcess = nil
        jitInput = nil
        isJITRunning = false
        if status != 0 {
            appendJITOutput("JIT: exited with status \(status)\n")
        }
        appendJITOutput(prompt)
        BASICJIT.discard(binary: binary)
    }

    /// Sends a console line to a running compiled program, so `INPUT`
    /// works: the console is the program's terminal for as long as it runs.
    func sendLineToJITProgram(_ line: String) {
        guard let input = jitInput else { return }
        input.fileHandleForWriting.write(Data((line + "\n").utf8))
    }
}
