//
//  RenderInputs.swift
//  BASICStudio
//
//  What the two native views are handed each time the model changes.
//

import BASICCore
import Foundation

/// Everything the Monaco editor shows, as one value.
///
/// ``MonacoEditorController/sync(_:)`` takes it and pushes only what changed
/// into the page. The SwiftUI shell builds one per update; the ActiveUI shell
/// builds the same one in its refresh. The two places Studio shows code differ
/// only in which input they build.
struct EditorRenderInput: Equatable {
    var text: String
    var showsLineNumbers: Bool
    var theme: EditorTheme
    var errorLine: Int?
    var diagnostics: [BASICDiagnostic]
    var executionLine: Int?
    var breakpointLines: Set<Int>
    var isReadOnly: Bool
    var fontFamily: String
    var fontSize: Double
    /// Bumped to open the find widget; 0 never opens it.
    var findRequest: Int
    /// Bumped to open find with replace; 0 never opens it.
    var replaceRequest: Int
    /// Tab and Shift-Tab indent the selected lines.
    var indentsSelectionWithTab = true
    /// Return keeps the line's indentation.
    var indentsNewLines = true
    /// One level of indentation.
    var indentUnit = StudioSettings.defaultIndentUnit

    /// The main editor: editable, with the gutter as set, the diagnostics and
    /// find requests, and no debugger marks.
    ///
    /// The gutter's numbers show when the setting is on and the program does
    /// not number its own lines: beside `10 PRINT` they would be a second,
    /// different number on every line.
    @MainActor
    static func mainEditor(_ model: StudioModel) -> EditorRenderInput {
        EditorRenderInput(
            text: model.programText,
            showsLineNumbers: model.isEditorGutterVisible && !hasBASICLineNumbers(model.programText),
            theme: model.editorTheme,
            errorLine: model.editorErrorLine,
            diagnostics: model.editorDiagnostics,
            executionLine: nil,
            breakpointLines: [],
            isReadOnly: false,
            fontFamily: model.fontFamily,
            fontSize: model.fontSize,
            findRequest: model.editorFindRequest,
            replaceRequest: model.editorReplaceRequest,
            indentsSelectionWithTab: model.editorIndentsSelectionWithTab,
            indentsNewLines: model.editorIndentsNewLines,
            indentUnit: model.editorIndentUnit
        )
    }

    /// Whether a program numbers its own lines, as `10 PRINT` does: at least
    /// half its code lines start with a number. Blank lines and `'` comments
    /// do not count either way.
    static func hasBASICLineNumbers(_ text: String) -> Bool {
        var code = 0
        var numbered = 0
        for line in text.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard let first = trimmed.first, first != "'" else { continue }
            code += 1
            if first.isASCII, first.isNumber { numbered += 1 }
        }
        return code > 0 && numbered * 2 >= code
    }

    /// The Debug inspector's code view: read-only and always numbered, with the
    /// paused line and the breakpoints, and no diagnostics or find.
    @MainActor
    static func debugCodeView(_ model: StudioModel) -> EditorRenderInput {
        EditorRenderInput(
            text: model.programText,
            showsLineNumbers: true,
            theme: model.editorTheme,
            errorLine: model.editorErrorLine,
            diagnostics: [],
            executionLine: model.debuggerExecutionLine,
            breakpointLines: model.debuggerBreakpointLines,
            isReadOnly: true,
            fontFamily: model.fontFamily,
            fontSize: model.fontSize,
            findRequest: 0,
            replaceRequest: 0
        )
    }
}

/// Everything the console view is handed on each update, as one value.
///
/// ``AIBasicTerminalContainerView/render(_:)`` compares it with what it last
/// drew and feeds the terminal only what is new, so building one is cheap and
/// handing over the same one twice does nothing.
struct ConsoleRenderInput: Equatable {
    var consoleText: String
    /// What scrollback trimming has dropped off the front of `consoleText`.
    var trimmedCharacters: Int
    var scrollbackLines: Int
    var screenSize: TerminalScreenSize
    var fontFamily: String
    var fontSize: Double
    var graphicsLayersVisible: Bool

    @MainActor
    init(_ model: StudioModel) {
        consoleText = model.consoleText
        trimmedCharacters = model.consoleTrimmedCharacters
        scrollbackLines = model.consoleScrollbackLines
        screenSize = model.terminalScreenSize
        fontFamily = model.fontFamily
        fontSize = model.fontSize
        graphicsLayersVisible = model.areGraphicsLayersVisible
    }
}
