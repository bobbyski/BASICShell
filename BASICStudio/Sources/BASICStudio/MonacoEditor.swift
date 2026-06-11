import BASICCore
import AppKit
import CoreText
import GameController
import MarkdownUI
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import VectorTerminalSDK
import WebKit

struct MonacoEditor: NSViewRepresentable {
    @Binding var text: String
    let showsLineNumbers: Bool
    let theme: EditorTheme
    let errorLine: Int?
    let diagnostics: [BASICDiagnostic]
    let executionLine: Int?
    let breakpointLines: Set<Int>
    let isReadOnly: Bool
    let fontFamily: String
    let fontSize: Double
    let findRequest: Int
    let replaceRequest: Int
    let breakpointToggle: ((Int) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, breakpointToggle: breakpointToggle)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "basicStudio")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(Self.html, baseURL: Bundle.main.resourceURL)
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.sync(
            text: text,
            showsLineNumbers: showsLineNumbers,
            theme: theme,
            errorLine: errorLine,
            diagnostics: diagnostics,
            executionLine: executionLine,
            breakpointLines: breakpointLines,
            isReadOnly: isReadOnly,
            fontFamily: fontFamily,
            fontSize: fontSize,
            findRequest: findRequest,
            replaceRequest: replaceRequest
        )
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "basicStudio")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        var text: Binding<String>
        var breakpointToggle: ((Int) -> Void)?
        weak var webView: WKWebView?
        private var isReady = false
        private var pendingText: String?
        private var pendingShowsLineNumbers: Bool?
        private var pendingTheme: EditorTheme?
        private var pendingErrorLine: Int?
        private var pendingDiagnostics: [BASICDiagnostic] = []
        private var pendingExecutionLine: Int?
        private var pendingBreakpointLines: Set<Int> = []
        private var pendingIsReadOnly = false
        private var pendingFontFamily = StudioFonts.defaultFamily
        private var pendingFontSize = 13.0
        private var pendingFindRequest: Int?
        private var pendingReplaceRequest: Int?
        private var lastAppliedText: String?
        private var lastAppliedShowsLineNumbers: Bool?
        private var lastAppliedTheme: EditorTheme?
        private var lastAppliedErrorLine: Int?
        private var lastAppliedDiagnostics: [BASICDiagnostic] = []
        private var lastAppliedExecutionLine: Int?
        private var lastAppliedBreakpointLines: Set<Int> = []
        private var lastAppliedIsReadOnly: Bool?
        private var lastAppliedFontFamily: String?
        private var lastAppliedFontSize: Double?
        private var lastAppliedFindRequest: Int?
        private var lastAppliedReplaceRequest: Int?

        init(text: Binding<String>, breakpointToggle: ((Int) -> Void)?) {
            self.text = text
            self.breakpointToggle = breakpointToggle
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            switch type {
            case "ready":
                isReady = true
                applyPending()
            case "change":
                guard let newText = body["text"] as? String else { return }
                lastAppliedText = newText
                text.wrappedValue = newText
            case "toggleBreakpoint":
                guard let lineNumber = body["lineNumber"] as? Int else { return }
                breakpointToggle?(lineNumber)
            default:
                break
            }
        }

        func sync(
            text: String,
            showsLineNumbers: Bool,
            theme: EditorTheme,
            errorLine: Int?,
            diagnostics: [BASICDiagnostic],
            executionLine: Int?,
            breakpointLines: Set<Int>,
            isReadOnly: Bool,
            fontFamily: String,
            fontSize: Double,
            findRequest: Int,
            replaceRequest: Int
        ) {
            pendingText = text
            pendingShowsLineNumbers = showsLineNumbers
            pendingTheme = theme
            pendingErrorLine = errorLine
            pendingDiagnostics = diagnostics
            pendingExecutionLine = executionLine
            pendingBreakpointLines = breakpointLines
            pendingIsReadOnly = isReadOnly
            pendingFontFamily = fontFamily
            pendingFontSize = fontSize
            pendingFindRequest = findRequest
            pendingReplaceRequest = replaceRequest
            applyPending()
        }

        private func applyPending() {
            guard isReady, let webView else { return }

            if let pendingText, pendingText != lastAppliedText {
                webView.evaluateJavaScript("window.basicStudioSetText(\(json(pendingText)));")
                lastAppliedText = pendingText
            }

            if let pendingShowsLineNumbers, pendingShowsLineNumbers != lastAppliedShowsLineNumbers {
                webView.evaluateJavaScript("window.basicStudioSetLineNumbers(\(pendingShowsLineNumbers ? "true" : "false"));")
                lastAppliedShowsLineNumbers = pendingShowsLineNumbers
            }

            if let pendingTheme, pendingTheme != lastAppliedTheme {
                webView.evaluateJavaScript("window.basicStudioSetTheme(\(json(pendingTheme.monacoName)));")
                lastAppliedTheme = pendingTheme
            }

            if pendingErrorLine != lastAppliedErrorLine {
                if let pendingErrorLine {
                    webView.evaluateJavaScript("window.basicStudioSetErrorLine(\(pendingErrorLine));")
                } else {
                    webView.evaluateJavaScript("window.basicStudioSetErrorLine(null);")
                }
                lastAppliedErrorLine = pendingErrorLine
            }

            if pendingDiagnostics != lastAppliedDiagnostics {
                if let data = try? JSONEncoder().encode(pendingDiagnostics),
                   let json = String(data: data, encoding: .utf8) {
                    webView.evaluateJavaScript("window.basicStudioSetDiagnostics(\(json));")
                    lastAppliedDiagnostics = pendingDiagnostics
                }
            }

            if pendingExecutionLine != lastAppliedExecutionLine {
                if let pendingExecutionLine {
                    webView.evaluateJavaScript("window.basicStudioSetExecutionLine(\(pendingExecutionLine));")
                } else {
                    webView.evaluateJavaScript("window.basicStudioSetExecutionLine(null);")
                }
                lastAppliedExecutionLine = pendingExecutionLine
            }

            if pendingBreakpointLines != lastAppliedBreakpointLines {
                let sorted = pendingBreakpointLines.sorted()
                if let data = try? JSONEncoder().encode(sorted),
                   let json = String(data: data, encoding: .utf8) {
                    webView.evaluateJavaScript("window.basicStudioSetBreakpoints(\(json));")
                    lastAppliedBreakpointLines = pendingBreakpointLines
                }
            }

            if pendingIsReadOnly != lastAppliedIsReadOnly {
                webView.evaluateJavaScript("window.basicStudioSetReadOnly(\(pendingIsReadOnly ? "true" : "false"));")
                lastAppliedIsReadOnly = pendingIsReadOnly
            }

            if pendingFontFamily != lastAppliedFontFamily || pendingFontSize != lastAppliedFontSize {
                webView.evaluateJavaScript("window.basicStudioSetFont(\(json(pendingFontFamily)), \(pendingFontSize));")
                lastAppliedFontFamily = pendingFontFamily
                lastAppliedFontSize = pendingFontSize
            }

            if let pendingFindRequest, pendingFindRequest != lastAppliedFindRequest {
                if pendingFindRequest > 0 {
                    webView.evaluateJavaScript("window.basicStudioFind(false);")
                }
                lastAppliedFindRequest = pendingFindRequest
            }

            if let pendingReplaceRequest, pendingReplaceRequest != lastAppliedReplaceRequest {
                if pendingReplaceRequest > 0 {
                    webView.evaluateJavaScript("window.basicStudioFind(true);")
                }
                lastAppliedReplaceRequest = pendingReplaceRequest
            }
        }

        private func json(_ value: String) -> String {
            guard let data = try? JSONEncoder().encode(value),
                  let encoded = String(data: data, encoding: .utf8) else {
                return "\"\""
            }
            return encoded
        }
    }

    private static let html = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        @font-face {
          font-family: "MesloLGS NF";
          src: url("Fonts/MesloLGS NF Regular.ttf") format("truetype");
          font-weight: 400;
          font-style: normal;
        }
        @font-face {
          font-family: "MesloLGS NF";
          src: url("Fonts/MesloLGS NF Bold.ttf") format("truetype");
          font-weight: 700;
          font-style: normal;
        }
        @font-face {
          font-family: "MesloLGS NF";
          src: url("Fonts/MesloLGS NF Italic.ttf") format("truetype");
          font-weight: 400;
          font-style: italic;
        }
        @font-face {
          font-family: "MesloLGS NF";
          src: url("Fonts/MesloLGS NF Bold Italic.ttf") format("truetype");
          font-weight: 700;
          font-style: italic;
        }
        html, body, #editor, #fallbackEditor {
          height: 100%;
          width: 100%;
          margin: 0;
          overflow: hidden;
          background: #1e1e1e;
        }
        #fallbackEditor {
          display: none;
          box-sizing: border-box;
          border: 0;
          outline: 0;
          resize: none;
          padding: 12px;
          color: #d4d4d4;
          caret-color: #75beff;
          font-family: "MesloLGS NF", "SF Mono", Menlo, Monaco, monospace;
          font-size: 13px;
          line-height: 1.35;
          white-space: pre;
        }
        #editorStatus {
          position: absolute;
          top: 12px;
          left: 12px;
          z-index: 10;
          padding: 5px 8px;
          border-radius: 6px;
          background: rgba(45, 45, 45, 0.92);
          color: #d4d4d4;
          font: 12px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          pointer-events: none;
        }
        .basic-error-line {
          background: rgba(255, 59, 48, 0.16);
        }
        .basic-diagnostic-range {
          background: rgba(255, 59, 48, 0.38);
          outline: 1px solid rgba(255, 69, 58, 0.95);
        }
        .basic-diagnostic-line {
          background: rgba(255, 59, 48, 0.10);
        }
        .basic-diagnostic-message {
          color: #ff8a80;
          font-style: italic;
          margin-left: 1.5em;
        }
        .basic-execution-line {
          background: rgba(48, 209, 88, 0.22);
          border-left: 3px solid rgba(48, 209, 88, 0.95);
        }
        .basic-breakpoint-glyph {
          background: #ff453a;
          border-radius: 50%;
          width: 10px !important;
          height: 10px !important;
          margin-left: 4px;
          margin-top: 4px;
        }
      </style>
      <script src="https://cdn.jsdelivr.net/npm/monaco-editor@0.49.0/min/vs/loader.js" onerror="window.basicStudioUseFallback && window.basicStudioUseFallback()"></script>
    </head>
    <body>
      <div id="editor"></div>
      <div id="editorStatus">Loading Monaco editor...</div>
      <textarea id="fallbackEditor" spellcheck="false" autocorrect="off" autocapitalize="off"></textarea>
      <script>
        let editor = null;
        let fallbackEditor = document.getElementById("fallbackEditor");
        let editorStatus = document.getElementById("editorStatus");
        var usingFallback = false;
        let didPostReady = false;
        let pendingText = "";
        let pendingLineNumbers = false;
        let pendingTheme = "vs-dark";
        let pendingFind = false;
        let pendingFindShowsReplace = false;
        let pendingFontFamily = "MesloLGS NF";
        let pendingFontSize = 13;
        let suppressChange = false;
        let errorDecorations = [];
        let diagnosticDecorations = [];
        let executionDecorations = [];
        let breakpointDecorations = [];

        function post(message) {
          window.webkit.messageHandlers.basicStudio.postMessage(message);
        }

        function postReadyOnce() {
          if (didPostReady) { return; }
          didPostReady = true;
          post({ type: "ready" });
        }

        function hideStatus() {
          editorStatus.style.display = "none";
        }

        function showStatus(message) {
          editorStatus.textContent = message;
          editorStatus.style.display = "block";
        }

        function fallbackThemeColors(themeName) {
          if (themeName === "vs") {
            return { background: "#ffffff", foreground: "#1f1f1f", caret: "#005fb8" };
          }
          if (themeName === "hc-black") {
            return { background: "#000000", foreground: "#ffffff", caret: "#ffffff" };
          }
          return { background: "#1e1e1e", foreground: "#d4d4d4", caret: "#75beff" };
        }

        window.basicStudioUseFallback = function() {
          if (editor || usingFallback) { return; }
          usingFallback = true;
          document.getElementById("editor").style.display = "none";
          showStatus("Basic editor fallback");
          fallbackEditor.style.display = "block";
          fallbackEditor.value = pendingText;
          const colors = fallbackThemeColors(pendingTheme);
          fallbackEditor.style.background = colors.background;
          fallbackEditor.style.color = colors.foreground;
          fallbackEditor.style.caretColor = colors.caret;
          fallbackEditor.readOnly = false;
          fallbackEditor.addEventListener("input", function() {
            pendingText = fallbackEditor.value;
            post({ type: "change", text: fallbackEditor.value });
          });
          window.setTimeout(hideStatus, 1800);
          postReadyOnce();
        };

        window.basicStudioSetText = function(value) {
          pendingText = value;
          if (usingFallback) {
            if (fallbackEditor.value !== value) {
              fallbackEditor.value = value;
            }
            return;
          }
          if (!editor || editor.getValue() === value) { return; }
          suppressChange = true;
          editor.setValue(value);
          suppressChange = false;
        };

        window.basicStudioSetLineNumbers = function(show) {
          pendingLineNumbers = show;
          if (usingFallback) { return; }
          if (!editor) { return; }
          editor.updateOptions({
            lineNumbers: show ? "on" : "off",
            glyphMargin: show,
            folding: show
          });
        };

        window.basicStudioSetReadOnly = function(readOnly) {
          if (usingFallback) {
            fallbackEditor.readOnly = readOnly;
            return;
          }
          if (!editor) { return; }
          editor.updateOptions({ readOnly: readOnly, domReadOnly: readOnly });
        };

        function cssFontFamily(fontFamily) {
          const escaped = String(fontFamily).replace(/'/g, "\\'");
          return "'" + escaped + "', 'SF Mono', Menlo, Monaco, monospace";
        }

        window.basicStudioSetFont = function(fontFamily, fontSize) {
          pendingFontFamily = fontFamily;
          pendingFontSize = fontSize;
          if (usingFallback) {
            fallbackEditor.style.fontFamily = cssFontFamily(fontFamily);
            fallbackEditor.style.fontSize = fontSize + "px";
            return;
          }
          if (!editor) { return; }
          editor.updateOptions({ fontFamily: cssFontFamily(fontFamily), fontSize: fontSize });
        };

        function applyPageBackground(themeName) {
          const color = themeName === "vs" ? "#ffffff" : (themeName === "hc-black" ? "#000000" : "#1e1e1e");
          document.documentElement.style.background = color;
          document.body.style.background = color;
        }

        window.basicStudioSetTheme = function(themeName) {
          pendingTheme = themeName;
          applyPageBackground(themeName);
          if (usingFallback) {
            const colors = fallbackThemeColors(themeName);
            fallbackEditor.style.background = colors.background;
            fallbackEditor.style.color = colors.foreground;
            fallbackEditor.style.caretColor = colors.caret;
            return;
          }
          if (!editor) { return; }
          monaco.editor.setTheme(themeName);
        };

        window.basicStudioFind = function(showReplace) {
          if (usingFallback) {
            fallbackEditor.focus();
            return;
          }
          if (!editor) {
            pendingFind = true;
            pendingFindShowsReplace = showReplace;
            return;
          }
          pendingFind = false;
          pendingFindShowsReplace = false;
          editor.focus();
          const actionName = showReplace ? "editor.action.startFindReplaceAction" : "actions.find";
          editor.getAction(actionName).run();
        };

        window.basicStudioSetErrorLine = function(lineNumber) {
          if (usingFallback) { return; }
          if (!editor) { return; }
          const decorations = lineNumber ? [{
            range: new monaco.Range(lineNumber, 1, lineNumber, 1),
            options: {
              isWholeLine: true,
              className: "basic-error-line",
              overviewRuler: {
                color: "rgba(255, 59, 48, 0.85)",
                position: monaco.editor.OverviewRulerLane.Right
              }
            }
          }] : [];
          errorDecorations.splice(0, errorDecorations.length, ...editor.deltaDecorations(errorDecorations, decorations));
          if (lineNumber) {
            editor.revealLineInCenterIfOutsideViewport(lineNumber);
          }
        };

        window.basicStudioSetDiagnostics = function(diagnostics) {
          if (usingFallback) { return; }
          if (!editor || !window.monaco) { return; }
          const markers = (diagnostics || []).map((diagnostic) => {
            const lineNumber = Math.max(1, diagnostic.lineNumber || 1);
            const column = Math.max(1, (diagnostic.column || 0) + 1);
            const severity = diagnostic.severity === "warning"
              ? monaco.MarkerSeverity.Warning
              : monaco.MarkerSeverity.Error;
            return {
              severity: severity,
              message: diagnostic.message || "Diagnostic",
              startLineNumber: lineNumber,
              startColumn: column,
              endLineNumber: lineNumber,
              endColumn: column + 1
            };
          });
          monaco.editor.setModelMarkers(editor.getModel(), "aibasic", markers);

          const model = editor.getModel();
          const decorations = (diagnostics || []).flatMap((diagnostic) => {
            const lineCount = model ? model.getLineCount() : 1;
            const lineNumber = Math.min(Math.max(1, diagnostic.lineNumber || 1), lineCount);
            const lineLength = model ? model.getLineLength(lineNumber) : 1;
            const column = Math.min(Math.max(1, (diagnostic.column || 0) + 1), Math.max(1, lineLength + 1));
            const message = diagnostic.message || "Diagnostic";
            return [
              {
                range: new monaco.Range(lineNumber, 1, lineNumber, 1),
                options: {
                  isWholeLine: true,
                  className: "basic-diagnostic-line",
                  overviewRuler: {
                    color: "rgba(255, 59, 48, 0.85)",
                    position: monaco.editor.OverviewRulerLane.Right
                  }
                }
              },
              {
                range: new monaco.Range(lineNumber, column, lineNumber, Math.min(column + 1, lineLength + 1)),
                options: {
                  inlineClassName: "basic-diagnostic-range",
                  hoverMessage: { value: message },
                  after: {
                    contentText: "  " + message,
                    inlineClassName: "basic-diagnostic-message"
                  },
                  stickiness: monaco.editor.TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges
                }
              }
            ];
          });
          diagnosticDecorations.splice(0, diagnosticDecorations.length, ...editor.deltaDecorations(diagnosticDecorations, decorations));
        };

        window.basicStudioSetExecutionLine = function(lineNumber) {
          if (usingFallback) { return; }
          if (!editor) { return; }
          const decorations = lineNumber ? [{
            range: new monaco.Range(lineNumber, 1, lineNumber, 1),
            options: {
              isWholeLine: true,
              className: "basic-execution-line",
              overviewRuler: {
                color: "rgba(48, 209, 88, 0.95)",
                position: monaco.editor.OverviewRulerLane.Right
              }
            }
          }] : [];
          executionDecorations.splice(0, executionDecorations.length, ...editor.deltaDecorations(executionDecorations, decorations));
          if (lineNumber) {
            editor.revealLineInCenterIfOutsideViewport(lineNumber);
          }
        };

        window.basicStudioSetBreakpoints = function(lineNumbers) {
          if (usingFallback) { return; }
          if (!editor) { return; }
          const decorations = lineNumbers.map((lineNumber) => ({
            range: new monaco.Range(lineNumber, 1, lineNumber, 1),
            options: {
              glyphMarginClassName: "basic-breakpoint-glyph",
              stickiness: monaco.editor.TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges
            }
          }));
          breakpointDecorations.splice(0, breakpointDecorations.length, ...editor.deltaDecorations(breakpointDecorations, decorations));
        };

        window.addEventListener("DOMContentLoaded", function() {
          window.setTimeout(function() {
            if (!editor) {
              window.basicStudioUseFallback();
            }
          }, 4000);
        });

        if (window.require) {
        require.config({ paths: { vs: "https://cdn.jsdelivr.net/npm/monaco-editor@0.49.0/min/vs" } });
        require(["vs/editor/editor.main"], function() {
          if (usingFallback) { return; }
          hideStatus();
          monaco.languages.register({ id: "aibasic" });
          monaco.languages.setMonarchTokensProvider("aibasic", {
            ignoreCase: true,
            controlKeywords: [
              "BREAK", "CASE", "CONTINUE", "DO", "ELSE", "ELSEIF", "END", "ERROR", "EXIT",
              "FOR", "GOSUB", "GOTO", "IF", "LOOP", "NEXT", "ON", "RESUME", "RETURN",
              "SELECT", "STEP", "STOP", "THEN", "TO", "UNTIL", "WEND", "WHILE", "YIELD"
            ],
            declarationKeywords: [
              "AS", "CLASS", "CONST", "DATA", "DECLARE", "DEFAULT", "DIM", "FUNCTION",
              "GLOBAL", "IMPLEMENTS", "IMPORT", "INHERITS", "INTERFACE", "JSON", "LABEL",
              "LET", "LOCAL", "ME", "META", "MODULE", "NAME", "OPTION", "OVERRIDES",
              "PRIVATE", "PROTECTED", "PUBLIC", "READ", "RECORD", "RESTORE", "SHARED",
              "TYPE", "VIRTUAL"
            ],
            ioKeywords: [
              "CD", "CLEAR", "CLOSE", "EDIT", "FIELD", "FILES", "GET", "HELP", "INPUT",
              "LINE", "LIST", "LOAD", "LOG", "LSET", "NEW", "OPEN", "PRINT", "PROMPT",
              "PUT", "RANDOMIZE", "RSET", "RUN", "SAVE", "SYSTEM"
            ],
            graphicsKeywords: [
              "CIRCLE", "CLS", "COLOR", "DRAW", "LOCATE", "PAINT", "POINT", "PRESET",
              "PSET", "SCREEN"
            ],
            typeKeywords: [
              "BIG", "BOOLEAN", "BOTH", "DICTIONARY", "DOUBLE", "EMPTY", "FALSE", "FILE",
              "INTEGER", "JSON", "LITTLE", "NATIVE", "NULL", "RAW", "READ", "SINGLE",
              "STRING", "TEXT", "TRUE", "VARIANT", "VOID", "WRITE"
            ],
            builtinFunctions: [
              "ABS", "ASC", "ATN", "BINARY$", "CHR$", "CINT", "COS", "CURRENTDIR$",
              "CVD", "CVI", "CVS", "EXP", "FIX", "FROMJSONSTRING", "INKEY$", "INPUT$",
              "INSTR", "INT", "LEFT$", "LEN", "LOF", "LOG", "MID$", "MKD$", "MKI$",
              "MKS$", "POINT", "RIGHT$", "RND", "SGN", "SIN", "SPACE$", "SPC", "SQR",
              "STR$", "STRING$", "SYSTEM$", "TAB", "TAN", "TOJSONSTRING", "USING$", "VAL"
            ],
            tokenizer: {
              root: [
                [/^\\s*#!.*$/, "comment.extension.aibasic"],
                [/^\\s*#.*$/, "comment.extension.aibasic"],
                [/"/, { token: "string.quote.aibasic", next: "@string" }],
                [/\\/\\/.*$/, "comment.extension.aibasic"],
                [/'.*$/, "comment.basic.aibasic"],
                [/\\bREM\\b.*$/, "comment.basic.aibasic"],
                [/^\\s*\\d+\\b/, "number.line.aibasic"],
                [/\\b\\d+(\\.\\d+)?\\b/, "number"],
                [/^[ \\t]*[A-Za-z_][A-Za-z0-9_]*[ \\t]*:/, "identifier.label.aibasic"],
                [/[A-Za-z_][A-Za-z0-9_]*\\$?/, {
                  cases: {
                    "@controlKeywords": "keyword.control.aibasic",
                    "@declarationKeywords": "keyword.declaration.aibasic",
                    "@ioKeywords": "keyword.io.aibasic",
                    "@graphicsKeywords": "keyword.graphics.aibasic",
                    "@typeKeywords": "keyword.type.aibasic",
                    "@builtinFunctions": "predefined.aibasic",
                    "@default": "identifier"
                  }
                }],
                [/[<>]=?|=|\\+|-|\\*|\\//, "operator"],
                [/[(),.:;]/, "delimiter"]
              ],
              string: [
                [/""/, "string.escape.aibasic"],
                [/[^"]+/, "string.aibasic"],
                [/"/, { token: "string.quote.aibasic", next: "@pop" }]
              ]
            }
          });

          editor = monaco.editor.create(document.getElementById("editor"), {
            value: pendingText,
            language: "aibasic",
            theme: pendingTheme,
            automaticLayout: true,
            minimap: { enabled: false },
            scrollBeyondLastLine: false,
            fontFamily: cssFontFamily(pendingFontFamily),
            fontSize: 13,
            lineNumbers: pendingLineNumbers ? "on" : "off",
            glyphMargin: pendingLineNumbers,
            folding: pendingLineNumbers,
            lineDecorationsWidth: 8,
            lineNumbersMinChars: 3,
            renderLineHighlight: "line",
            wordWrap: "off",
            readOnly: false,
            domReadOnly: false
          });

          editor.onMouseDown(function(event) {
            if (event.target.type !== monaco.editor.MouseTargetType.GUTTER_GLYPH_MARGIN &&
                event.target.type !== monaco.editor.MouseTargetType.GUTTER_LINE_NUMBERS) { return; }
            if (!event.target.position) { return; }
            post({ type: "toggleBreakpoint", lineNumber: event.target.position.lineNumber });
          });

          applyPageBackground(pendingTheme);

          editor.onDidChangeModelContent(function() {
            if (!suppressChange) {
              post({ type: "change", text: editor.getValue() });
            }
          });

          if (pendingFind) {
            window.basicStudioFind(pendingFindShowsReplace);
          }

          postReadyOnce();
        }, function() {
          window.basicStudioUseFallback();
        });
        } else {
          window.basicStudioUseFallback();
        }
      </script>
    </body>
    </html>
    """
}

