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
    @MainActor
    static func mainEditor(_ model: StudioModel) -> EditorRenderInput {
        EditorRenderInput(
            text: model.programText,
            showsLineNumbers: model.isEditorGutterVisible,
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
