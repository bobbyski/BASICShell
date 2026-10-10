//
//  StudioPageAndLaunchTests.swift
//  BASICStudioTests
//
//  The command line reads as it always has.
//

import Foundation
import Testing
@testable import BASICStudio

@Suite("Launch options")
struct StudioLaunchOptionsTests {
    @Test("No arguments: no program")
    func empty() {
        #expect(StudioLaunchOptions.parse([]) == StudioLaunchOptions())
    }

    @Test("The first argument is the program, as it always was")
    func program() {
        let options = StudioLaunchOptions.parse(["~/demo.bas", "ignored"])
        #expect(options.programPath == "~/demo.bas")
    }

    @Test("--activeui, from when there were two shells, is ignored wherever it appears, and is not a path")
    func activeUIFlag() {
        let before = StudioLaunchOptions.parse(["--activeui", "demo.bas"])
        let after = StudioLaunchOptions.parse(["demo.bas", "--activeui"])
        #expect(before.programPath == "demo.bas")
        #expect(after == before)
        #expect(StudioLaunchOptions.parse(["--activeui"]) == StudioLaunchOptions())
    }

    @Test("Xcode's own arguments are passed through untouched, as before")
    func xcodeArguments() {
        let options = StudioLaunchOptions.parse(["-NSDocumentRevisionsDebugMode", "YES"])
        #expect(options.programPath == "-NSDocumentRevisionsDebugMode")
    }

    @Test("--walk opens a stated state on default settings, saving nothing; its values are not the program")
    func walk() {
        let options = StudioLaunchOptions.parse([
            "--activeui", "--walk", "--pane", "editor", "--inspector", "debug", "--command-bar",
            "--breakpoint", "2", "--breakpoint", "5", "--settings", "Font", "--project", "~/demos", "demo.bas",
        ])
        #expect(options.programPath == "demo.bas")
        #expect(!options.persistsSettings)
        let walk = options.walk
        #expect(walk?.pane == .editor && walk?.inspector == .debug && walk?.showsCommandBar == true)
        #expect(walk?.breakpoints == [2, 5])
        #expect(walk?.settingsTab == "font" && walk?.settingsTabIndex == 1)
        #expect(walk?.projectPath == "~/demos")
        #expect(StudioLaunchOptions.parse(["demo.bas"]).walk == nil)
        // The program can come from the environment, where AppKit cannot see it.
        let fromEnvironment = StudioLaunchOptions.parse(["--walk"], environment: ["BASICSTUDIO_PROGRAM": "env.bas"])
        #expect(fromEnvironment.programPath == "env.bas")
        #expect(StudioLaunchOptions.parse([], environment: ["BASICSTUDIO_PROGRAM": "env.bas"]).programPath == nil)
    }

    @Test("Headless models persist nothing")
    func headless() {
        #expect(!StudioLaunchOptions.headless.persistsSettings)
        #expect(StudioLaunchOptions.headless.programPath == nil)
    }
}
