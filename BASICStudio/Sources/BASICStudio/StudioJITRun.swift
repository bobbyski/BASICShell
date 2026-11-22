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
    ///   belong to the interpreter, and nothing in Studio reads the DWARF
    ///   basicc writes. The panes are left alone rather than shown as empty.
    ///   (Built as WebAssembly instead, ⚡ has the WebAssembly debugger.)
    /// - **No graphics overlay.** VTG reaches Studio's canvas through the
    ///   host; a separate process writes escape sequences to a pipe, and
    ///   nothing here reads them back.
    /// - **No TUI window.** Same reason, and a TUI application would find
    ///   the pipe is not a terminal and say so, exactly as it does under the
    ///   shell without one.
    func jitEditorProgram() {
        runJIT(BASICJIT.Command(), echo: "JIT")
    }

    /// `JIT` typed at the console, already echoed there: what ⚡ does, with
    /// BASICShell's `JIT SWIFT` and `JIT "file.bas"`, which compiles that
    /// file and leaves the editor's program alone (JIT.md).
    func runTypedJIT(_ command: BASICJIT.Command) {
        runJIT(command, echo: nil)
    }

    private func runJIT(_ command: BASICJIT.Command, echo: String?) {
        guard !isProgramRunning, jitProcess == nil else { return }
        // A file is found as LOAD finds one: beside the console's folder.
        let file = command.file.map(consolePath)
        func refuse(_ message: String) {
            selectedPane = .console
            if let echo { echoConsoleCommandForRun(echo) }
            appendJITOutput("JIT: \(message)\n")
            appendJITOutput(prompt)
        }
        if let file, !FileManager.default.fileExists(atPath: file) {
            refuse("\(command.file ?? file) does not exist")
            return
        }
        if effectiveCompiledRunTarget == .webAssembly {
            if command.dialect == "swift" {
                refuse("SWIFT needs ⚡ to build with LLVM; it builds with WebAssembly here, which compiles the traditional dialect")
                return
            }
            runAsWebAssembly(echo: echo, file: file)
            return
        }
        rebuildProgramFromEditor()
        selectedPane = .console
        if let echo { echoConsoleCommandForRun(echo) }
        guard BASICPlatform.runsOtherPrograms else {
            appendJITOutput(BASICPlatform.notAvailableMessage("JIT") + "; RUN still interprets\n")
            appendJITOutput(prompt)
            return
        }
        if file == nil, session.program.isEmpty {
            appendJITOutput("JIT: nothing to compile\n")
            appendJITOutput(prompt)
            return
        }

        // A file is compiled as itself, so its IMPORTs resolve beside it.
        let source = file == nil ? BASICJIT.text(of: session.program) : ""
        let path = file ?? currentProgramURL?.path
        switch BASICJIT.compile(source: source, path: path, dialect: command.dialect) {
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
        wasmRun?.stop()
        // A TUI program run as WebAssembly sits in `app.run` as an
        // interpreted one does, and Stop reaches it the same way.
        if wasmRun != nil, activeTUIDriver != nil {
            BASICTUIApplications.stopAll()
        }
        #if os(macOS)
        nativeRun?.stop()
        jitProcess?.terminate()
        #endif
    }

    private func start(binary: String) {
        #if os(macOS)
        // On a pseudo-terminal, not a pipe.
        //
        // The compiled runtime finds out whether it can draw by asking: it
        // writes VTG's `capabilities?` and waits for the terminal to answer.
        // A pipe answers nothing, so `RTHostCanvas.probe()` came back nil and
        // the first `vtg.` call died with "VectorTerminal graphics are not
        // supported by this host" — on a console that is a VectorTerminalView
        // and could have answered all along. It is the same view, and the
        // same SwiftTerm, that VGTerm gives BASICShell; only the terminal
        // between the two was missing. See ``StudioNativeRun``.
        let size = tuiScreenSize
        let run = StudioNativeRun(
            output: { [weak self] bytes in
                self?.terminalByteSink?(bytes)
            },
            finished: { [weak self] status in
                self?.finishJITRun(status: status ?? 0, binary: binary)
            }
        )
        nativeRun = run
        run.resized(columns: size.width, rows: size.height)
        run.start(binary: binary)
        isJITRunning = true
        #else
        // Unreachable: `BASICJIT.compile` builds nothing on iOS.
        appendJITOutput(BASICPlatform.notAvailableMessage("JIT") + "\n")
        appendJITOutput(prompt)
        #endif
    }

    private func finishJITRun(status: Int32, binary: String) {
        jitProcess = nil
        jitInput = nil
        #if os(macOS)
        nativeRun = nil
        #endif
        isJITRunning = false
        // What the program wrote into a zip project is saved shortly (BASIC-72).
        noteProjectChanges()
        if status != 0 {
            appendJITOutput("JIT: exited with status \(status)\n")
        }
        appendJITOutput(prompt)
        BASICJIT.discard(binary: binary)
    }

    /// Sends a console line to a running compiled program, so `INPUT`
    /// works: the console is the program's terminal for as long as it runs.
    func sendLineToJITProgram(_ line: String) {
        if wasmRun != nil {
            submitCompiledRunLine(line)
            return
        }
        #if os(macOS)
        // On a pseudo-terminal the program reads its own terminal, so a line
        // goes in as typed — with a carriage return, which is what a terminal
        // sends for Return.
        if let run = nativeRun {
            run.send(ArraySlice(Array((line + "\r").utf8)))
            return
        }
        #endif
        guard let input = jitInput else { return }
        input.fileHandleForWriting.write(Data((line + "\n").utf8))
    }
}
