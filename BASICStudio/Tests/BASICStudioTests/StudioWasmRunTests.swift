//
//  StudioWasmRunTests.swift
//  BASICStudioTests
//
//  BASIC-45: ⚡ with Settings ▸ Console ▸ "⚡ builds with" set to WebAssembly
//  compiles the program in Studio, runs it in JavaScriptCore, and uses
//  Studio's console as the interpreter does: output, INPUT, errors and Stop.
//  Its ActiveUI windows are Studio's, as an interpreted program's are.
//

import ActiveUI
import Foundation
import Testing
@testable import BASICStudio

@MainActor
@Suite("BASIC-45 · ⚡ as WebAssembly, in Studio", .serialized)
struct StudioWasmRunTests {
    private func start(_ program: String) -> StudioHarness {
        let studio = StudioHarness(program: program)
        studio.model.compiledRunTarget = .webAssembly
        studio.model.jitEditorProgram()
        return studio
    }

    private func waitUntilFinished(_ studio: StudioHarness) async throws {
        try await studio.waitUntil("the WebAssembly run to finish", timeout: .seconds(60)) { !studio.model.isJITRunning }
    }

    @Test("Prints, takes INPUT from the console, and returns to the prompt")
    func printsAndAsks() async throws {
        let studio = start("""
        print "Hello from WebAssembly"
        input "Name? "; who$
        print "Hi, "; who$; "! "; 6 * 7
        """)
        try await studio.answer("Ada", afterPrompt: "Name? ")
        try await waitUntilFinished(studio)
        let console = studio.model.consoleText
        #expect(console.contains("JIT\nHello from WebAssembly\nName? "), "\(console)")
        #expect(console.contains("Hi, Ada! 42\n"), "\(console)")
        #expect(console.hasSuffix(studio.model.prompt))
    }

    @Test("A runtime error is reported as the interpreter reports it")
    func error() async throws {
        let studio = start("print \"before\"\nprint 1 / 0")
        try await waitUntilFinished(studio)
        #expect(studio.model.consoleText.contains("before\n"))
        #expect(studio.model.consoleText.contains("Division by zero"), "\(studio.model.consoleText)")
    }

    @Test("Stop ends a loop that never would")
    func stop() async throws {
        let studio = start("n = 0\nwhile 1\n    n = n + 1\nwend")
        try await studio.waitUntil("the run to start") { studio.model.isJITRunning }
        try await Task.sleep(for: .milliseconds(300))
        studio.model.stopProgram()
        try await waitUntilFinished(studio)
        #expect(studio.model.consoleText.contains("Break at "), "\(studio.model.consoleText.suffix(200))")
    }

    @Test("A program that does not compile says why, and runs nothing")
    func refused() async throws {
        let studio = start("print \"unterminated")
        try await waitUntilFinished(studio)
        #expect(studio.model.consoleText.contains("Unterminated string"), "\(studio.model.consoleText.suffix(300))")
    }

    /// The first control of `type` the program made.
    private func control<T: AUIView>(_ type: T.Type, in bridge: StudioAUIBridge) -> (Int, T)? {
        bridge.views.sorted { $0.key < $1.key }.lazy.compactMap { id, view in (view as? T).map { (id, $0) } }.first
    }

    @Test("A program's window: clicks and a selection reach its handlers, run() returns when it closes")
    func window() async throws {
        let studio = StudioHarness(program: """
        GLOBAL clicks = 0
        let w = AUIWindow("Picker")
        let l = AUILabel("none yet")
        let b = AUIButton("Count")
        let li = AUIList()
        li.add("Ada")
        li.add("Grace")
        w.add(l)
        w.add(b)
        w.add(li)
        b.onclick("Counted")
        on aui select call Picked
        w.run()
        print "clicks "; clicks; " label "; l.text$()

        function Counted()
            clicks = clicks + 1
        end function

        function Picked(event as BASICAUIEvent)
            l.text("picked " + event.Text$)
        end function
        """)
        let bridge = studio.model.auiBridge
        bridge.showsWindows = false
        studio.model.compiledRunTarget = .webAssembly
        studio.model.jitEditorProgram()
        try await studio.waitUntil("the window", timeout: .seconds(60)) {
            (try? bridge.perform(.isOpen(id: 1))) == .flag(true) && bridge.views.count == 3
        }
        let (_, button) = try #require(control(AUIButton.self, in: bridge))
        button.onClick?()
        button.onClick?()
        let (_, list) = try #require(control(AUITable.self, in: bridge))
        #expect(list.rowCount() == 2)
        list.selectedRows = [1]
        list.onSelectionChange?([1])
        let (_, label) = try #require(control(AUILabel.self, in: bridge))
        try await studio.waitUntil("the handler") { label.text == "picked Grace" }
        _ = try bridge.perform(.close(id: 1))
        try await waitUntilFinished(studio)
        #expect(studio.model.consoleText.contains("clicks 2 label picked Grace"), "\(studio.model.consoleText.suffix(300))")
        #expect(bridge.views.isEmpty, "the program's controls go when it ends")
    }

    @Test("On the Mac the choice is the person's, and LLVM is the default")
    func choice() {
        #expect(StudioCompiledRunTarget.isChoosable)
        let studio = StudioHarness()
        #expect(studio.model.compiledRunTarget == .llvm)
        #expect(studio.model.effectiveCompiledRunTarget == .llvm)
        studio.model.compiledRunTarget = .webAssembly
        #expect(studio.model.effectiveCompiledRunTarget == .webAssembly)
    }
}
