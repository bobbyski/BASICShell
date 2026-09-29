//
//  StudioHarness.swift
//  BASICStudioTests
//
//  Drives a StudioModel with no window, the way the panes do.
//

import Foundation
import Testing
@testable import BASICStudio

/// A ``StudioModel`` with no window: load a program, run it, answer its
/// `INPUT`, and read back what a pane would show.
///
/// Every call here is one a pane or a menu already makes, so what passes here
/// passes under either shell. That is the point of it: these assertions are the
/// "before" that ACTIVEUI_TRANSITION.md's P2 and P3 are measured against.
///
/// The model is built from ``StudioLaunchOptions/headless``, so the settings in
/// Application Support are neither read nor written.
@MainActor
final class StudioHarness {
    /// The model under test.
    let model: StudioModel

    /// A fresh model with `program` in the editor.
    init(program: String = "") {
        model = StudioModel(launch: .headless)
        model.programText = program
    }

    /// The Run button: runs the editor's program and waits until it stops,
    /// whether it finished, failed, or paused at a breakpoint.
    func run(timeout: Duration = .seconds(20)) async throws {
        model.runEditorProgram()
        try await waitUntilStopped(timeout: timeout)
    }

    /// Types `command` at the console prompt and presses Return, then waits
    /// for anything it started to stop.
    func submit(_ command: String, timeout: Duration = .seconds(20)) async throws {
        model.command = command
        model.submitCommand()
        try await waitUntilStopped(timeout: timeout)
    }

    /// Answers the `INPUT` the running program is waiting on. Waits for its
    /// prompt, `prompt`, to reach the console first.
    func answer(_ line: String, afterPrompt prompt: String, timeout: Duration = .seconds(20)) async throws {
        try await waitUntil("the prompt \(prompt.debugDescription)", timeout: timeout) {
            model.consoleText.hasSuffix(prompt)
        }
        model.handleTerminalInput([.submit(line)])
    }

    /// Waits for the running program to finish or pause.
    func waitUntilStopped(timeout: Duration = .seconds(20)) async throws {
        try await waitUntil("the program to stop", timeout: timeout) { !model.isProgramRunning }
    }

    /// Yields the main actor until `condition` holds, so the interpreter
    /// thread's `DispatchQueue.main` hops can land.
    func waitUntil(_ what: String, timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else {
                throw HarnessTimeout(waitingFor: what, console: model.consoleText)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The console from the last `RUN` echo on: what the last run printed,
    /// then the prompt it left.
    var lastRunOutput: String {
        guard let range = model.consoleText.range(of: "RUN\n", options: .backwards) else {
            return model.consoleText
        }
        return String(model.consoleText[range.upperBound...])
    }
}

/// A wait that ran out, with the console as it stood.
struct HarnessTimeout: Error, CustomStringConvertible {
    let waitingFor: String
    let console: String

    var description: String {
        "timed out waiting for \(waitingFor); the console ends:\n\(console.suffix(400))"
    }
}
