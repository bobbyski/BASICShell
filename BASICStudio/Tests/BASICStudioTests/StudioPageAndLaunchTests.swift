//
//  StudioPageAndLaunchTests.swift
//  BASICStudioTests
//
//  The editor page parses, and the command line reads as it always has.
//

import Foundation
import JavaScriptCore
import Testing
@testable import BASICStudio

@Suite("Monaco editor page")
@MainActor
struct MonacoPageTests {
    /// The page's own inline script: everything between the last `<script>`
    /// and its `</script>`. The first script tag is Monaco's loader, by URL.
    private static var inlineScript: String? {
        let html = MonacoEditorController.html
        guard let open = html.range(of: "<script>", options: .backwards),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex) else {
            return nil
        }
        return String(html[open.upperBound..<close.lowerBound])
    }

    /// From 055a04c to its fix, the grammar's `tokenizer` block was missing
    /// and a stray `],` stood in its place, so the whole script failed to
    /// parse and the editor never appeared. Nothing reported it anywhere.
    @Test("E2 · The editor page's script parses")
    func scriptParses() throws {
        let script = try #require(Self.inlineScript)
        let context = try #require(JSContext())
        let source = JSStringCreateWithUTF8CString(script)
        defer { JSStringRelease(source) }
        var exception: JSValueRef?
        let parses = JSCheckScriptSyntax(context.jsGlobalContextRef, source, nil, 1, &exception)
        let message = exception.map { JSValue(jsValueRef: $0, in: context)?.toString() ?? "?" } ?? ""
        #expect(parses, "\(message)")
    }

    @Test("E3 · The BASIC grammar colors keywords, strings, comments and line numbers")
    func grammarHasATokenizer() throws {
        let script = try #require(Self.inlineScript)
        #expect(script.contains("tokenizer: {"))
        for scope in ["keyword.control.aibasic", "string.quote.aibasic", "comment.basic.aibasic", "number.line.aibasic", "predefined.aibasic"] {
            #expect(script.contains(scope), "no rule yields \(scope)")
        }
    }
}

@Suite("Launch options")
struct StudioLaunchOptionsTests {
    @Test("No arguments: the SwiftUI shell, no program")
    func empty() {
        #expect(StudioLaunchOptions.parse([]) == StudioLaunchOptions())
    }

    @Test("The first argument is the program, as it always was")
    func program() {
        let options = StudioLaunchOptions.parse(["~/demo.bas", "ignored"])
        #expect(options.programPath == "~/demo.bas")
        #expect(options.shell == .swiftUI)
    }

    @Test("--activeui picks the ActiveUI shell wherever it appears, and is not a path")
    func activeUIFlag() {
        let before = StudioLaunchOptions.parse(["--activeui", "demo.bas"])
        let after = StudioLaunchOptions.parse(["demo.bas", "--activeui"])
        #expect(before.shell == .activeUI)
        #expect(before.programPath == "demo.bas")
        #expect(after == before)
    }

    @Test("The last shell flag wins")
    func lastFlagWins() {
        #expect(StudioLaunchOptions.parse(["--activeui", "--swiftui"]).shell == .swiftUI)
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
        #expect(options.shell == .activeUI)
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
