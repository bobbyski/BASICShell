//
//  ActiveUISourceEditorTests.swift
//  BASICStudioTests
//
//  The ActiveUI shell's source editor, where the SwiftUI shell has Monaco.
//

import AppKit
import Foundation
import SwiftyCodeEditor
import Testing
@testable import BASICStudio

@Suite("ActiveUI source editor", .serialized)
@MainActor
struct ActiveUISourceEditorTests {
    /// The scope each piece of `line` is colored as.
    func scopes(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        for token in SourceEditorAUI.highlighter.tokens(for: line, lineNumber: 1) {
            let text = (line as NSString).substring(with: NSRange(location: token.range.lowerBound, length: token.range.count))
            result[text.trimmingCharacters(in: .whitespaces)] = token.scope
        }
        return result
    }

    @Test("E1 · BASIC is colored in Monaco's categories, from the interpreter's own word lists")
    func highlighter() {
        let line = scopes(#"FOR i = 1 TO 10: PRINT LEFT$(name$, 2), "hi" ' done"#)
        #expect(line["FOR"] == "keyword.control")
        #expect(line["PRINT"] == "keyword.io")
        #expect(line["LEFT$"] == "predefined")
        #expect(line["\"hi\""] == "string")
        #expect(line["' done"] == "comment.basic")
        #expect(line["10"] == "number")
        #expect(scopes("DIM a AS INTEGER")["INTEGER"] == "keyword.type")
        #expect(scopes("REM a note")["REM a note"] == "comment.basic")
        // Not keywords inside a longer name, a string or a comment.
        #expect(scopes("REMAINDER = 1")["REMAINDER"] == nil)
        #expect(scopes(#"x$ = "PRINT""#)["PRINT"] == nil)
    }

    @Test("T13 · The three themes are Monaco's colors, keyed by what the highlighter emits")
    func themes() {
        for theme in EditorTheme.allCases {
            let colors = SourceEditorAUI.theme(for: theme)
            #expect(colors.name == theme.label)
            #expect(colors.style(for: "keyword.io") != colors.defaultStyle)
            #expect(colors.style(for: "comment.basic") != colors.style(for: "string"))
        }
        #expect(SourceEditorAUI.theme(for: .light).background != SourceEditorAUI.theme(for: .dark).background)
    }

    @Test("E4 E5 E8 · The main editor: the text, editable, diagnostics, and the gutter as set")
    func mainEditor() throws {
        let studio = StudioHarness(program: "PRINT (")
        studio.model.isEditorGutterVisible = true
        let source = SourceEditorAUI()
        source.sync(.mainEditor(studio.model))
        #expect(source.editor.text == "PRINT (")
        #expect(source.editor.isEditable)
        #expect(!source.editor.diagnostics.isEmpty)
        #expect(source.editor.stoppedLine == nil && source.editor.breakpoints.isEmpty)
        let ruler = try #require(Self.scrollView(in: source.editor.nativeView))
        #expect(ruler.rulersVisible)

        studio.model.isEditorGutterVisible = false
        source.sync(.mainEditor(studio.model))
        #expect(!ruler.rulersVisible, "T11 · the line numbers hide")

        var typed: String?
        source.onTextChange = { typed = $0 }
        source.editor.onChange?("PRINT 1")
        #expect(typed == "PRINT 1")
    }

    @Test("E12 · Typing is set for BASIC: Settings' indenting on; no auto-closed ' or HTML tags")
    func typingBehavior() {
        let model = StudioHarness().model
        let source = SourceEditorAUI()
        source.sync(.mainEditor(model))
        let behavior = source.editor.editorBehavior
        #expect(behavior.indentsSelectionWithTab && behavior.indentsNewLines && behavior.indentUnit == "    ")
        // `'` starts a comment and `y>z` is a comparison, so nothing pairs.
        #expect(!behavior.closesPairsAutomatically && !behavior.synchronizesClosingTag && !behavior.expandsPairsOnReturn)
        #expect(!behavior.showsFoldingRibbon && !behavior.showsGitChangeGutter)

        model.editorIndentUnit = "\t"
        model.editorIndentsNewLines = false
        source.sync(.mainEditor(model))
        #expect(source.editor.editorBehavior.indentUnit == "\t" && !source.editor.editorBehavior.indentsNewLines)
    }

    @Test("D5 D6 · The debug code view: read-only, the paused line and the breakpoints")
    func debugCodeView() async throws {
        let studio = StudioHarness(program: """
        PRINT 1
        PRINT 2
        """)
        studio.model.openDebugger()
        studio.model.toggleDebuggerBreakpoint(atSourceLine: 2)
        try await studio.run()
        let source = SourceEditorAUI()
        source.sync(.debugCodeView(studio.model))
        #expect(!source.editor.isEditable)
        #expect(source.editor.stoppedLine == 2)
        #expect(Set(source.editor.breakpoints.keys) == [2])
        studio.model.continueDebugging()
        try await studio.waitUntilStopped()
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.hasVerticalRuler { return scroll }
        return view.subviews.lazy.compactMap(scrollView(in:)).first
    }
}
