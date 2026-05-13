import BASICCore
import AppKit
import MarkdownUI
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import WebKit

@main
struct BASICStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = StudioModel()

    var body: some Scene {
        WindowGroup("AIBasic Studio") {
            StudioView(model: model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Load...") {
                    model.loadProgramFromMenu()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    model.saveProgramFromMenu()
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button("Save As...") {
                    model.saveProgramAsFromMenu()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandMenu("Examples") {
                if model.bundledExamples.isEmpty {
                    Text("No Examples Found")
                } else {
                    ForEach(model.bundledExamples) { example in
                        Button(example.menuTitle) {
                            model.loadBundledExample(example)
                        }
                    }
                }
            }

            CommandGroup(after: .textEditing) {
                Divider()

                Button("Find") {
                    model.showFind()
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("Find and Replace") {
                    model.showFindAndReplace()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
            }

            CommandMenu("Debug") {
                Button("Show Debugger") {
                    model.openDebugger()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct StudioView: View {
    @ObservedObject var model: StudioModel
    @State private var inspectorWidth: CGFloat = 360

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    mainPane
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

                    if let inspectorPane = model.inspectorPane {
                        InspectorDivider(
                            width: $inspectorWidth,
                            availableWidth: geometry.size.width,
                            minimumMainWidth: 420,
                            minimumInspectorWidth: 260
                        )

                        inspectorView(for: inspectorPane)
                            .frame(width: clampedInspectorWidth(availableWidth: geometry.size.width))
                            .frame(maxHeight: .infinity)
                    }
                }
            }

            if model.isCommandBarVisible {
                Divider()

                HStack {
                    Button("Run") { model.runEditorProgram() }
                        .keyboardShortcut("r", modifiers: [.command])
                    Button("List") { model.listProgram() }
                    Button("New") { model.clearProgram() }
                    TextField("Immediate command", text: $model.command)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.submitCommand() }
                    Button("Submit") { model.submitCommand() }
                }
                .padding()
            }
        }
        .onAppear {
            model.runStartupProgramIfNeeded()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.runEditorProgram()
                } label: {
                    Image(systemName: "play.fill")
                        .foregroundStyle(model.isProgramRunning ? Color.secondary : Color.primary)
                }
                .disabled(model.isProgramRunning)
                .help("Run")

                Button {
                    model.stopProgram()
                } label: {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(model.isProgramRunning ? Color.red : Color.secondary)
                }
                .disabled(!model.isProgramRunning)
                .help("Stop")

                Divider()

                Button {
                    model.selectedPane = .console
                } label: {
                    Image(systemName: "terminal")
                        .foregroundStyle(model.selectedPane == .console ? Color.blue : Color.primary)
                }
                .help("Console")

                Button {
                    model.selectedPane = .editor
                } label: {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(model.selectedPane == .editor ? Color.blue : Color.primary)
                }
                .help("Editor")

                Button {
                    model.toggleInspector(.debug)
                } label: {
                    Image(systemName: "ladybug")
                        .foregroundStyle(model.inspectorPane == .debug ? Color.blue : Color.primary)
                }
                .help("Debug")

                Button {
                    model.toggleInspector(.docs)
                } label: {
                    Image(systemName: "book")
                        .foregroundStyle(model.inspectorPane == .docs ? Color.blue : Color.primary)
                }
                .help("Documentation")

                Button {
                    model.isCommandBarVisible.toggle()
                } label: {
                    Image(systemName: "keyboard")
                        .foregroundStyle(model.isCommandBarVisible ? Color.blue : Color.primary)
                }
                .help("Command Bar")

                Button {
                    model.isEditorGutterVisible.toggle()
                } label: {
                    Image(systemName: "list.number")
                        .foregroundStyle(model.isEditorGutterVisible ? Color.blue : Color.primary)
                }
                .help("Editor Line Numbers")

                Button {
                    model.showFind()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Find")

                Menu {
                    ForEach(EditorTheme.allCases, id: \.self) { theme in
                        Button {
                            model.editorTheme = theme
                        } label: {
                            HStack {
                                Text(theme.label)
                                if model.editorTheme == theme {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label(model.editorTheme.label, systemImage: "paintpalette")
                }
                .help("Editor Theme")

                Menu {
                    ForEach(TerminalScreenSize.allCases, id: \.self) { size in
                        Button {
                            model.terminalScreenSize = size
                        } label: {
                            HStack {
                                Text(size.label)
                                if model.terminalScreenSize == size {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label(model.terminalScreenSize.label, systemImage: "rectangle.inset.filled")
                }
                .help("Screen Size")
            }
        }
    }

    @ViewBuilder
    private var mainPane: some View {
        switch model.selectedPane {
        case .editor:
            VStack(spacing: 0) {
                MonacoEditor(
                    text: $model.programText,
                    showsLineNumbers: model.isEditorGutterVisible,
                    theme: model.editorTheme,
                    errorLine: model.editorErrorLine,
                    executionLine: nil,
                    breakpointLines: [],
                    isReadOnly: false,
                    findRequest: model.editorFindRequest,
                    replaceRequest: model.editorReplaceRequest,
                    breakpointToggle: nil
                )
            }
            .padding()
        case .console:
            VStack(spacing: 0) {
                SwiftTermGraphicsConsole(model: model)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func inspectorView(for pane: InspectorPane) -> some View {
        switch pane {
        case .debug:
            DebugPane(model: model)
        case .docs:
            UserDocumentationPane()
        }
    }

    private func clampedInspectorWidth(availableWidth: CGFloat) -> CGFloat {
        min(max(inspectorWidth, 260), max(260, availableWidth - 420))
    }
}

struct InspectorDivider: View {
    @Binding var width: CGFloat
    let availableWidth: CGFloat
    let minimumMainWidth: CGFloat
    let minimumInspectorWidth: CGFloat
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 3, height: 44)
            Color.clear
                .frame(width: 12)
        }
        .frame(width: 12)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = width
                    }

                    let maximumWidth = max(minimumInspectorWidth, availableWidth - minimumMainWidth)
                    let proposedWidth = (dragStartWidth ?? width) - value.translation.width
                    width = min(max(proposedWidth, minimumInspectorWidth), maximumWidth)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
        .help("Resize side pane")
    }
}

enum StudioPane {
    case editor
    case console
}

enum InspectorPane {
    case debug
    case docs
}

struct BundledExample: Identifiable, Hashable {
    let path: String

    var id: String { path }

    var menuTitle: String {
        path
            .split(separator: "/")
            .map { part in
                part
                    .split(separator: "-")
                    .map { word in
                        guard let first = word.first else { return "" }
                        return first.uppercased() + word.dropFirst()
                    }
                    .joined(separator: " ")
            }
            .joined(separator: " / ")
    }
}

fileprivate enum TerminalInputOperation {
    case append(String)
    case submit(String)
}

@MainActor
protocol StudioDebuggerInterface: AnyObject {
    var debuggerBreakpointLines: Set<Int> { get }
    var debuggerExecutionLine: Int? { get }
    func toggleDebuggerBreakpoint(atSourceLine lineNumber: Int)
    func openDebugger()
}

enum EditorTheme: String, CaseIterable, Codable {
    case dark
    case light
    case highContrast

    var label: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .highContrast: return "High Contrast"
        }
    }

    var monacoName: String {
        switch self {
        case .dark: return "vs-dark"
        case .light: return "vs"
        case .highContrast: return "hc-black"
        }
    }
}

enum TerminalScreenSize: String, CaseIterable, Codable {
    case eightyByTwentyFive
    case sixtyFourBySixteen
    case thirtyTwoBySixteen
    case flexible

    var label: String {
        switch self {
        case .eightyByTwentyFive: return "80x25"
        case .sixtyFourBySixteen: return "64x16"
        case .thirtyTwoBySixteen: return "32x16"
        case .flexible: return "Flexible"
        }
    }

    var dimensions: (cols: Int, rows: Int)? {
        switch self {
        case .eightyByTwentyFive: return (80, 25)
        case .sixtyFourBySixteen: return (64, 16)
        case .thirtyTwoBySixteen: return (32, 16)
        case .flexible: return nil
        }
    }
}

struct StudioSettings: Codable {
    var editorTheme: EditorTheme = .dark
    var isEditorGutterVisible = false
    var terminalScreenSize: TerminalScreenSize = .flexible
}

struct StudioSettingsStore {
    private static let fileName = "StudioSettings.json"

    static var settingsURL: URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("AIBasic", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func load() -> StudioSettings {
        let url = settingsURL
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(StudioSettings.self, from: data) else {
            return StudioSettings()
        }
        return settings
    }

    static func save(_ settings: StudioSettings) {
        let url = settingsURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.pretty.encode(settings)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Unable to save BASICStudio settings: \(error.localizedDescription)")
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

struct MonacoEditor: NSViewRepresentable {
    @Binding var text: String
    let showsLineNumbers: Bool
    let theme: EditorTheme
    let errorLine: Int?
    let executionLine: Int?
    let breakpointLines: Set<Int>
    let isReadOnly: Bool
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
        webView.loadHTMLString(Self.html, baseURL: nil)
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
            executionLine: executionLine,
            breakpointLines: breakpointLines,
            isReadOnly: isReadOnly,
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
        private var pendingExecutionLine: Int?
        private var pendingBreakpointLines: Set<Int> = []
        private var pendingIsReadOnly = false
        private var pendingFindRequest: Int?
        private var pendingReplaceRequest: Int?
        private var lastAppliedText: String?
        private var lastAppliedShowsLineNumbers: Bool?
        private var lastAppliedTheme: EditorTheme?
        private var lastAppliedErrorLine: Int?
        private var lastAppliedExecutionLine: Int?
        private var lastAppliedBreakpointLines: Set<Int> = []
        private var lastAppliedIsReadOnly: Bool?
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
            executionLine: Int?,
            breakpointLines: Set<Int>,
            isReadOnly: Bool,
            findRequest: Int,
            replaceRequest: Int
        ) {
            pendingText = text
            pendingShowsLineNumbers = showsLineNumbers
            pendingTheme = theme
            pendingErrorLine = errorLine
            pendingExecutionLine = executionLine
            pendingBreakpointLines = breakpointLines
            pendingIsReadOnly = isReadOnly
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
        html, body, #editor {
          height: 100%;
          width: 100%;
          margin: 0;
          overflow: hidden;
          background: #1e1e1e;
        }
        .basic-error-line {
          background: rgba(255, 59, 48, 0.16);
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
      <script src="https://cdn.jsdelivr.net/npm/monaco-editor@0.49.0/min/vs/loader.js"></script>
    </head>
    <body>
      <div id="editor"></div>
      <script>
        let editor = null;
        let pendingText = "";
        let pendingLineNumbers = false;
        let pendingTheme = "vs-dark";
        let pendingFind = false;
        let pendingFindShowsReplace = false;
        let suppressChange = false;
        let errorDecorations = [];
        let executionDecorations = [];
        let breakpointDecorations = [];

        function post(message) {
          window.webkit.messageHandlers.basicStudio.postMessage(message);
        }

        window.basicStudioSetText = function(value) {
          pendingText = value;
          if (!editor || editor.getValue() === value) { return; }
          suppressChange = true;
          editor.setValue(value);
          suppressChange = false;
        };

        window.basicStudioSetLineNumbers = function(show) {
          pendingLineNumbers = show;
          if (!editor) { return; }
          editor.updateOptions({
            lineNumbers: show ? "on" : "off",
            glyphMargin: show,
            folding: show
          });
        };

        window.basicStudioSetReadOnly = function(readOnly) {
          if (!editor) { return; }
          editor.updateOptions({ readOnly: readOnly, domReadOnly: readOnly });
        };

        function applyPageBackground(themeName) {
          const color = themeName === "vs" ? "#ffffff" : (themeName === "hc-black" ? "#000000" : "#1e1e1e");
          document.documentElement.style.background = color;
          document.body.style.background = color;
        }

        window.basicStudioSetTheme = function(themeName) {
          pendingTheme = themeName;
          applyPageBackground(themeName);
          if (!editor) { return; }
          monaco.editor.setTheme(themeName);
        };

        window.basicStudioFind = function(showReplace) {
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

        window.basicStudioSetExecutionLine = function(lineNumber) {
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

        require.config({ paths: { vs: "https://cdn.jsdelivr.net/npm/monaco-editor@0.49.0/min/vs" } });
        require(["vs/editor/editor.main"], function() {
          monaco.languages.register({ id: "aibasic" });
          monaco.languages.setMonarchTokensProvider("aibasic", {
            ignoreCase: true,
            tokenizer: {
              root: [
                [/\\b(PRINT|LET|GLOBAL|LOCAL|OPTION|INPUT|GOTO|GOSUB|RETURN|FUNCTION|VOID|VARIANT|IF|THEN|ELSEIF|FOR|TO|STEP|NEXT|SELECT|CASE|ELSE|END|EXIT|REM|RUN|LIST|LOAD|SAVE|FILES|SYSTEM|NEW|CLEAR|HELP|SCREEN|COLOR|CLS|PSET|PRESET|LINE|POINT|IS|AS|TRUE|FALSE|TYPE|INTERFACE|CLASS|IMPLEMENTS|INHERITS|PUBLIC|PRIVATE|PROTECTED|OVERRIDES|VIRTUAL|ME)\\b/, "keyword"],
                [/".*?"/, "string"],
                [/\\b\\d+(\\.\\d+)?\\b/, "number"],
                [/'.*$/, "comment"],
                [/\\bREM\\b.*$/, "comment"]
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
            fontFamily: "SFMono-Regular, Menlo, Monaco, Consolas, monospace",
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

          post({ type: "ready" });
        });
      </script>
    </body>
    </html>
    """
}

@MainActor
final class StudioModel: ObservableObject {
    @Published var selectedPane: StudioPane = .console
    @Published var inspectorPane: InspectorPane?
    @Published var isCommandBarVisible = false
    @Published var isEditorGutterVisible = false {
        didSet { saveSettings() }
    }
    @Published var editorTheme: EditorTheme = .dark {
        didSet { saveSettings() }
    }
    @Published var editorErrorLine: Int?
    @Published var editorFindRequest = 0
    @Published var editorReplaceRequest = 0
    @Published var isProgramRunning = false
    @Published var terminalScreenSize: TerminalScreenSize = .flexible {
        didSet { saveSettings() }
    }
    @Published var programText = StudioModel.defaultProgramSource()
    @Published var consoleText = BASICSession.defaultPrompt
    @Published var command = ""
    @Published var graphicsRevision = 0
    @Published var debuggerBreakpoints: [BASICBreakpoint] = []
    @Published var debuggerExecutionLine: Int?
    @Published var isProgramPaused = false
    @Published var debuggerCallStack: [BASICCallStackFrame] = []
    @Published var debuggerSelectedCallStackFrameIndex: Int?
    @Published var debuggerLocalVariables: [BASICVariableSnapshot] = []
    @Published var debuggerFrameLocalVariables: [[BASICVariableSnapshot]] = []
    @Published var debuggerGlobalVariables: [BASICVariableSnapshot] = []
    let bundledExamples = StudioModel.availableBundledExamples()

    let graphics = GraphicsFramebuffer()
    private var shouldRunStartupProgram = false
    private var currentProgramURL: URL?
    private let executionQueue = DispatchQueue(label: "AIBasic.Studio.Execution", qos: .userInitiated)
    private var activeExecutionControl: BASICExecutionControl?

    private lazy var session = BASICSession(host: self)

    private var prompt: String {
        session.prompt
    }

    init() {
        let settings = StudioSettingsStore.load()
        editorTheme = settings.editorTheme
        isEditorGutterVisible = settings.isEditorGutterVisible
        terminalScreenSize = settings.terminalScreenSize

        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--demo", arguments.count >= 2 {
            if let source = Self.bundledDemoSource(named: arguments[1]) {
                programText = source
            }
        } else if let path = arguments.first,
           let source = try? String(contentsOfFile: expandedPath(path), encoding: .utf8) {
            programText = source
            currentProgramURL = URL(fileURLWithPath: expandedPath(path))
            shouldRunStartupProgram = true
        }

        saveSettings()
    }

    func runStartupProgramIfNeeded() {
        guard shouldRunStartupProgram else { return }
        shouldRunStartupProgram = false
        runEditorProgram()
    }

    func toggleInspector(_ pane: InspectorPane) {
        inspectorPane = inspectorPane == pane ? nil : pane
    }

    func openDebugger() {
        inspectorPane = .debug
    }

    var debuggerBreakpointLines: Set<Int> {
        Set(debuggerBreakpoints
            .filter(\.isEnabled)
            .map(\.location.lineNumber))
    }

    var debuggerSelectedLocalVariables: [BASICVariableSnapshot] {
        guard let index = debuggerSelectedCallStackFrameIndex,
              debuggerFrameLocalVariables.indices.contains(index) else {
            return debuggerLocalVariables
        }
        return debuggerFrameLocalVariables[index]
    }

    func selectDebuggerCallStackFrame(_ frame: BASICCallStackFrame) {
        debuggerSelectedCallStackFrameIndex = frame.index
    }

    func toggleDebuggerBreakpoint(atSourceLine lineNumber: Int) {
        let location = BASICBreakpointLocation(
            fileName: debuggerFileName,
            lineNumber: lineNumber,
            statementNumber: 0
        )
        if let index = debuggerBreakpoints.firstIndex(where: { $0.location == location }) {
            debuggerBreakpoints.remove(at: index)
        } else {
            debuggerBreakpoints.append(BASICBreakpoint(location: location))
        }
    }

    func showFind() {
        selectedPane = .editor
        editorFindRequest += 1
    }

    func showFindAndReplace() {
        selectedPane = .editor
        editorReplaceRequest += 1
    }

    func loadProgramFromMenu() {
        let panel = NSOpenPanel()
        panel.title = "Load BASIC Program"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.basicProgramContentTypes

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            programText = source
            currentProgramURL = url
            editorErrorLine = nil
            rebuildProgramFromEditor()
            selectedPane = .editor
        } catch {
            presentFileError("Unable to load \(url.lastPathComponent).", error: error)
        }
    }

    func loadBundledExample(_ example: BundledExample) {
        guard let source = Self.bundledDemoSource(named: example.path) else {
            let alert = NSAlert()
            alert.messageText = "Unable to load \(example.menuTitle)."
            alert.informativeText = "The bundled example could not be found."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        programText = source
        currentProgramURL = nil
        editorErrorLine = nil
        debuggerExecutionLine = nil
        debuggerBreakpoints = []
        rebuildProgramFromEditor()
        selectedPane = .editor
    }

    func saveProgramFromMenu() {
        if let currentProgramURL {
            saveProgram(to: currentProgramURL)
        } else {
            saveProgramAsFromMenu()
        }
    }

    func saveProgramAsFromMenu() {
        let panel = NSSavePanel()
        panel.title = "Save BASIC Program"
        panel.allowedContentTypes = Self.basicProgramContentTypes
        panel.nameFieldStringValue = currentProgramURL?.lastPathComponent ?? "Untitled.bas"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveProgram(to: url)
    }

    func runEditorProgram() {
        guard !isProgramRunning else { return }
        rebuildProgramFromEditor()
        selectedPane = .console
        echoConsoleCommand("RUN")
        startProgramRun(startLine: nil)
    }

    func listProgram() {
        rebuildProgramFromEditor()
        selectedPane = .console
        submitConsoleCommand("LIST", echo: true)
    }

    func clearProgram() {
        guard !isProgramRunning else { return }
        _ = session.submit("NEW")
        programText = ""
        consoleText = prompt
        graphics.clear(color: nil)
        graphicsRevision += 1
        isProgramPaused = false
        debuggerExecutionLine = nil
        debuggerCallStack = []
        debuggerSelectedCallStackFrameIndex = nil
        debuggerLocalVariables = []
        debuggerFrameLocalVariables = []
        debuggerGlobalVariables = []
        activeExecutionControl = nil
    }

    func submitCommand() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectedPane = .console
        submitConsoleCommand(trimmed, echo: true)
        command = ""
    }

    func stopProgram() {
        activeExecutionControl?.requestBreak()
    }

    func continueDebugging() {
        guard isProgramPaused else { return }
        startProgramRun(startLine: nil, command: .continueExecution)
    }

    func stepDebugging() {
        if !isProgramPaused {
            rebuildProgramFromEditor()
        }
        startProgramRun(startLine: nil, command: isProgramPaused ? .stepInto : .runStep)
    }

    func stepOverDebugging() {
        if !isProgramPaused {
            rebuildProgramFromEditor()
        }
        startProgramRun(startLine: nil, command: isProgramPaused ? .stepOver : .runStep)
    }

    func stepOutDebugging() {
        guard isProgramPaused else { return }
        startProgramRun(startLine: nil, command: .stepOut)
    }

    fileprivate func handleTerminalInput(_ operations: [TerminalInputOperation]) {
        for operation in operations {
            switch operation {
            case .append(let text):
                consoleText += text
            case .submit(let command):
                consoleText += "\n"
                submitConsoleCommand(command, echo: false)
            }
        }
    }

    private func rebuildProgramFromEditor() {
        session.program.loadSource(programText)
    }

    private func saveProgram(to url: URL) {
        do {
            try programText.write(to: url, atomically: true, encoding: .utf8)
            currentProgramURL = url
            rebuildProgramFromEditor()
        } catch {
            presentFileError("Unable to save \(url.lastPathComponent).", error: error)
        }
    }

    private func presentFileError(_ message: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func appendConsoleOutput(_ text: String, terminator: String = "\n") {
        consoleText += text + terminator
    }

    private func echoConsoleCommand(_ command: String) {
        if !consoleText.hasSuffix(prompt) {
            consoleText += prompt
        }
        consoleText += command + "\n"
    }

    private func submitConsoleCommand(_ command: String, echo: Bool) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        editorErrorLine = nil
        if shouldUseEditorProgram(for: trimmed) {
            rebuildProgramFromEditor()
        }

        if echo {
            echoConsoleCommand(command)
        }

        if trimmed.uppercased() == "EDIT" {
            graphics.clear(color: nil)
            graphicsRevision += 1
            selectedPane = .editor
            return
        }

        if let startLine = runStartLine(from: trimmed) {
            startProgramRun(startLine: startLine, command: .run)
            return
        }

        if !trimmed.isEmpty {
            let shouldContinue = session.submit(command)
            if shouldSyncEditorAfterCommand(trimmed) {
                syncEditorFromSession()
            }
            if !shouldContinue {
                appendConsoleOutput("BYE")
                return
            }
        }

        consoleText += prompt
    }

    private enum DebugRunCommand: Sendable {
        case run
        case continueExecution
        case stepInto
        case stepOver
        case stepOut
        case runStep
    }

    private func startProgramRun(startLine: Int?, command: DebugRunCommand = .run) {
        guard !isProgramRunning else { return }
        let control = BASICExecutionControl()
        control.setBreakpoints(debuggerBreakpoints)
        switch command {
        case .run, .continueExecution:
            control.setMode(.run)
        case .stepInto, .runStep:
            control.setMode(.stepInto)
        case .stepOver:
            control.setMode(.stepOver(depth: session.debugCallDepth))
        case .stepOut:
            control.setMode(.stepOut(depth: session.debugCallDepth))
        }
        if command == .continueExecution || command == .stepInto || command == .stepOver || command == .stepOut {
            control.ignoreBreakpointOnce(at: activeExecutionControl?.location)
        }
        activeExecutionControl = control
        isProgramRunning = true
        isProgramPaused = false
        if command == .run || command == .runStep {
            debuggerExecutionLine = nil
        }
        let session = session

        executionQueue.async { [weak self, session, control, startLine, command] in
            let result: Result<Void, Error>
            do {
                switch command {
                case .run, .runStep:
                    try session.runProgram(startLine: startLine, executionControl: control)
                case .continueExecution, .stepInto, .stepOver, .stepOut:
                    try session.continueProgram(executionControl: control)
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self?.finishProgramRun(result)
            }
        }
    }

    private func finishProgramRun(_ result: Result<Void, Error>) {
        var paused = false
        var consoleMessage: String?
        switch result {
        case .success:
            debuggerExecutionLine = nil
            isProgramPaused = false
            debuggerCallStack = []
            debuggerSelectedCallStackFrameIndex = nil
            debuggerLocalVariables = []
            debuggerFrameLocalVariables = []
            debuggerGlobalVariables = session.debugGlobalVariables
            break
        case .failure(let error as BASICError):
            switch error {
            case .breakRequested(let line):
                debuggerExecutionLine = line.flatMap(sourceLineNumber(forBasicLineNumber:))
                paused = true
            case .breakpoint(let location):
                debuggerExecutionLine = location.lineNumber
                paused = true
            case .stepComplete(let location):
                debuggerExecutionLine = location.lineNumber
                paused = true
            default:
                isProgramPaused = false
                break
            }
            consoleMessage = session.debugPauseDescription(for: error)
        case .failure(let error):
            isProgramPaused = false
            consoleMessage = "Unexpected error: \(error)"
        }

        isProgramPaused = paused
        if paused {
            debuggerCallStack = session.debugCallStack
            debuggerLocalVariables = session.debugLocalVariables
            debuggerFrameLocalVariables = session.debugFrameLocalVariables
            if debuggerSelectedCallStackFrameIndex == nil ||
                !debuggerCallStack.contains(where: { $0.index == debuggerSelectedCallStackFrameIndex }) {
                debuggerSelectedCallStackFrameIndex = debuggerCallStack.first?.index
            }
            debuggerGlobalVariables = session.debugGlobalVariables
        }
        if !paused {
            debuggerCallStack = []
            debuggerSelectedCallStackFrameIndex = nil
            debuggerFrameLocalVariables = []
            activeExecutionControl = nil
        }
        isProgramRunning = false

        let debuggerIsActive = inspectorPane == .debug
        let shouldSuppressConsolePause = paused && debuggerIsActive
        if let consoleMessage, !shouldSuppressConsolePause {
            appendConsoleOutput(consoleMessage)
        }
        if !shouldSuppressConsolePause {
            consoleText += prompt
        }
    }

    private func runStartLine(from command: String) -> Int?? {
        let uppercased = command.uppercased()
        guard uppercased == "RUN" || uppercased.hasPrefix("RUN ") else { return nil }
        let rest = command.dropFirst(3).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return .some(nil) }
        guard let line = Int(rest) else { return nil }
        return .some(line)
    }

    private func shouldUseEditorProgram(for command: String) -> Bool {
        let keyword = command.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return keyword == "LIST" || keyword == "RUN" || keyword.hasPrefix("RUN ") || keyword == "SAVE" || keyword.hasPrefix("SAVE ")
    }

    private func shouldSyncEditorAfterCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let uppercased = trimmed.uppercased()
        return trimmed.first?.isNumber == true || uppercased == "NEW" || uppercased == "LOAD" || uppercased.hasPrefix("LOAD ")
    }

    private func syncEditorFromSession() {
        programText = session.program.listing()
    }

    private var debuggerFileName: String? {
        currentProgramURL?.lastPathComponent
    }

    private func sourceLineNumber(forBasicLineNumber lineNumber: Int) -> Int? {
        let lines = programText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.firstIndex { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("\(lineNumber) ")
                || line.trimmingCharacters(in: .whitespaces) == "\(lineNumber)"
        }.map { $0 + 1 }
    }

    private func saveSettings() {
        StudioSettingsStore.save(
            StudioSettings(
                editorTheme: editorTheme,
                isEditorGutterVisible: isEditorGutterVisible,
                terminalScreenSize: terminalScreenSize
            )
        )
    }

    private func highlightErrorIfPresent(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3,
              lines[1].contains("^"),
              lines[2].hasPrefix("Syntax error:") else { return }

        let source = lines[0].trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return }

        let programLines = programText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let index = programLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == source }) {
            editorErrorLine = index + 1
        }
    }

    nonisolated private func expandedPath(_ path: String) -> String {
        if path == "~" || path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst())
        }
        return path
    }

    nonisolated private func runOnMainSync(_ body: @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                body()
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    body()
                }
            }
        }
    }

    nonisolated private func valueOnMainSync<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                body()
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                body()
            }
        }
    }

    private static var basicProgramContentTypes: [UTType] {
        var types: [UTType] = [.plainText, .text, .sourceCode]
        if let basic = UTType(filenameExtension: "bas") {
            types.append(basic)
        }
        return types
    }

    private static func defaultProgramSource() -> String {
        let fileManager = FileManager.default
        if let source = bundledDemoSource(named: "studio/test-suite") {
            return source
        }

        let relativePath = "basicPrograms/demos/studio/test-suite.bas"
        let sourcePath = String(#filePath)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let candidates = [
            fileManager.currentDirectoryPath + "/" + relativePath,
            fileManager.currentDirectoryPath + "/../../" + relativePath,
            fileManager.currentDirectoryPath + "/basicPrograms/BASICStudio/test-suite.bas",
            sourceURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(relativePath)
                .path
        ]

        for path in candidates {
            if let source = try? String(contentsOfFile: path, encoding: .utf8) {
                return source
            }
        }

        return """
        print "AIBASIC SWIFTTERM"
        screen 1
        color 2
        line (10,10)-(310,10), 2
        line (310,10)-(310,190), 3
        line (310,190)-(10,190), 1
        line (10,190)-(10,10), 2
        pset (160,100), 3
        print "CENTER =", point(160,100)
        end
        """
    }

    private static func bundledDemoSource(named name: String) -> String? {
        let normalized = name.hasSuffix(".bas") ? String(name.dropLast(4)) : name
        for candidate in [
            normalized,
            "studio/\(normalized)",
            "shell/\(normalized)"
        ] {
            let url = URL(fileURLWithPath: candidate)
            let directory = url.deletingLastPathComponent().relativePath
            let subdirectory = directory == "." || directory.isEmpty ? "Demos" : "Demos/\(directory)"
            for resource in demoResourceCandidates(named: url.lastPathComponent, subdirectory: subdirectory) {
                if let source = try? String(contentsOf: resource, encoding: .utf8) {
                    return source
                }
            }
        }
        return nil
    }

    private static func availableBundledExamples() -> [BundledExample] {
        var examplesByPath: [String: BundledExample] = [:]
        for root in demoRootCandidates() {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                continue
            }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "bas" {
                guard let path = pathRelativeToDemoRoot(url, root: root) else { continue }
                examplesByPath[path] = BundledExample(path: path)
            }
        }

        return examplesByPath.values.sorted {
            $0.menuTitle.localizedStandardCompare($1.menuTitle) == .orderedAscending
        }
    }

    private static func demoRootCandidates() -> [URL] {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: String(#filePath))
        let packageRoot = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundleDemoRoot = Bundle.main.resourceURL?.appendingPathComponent("Demos")
        let bundleRootFallback = bundleDemoRoot.map { fileManager.fileExists(atPath: $0.path) } == true
            ? nil
            : Bundle.main.resourceURL

        let candidateURLs = [
            bundleDemoRoot,
            bundleRootFallback,
            packageRoot.appendingPathComponent("Sources/BASICStudio/Resources/Demos"),
            packageRoot
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("basicPrograms/demos"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Resources/Demos")
        ].compactMap { $0 }

        var seen: Set<String> = []
        return candidateURLs.filter { url in
            let key = url.standardizedFileURL.path
            guard fileManager.fileExists(atPath: key), !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private static func pathRelativeToDemoRoot(_ url: URL, root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(path.dropFirst(rootPath.count + 1))
        guard relative.hasSuffix(".bas") else { return nil }
        return String(relative.dropLast(4))
    }

    private static func demoResourceCandidates(named name: String, subdirectory: String) -> [URL] {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: String(#filePath))
        let packageRoot = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        return [
            Bundle.main.url(forResource: name, withExtension: "bas"),
            Bundle.main.url(forResource: name, withExtension: "bas", subdirectory: subdirectory),
            Bundle.main.resourceURL?
                .appendingPathComponent(subdirectory)
                .appendingPathComponent("\(name).bas"),
            packageRoot
                .appendingPathComponent("Sources/BASICStudio/Resources")
                .appendingPathComponent(subdirectory)
                .appendingPathComponent("\(name).bas"),
            packageRoot
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("basicPrograms/demos")
                .appendingPathComponent(String(subdirectory.dropFirst("Demos".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                .appendingPathComponent("\(name).bas"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Resources")
                .appendingPathComponent(subdirectory)
                .appendingPathComponent("\(name).bas")
        ].compactMap { $0 }
    }

    var programLineCount: Int {
        programText.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var consoleLineCount: Int {
        guard !consoleText.isEmpty else { return 0 }
        return consoleText.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

struct DebugPane: View {
    @ObservedObject var model: StudioModel
    @State private var isCallStackExpanded = true
    @State private var isLocalsExpanded = false
    @State private var isGlobalsExpanded = false
    @State private var codePaneHeight: CGFloat?
    @State private var dragStartCodePaneHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            debuggerControls
                .padding(10)

            Divider()

            GeometryReader { geometry in
                let codeHeight = resolvedCodePaneHeight(totalHeight: geometry.size.height)

                VStack(spacing: 0) {
                    MonacoEditor(
                        text: .constant(model.programText),
                        showsLineNumbers: true,
                        theme: model.editorTheme,
                        errorLine: model.editorErrorLine,
                        executionLine: model.debuggerExecutionLine,
                        breakpointLines: model.debuggerBreakpointLines,
                        isReadOnly: true,
                        findRequest: 0,
                        replaceRequest: 0,
                        breakpointToggle: { lineNumber in
                            model.toggleDebuggerBreakpoint(atSourceLine: lineNumber)
                        }
                    )
                    .frame(height: codeHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding([.top, .horizontal], 12)

                    DebugHorizontalDivider(
                        codePaneHeight: $codePaneHeight,
                        dragStartHeight: $dragStartCodePaneHeight,
                        availableHeight: geometry.size.height,
                        minimumCodeHeight: 160,
                        minimumVariablesHeight: 140
                    )

                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            DisclosureGroup("Call Stack", isExpanded: $isCallStackExpanded) {
                                callStackList(
                                    model.debuggerCallStack,
                                    selectedIndex: model.debuggerSelectedCallStackFrameIndex,
                                    selectFrame: model.selectDebuggerCallStackFrame
                                )
                            }

                            DisclosureGroup("Local Variables", isExpanded: $isLocalsExpanded) {
                                variableList(model.debuggerSelectedLocalVariables, emptyText: "No local variables are available.")
                            }

                            DisclosureGroup("Globals", isExpanded: $isGlobalsExpanded) {
                                variableList(model.debuggerGlobalVariables, emptyText: "No globals are available.")
                            }
                        }
                        .padding([.horizontal, .bottom], 12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var debuggerControls: some View {
        HStack(spacing: 10) {
            debugButton("Run", systemImage: "play.fill", isEnabled: !model.isProgramRunning) {
                model.runEditorProgram()
            }
            debugButton("Continue", systemImage: "forward.frame.fill", isEnabled: model.isProgramPaused && !model.isProgramRunning) {
                model.continueDebugging()
            }
            debugButton("Pause", systemImage: "pause.fill", isEnabled: model.isProgramRunning) {
                model.stopProgram()
            }
            debugButton("Step", systemImage: "arrow.down.to.line", isEnabled: !model.isProgramRunning) {
                model.stepDebugging()
            }
            debugButton("Step Over", systemImage: "arrow.turn.down.right", isEnabled: !model.isProgramRunning) {
                model.stepOverDebugging()
            }
            debugButton("Step Out", systemImage: "arrow.up.to.line", isEnabled: model.isProgramPaused && !model.isProgramRunning) {
                model.stepOutDebugging()
            }

            Spacer(minLength: 0)
        }
    }

    private func debugButton(_ title: String, systemImage: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
        .help(title)
    }

    private func resolvedCodePaneHeight(totalHeight: CGFloat) -> CGFloat {
        let minimumCodeHeight: CGFloat = 160
        let minimumVariablesHeight: CGFloat = 140
        let maximumCodeHeight = max(minimumCodeHeight, totalHeight - minimumVariablesHeight)
        let preferredHeight = codePaneHeight ?? max(260, totalHeight * 0.62)
        return min(max(preferredHeight, minimumCodeHeight), maximumCodeHeight)
    }

    @ViewBuilder
    private func callStackList(
        _ frames: [BASICCallStackFrame],
        selectedIndex: Int?,
        selectFrame: @escaping (BASICCallStackFrame) -> Void
    ) -> some View {
        if frames.isEmpty {
            Text("No active stack frames.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 0) {
                ForEach(frames) { frame in
                    Button {
                        selectFrame(frame)
                    } label: {
                        HStack(spacing: 8) {
                            Text(frame.kind)
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .leading)
                            Text(frame.name)
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let metadata = callStackMetadata(for: frame) {
                                Text(metadata)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if let location = frame.location {
                                Text("\(location.lineNumber)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(frame.index == selectedIndex ? Color.accentColor.opacity(0.18) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)

                    Divider()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func callStackMetadata(for frame: BASICCallStackFrame) -> String? {
        var parts: [String] = []
        if frame.isOverride {
            parts.append("override")
        }
        if let receiverClassName = frame.receiverClassName,
           let declaringClassName = frame.declaringClassName,
           receiverClassName.caseInsensitiveCompare(declaringClassName) != .orderedSame {
            parts.append("on \(receiverClassName)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func variableList(_ variables: [BASICVariableSnapshot], emptyText: String) -> some View {
        if variables.isEmpty {
            Text(emptyText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 0) {
                ForEach(variables) { variable in
                    variableNode(variable, indent: 0)
                    Divider()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func variableNode(_ variable: BASICVariableSnapshot, indent: CGFloat) -> AnyView {
        if variable.children.isEmpty {
            return AnyView(variableRow(variable, indent: indent))
        } else {
            return AnyView(DisclosureGroup {
                VStack(spacing: 0) {
                    ForEach(variable.children) { child in
                        variableNode(child, indent: indent + 14)
                        Divider()
                    }
                }
            } label: {
                variableRow(variable, indent: indent)
            }
            .disclosureGroupStyle(.automatic))
        }
    }

    private func variableRow(_ variable: BASICVariableSnapshot, indent: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(variable.name)
                .fontWeight(.medium)
                .padding(.leading, indent)
                .frame(minWidth: 70 + indent, alignment: .leading)
            Text(variable.typeName)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(variable.value)
                .monospaced()
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .padding(.vertical, 5)
    }
}

struct DebugHorizontalDivider: View {
    @Binding var codePaneHeight: CGFloat?
    @Binding var dragStartHeight: CGFloat?
    let availableHeight: CGFloat
    let minimumCodeHeight: CGFloat
    let minimumVariablesHeight: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 44, height: 3)
            Color.clear
                .frame(height: 12)
        }
        .frame(height: 12)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartHeight == nil {
                        dragStartHeight = codePaneHeight ?? defaultCodeHeight
                    }
                    let maximumHeight = max(minimumCodeHeight, availableHeight - minimumVariablesHeight)
                    let proposedHeight = (dragStartHeight ?? defaultCodeHeight) + value.translation.height
                    codePaneHeight = min(max(proposedHeight, minimumCodeHeight), maximumHeight)
                }
                .onEnded { _ in
                    dragStartHeight = nil
                }
        )
        .help("Resize debugger panes")
    }

    private var defaultCodeHeight: CGFloat {
        min(max(max(260, availableHeight * 0.62), minimumCodeHeight), max(minimumCodeHeight, availableHeight - minimumVariablesHeight))
    }
}

struct UserDocumentationPane: View {
    @State private var docs = UserDoc.loadAll()
    @State private var selectedDocID: UserDoc.ID?

    private var selectedDocBinding: Binding<UserDoc.ID> {
        Binding(
            get: { selectedDocID ?? docs.first?.id ?? "" },
            set: { selectedDocID = $0 }
        )
    }

    private var selectedDoc: UserDoc? {
        let id = selectedDocID ?? docs.first?.id
        return docs.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Documentation")
                    .font(.headline)
                Spacer()
                if !docs.isEmpty {
                    Picker("Topic", selection: selectedDocBinding) {
                        ForEach(docs) { doc in
                            Text(doc.title).tag(doc.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                if let selectedDoc {
                    Markdown(selectedDoc.content)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                } else {
                    Text("No documentation found.")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            selectedDocID = selectedDocID ?? docs.first?.id
        }
    }
}

struct UserDoc: Identifiable, Hashable {
    let id: String
    let title: String
    let content: String

    static func loadAll() -> [UserDoc] {
        for directory in documentationDirectories() {
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                continue
            }

            let docs = files
                .filter { $0.pathExtension.lowercased() == "md" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { url -> UserDoc? in
                    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                    return UserDoc(
                        id: url.lastPathComponent,
                        title: title(from: content, fallback: url.deletingPathExtension().lastPathComponent),
                        content: content
                    )
                }

            if !docs.isEmpty {
                return docs
            }
        }

        return []
    }

    private static func documentationDirectories() -> [URL] {
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = URL(fileURLWithPath: String(#filePath))
        return [
            currentDirectory.appendingPathComponent("UserDocs"),
            currentDirectory.appendingPathComponent("Code/BASICStudio/UserDocs"),
            sourceURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("UserDocs")
        ]
    }

    private static func title(from content: String, fallback: String) -> String {
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("# ") {
                return String(line.dropFirst(2))
            }
        }
        return fallback.replacingOccurrences(of: "_", with: " ")
    }
}

extension StudioModel: StudioDebuggerInterface {}

extension StudioModel: BASICHost {
    nonisolated func print(_ text: String, terminator: String) {
        runOnMainSync {
            highlightErrorIfPresent(text)
            appendConsoleOutput(text, terminator: terminator)
        }
    }

    nonisolated func printLine(_ text: String) {
        runOnMainSync {
            highlightErrorIfPresent(text)
            appendConsoleOutput(text)
        }
    }

    nonisolated func readLine(prompt: String) -> String? {
        nil
    }
}

extension StudioModel: BASICFileHost, BASICSystemHost {
    nonisolated func loadTextFile(path: String) throws -> String {
        try String(contentsOfFile: expandedPath(path), encoding: .utf8)
    }

    nonisolated func saveTextFile(path: String, text: String) throws {
        try text.write(toFile: expandedPath(path), atomically: true, encoding: .utf8)
    }

    nonisolated func listFiles() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: FileManager.default.currentDirectoryPath)
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

extension StudioModel: BASICGraphicsHost {
    nonisolated func setScreenMode(_ mode: BASICScreenMode) {
        runOnMainSync {
            graphics.setMode(mode)
            graphicsRevision += 1
        }
    }

    nonisolated func setGraphicsColor(_ color: Int) {
        runOnMainSync {
            graphics.currentColor = color
        }
    }

    nonisolated func clearGraphics(color: Int?) {
        runOnMainSync {
            graphics.clear(color: color)
            graphicsRevision += 1
        }
    }

    nonisolated func setPixel(x: Int, y: Int, color: Int) {
        runOnMainSync {
            graphics.setPixel(x: x, y: y, color: color)
            graphicsRevision += 1
        }
    }

    nonisolated func getPixel(x: Int, y: Int) -> Int {
        valueOnMainSync {
            graphics.getPixel(x: x, y: y)
        }
    }

    nonisolated func drawLine(x1: Int, y1: Int, x2: Int, y2: Int, color: Int) {
        runOnMainSync {
            graphics.drawLine(x1: x1, y1: y1, x2: x2, y2: y2, color: color)
            graphicsRevision += 1
        }
    }
}

final class GraphicsFramebuffer {
    private(set) var mode = BASICScreenMode(number: 0, width: 0, height: 0, colorCount: 0)
    private(set) var pixels: [Int] = []
    var currentColor = 1

    var isEnabled: Bool {
        mode.width > 0 && mode.height > 0
    }

    func setMode(_ mode: BASICScreenMode) {
        self.mode = mode
        pixels = Array(repeating: 0, count: max(0, mode.width * mode.height))
    }

    func clear(color: Int?) {
        guard isEnabled else { return }
        pixels = Array(repeating: color ?? 0, count: mode.width * mode.height)
    }

    func setPixel(x: Int, y: Int, color: Int) {
        guard isEnabled, x >= 0, y >= 0, x < mode.width, y < mode.height else { return }
        pixels[y * mode.width + x] = normalized(color)
    }

    func getPixel(x: Int, y: Int) -> Int {
        guard isEnabled, x >= 0, y >= 0, x < mode.width, y < mode.height else { return 0 }
        return pixels[y * mode.width + x]
    }

    func drawLine(x1: Int, y1: Int, x2: Int, y2: Int, color: Int) {
        var x = x1
        var y = y1
        let dx = abs(x2 - x1)
        let sx = x1 < x2 ? 1 : -1
        let dy = -abs(y2 - y1)
        let sy = y1 < y2 ? 1 : -1
        var error = dx + dy

        while true {
            setPixel(x: x, y: y, color: color)
            if x == x2 && y == y2 { break }
            let nextError = 2 * error
            if nextError >= dy {
                error += dy
                x += sx
            }
            if nextError <= dx {
                error += dx
                y += sy
            }
        }
    }

    private func normalized(_ color: Int) -> Int {
        guard mode.colorCount > 0 else { return max(0, color) }
        return max(0, color) % mode.colorCount
    }
}

struct SwiftTermGraphicsConsole: NSViewRepresentable {
    @ObservedObject var model: StudioModel

    func makeNSView(context: Context) -> AIBasicTerminalContainerView {
        let view = AIBasicTerminalContainerView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: AIBasicTerminalContainerView, context: Context) {
        nsView.model = model
        nsView.render(
            consoleText: model.consoleText,
            graphics: model.graphics,
            revision: model.graphicsRevision,
            screenSize: model.terminalScreenSize
        )
    }
}

final class AIBasicTerminalContainerView: NSView, @preconcurrency TerminalViewDelegate {
    weak var model: StudioModel?

    private let terminalView = TerminalView(frame: .zero, font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
    private let overlayView = GraphicsOverlayView(frame: .zero)
    private var renderedCharacterCount = 0
    private var renderedRevision = -1
    private var renderedScreenSize: TerminalScreenSize?
    private var inputBuffer = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        terminalView.terminalDelegate = self
        terminalView.configureNativeColors()
        terminalView.linkReporting = .none
        terminalView.getTerminal().resize(cols: 80, rows: 25)

        addSubview(terminalView)
        addSubview(overlayView, positioned: .above, relativeTo: terminalView)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(terminalView)
    }

    override func layout() {
        super.layout()
        applyScreenSize(force: false)
    }

    func render(consoleText: String, graphics: GraphicsFramebuffer, revision: Int, screenSize: TerminalScreenSize) {
        if renderedScreenSize != screenSize {
            renderedScreenSize = screenSize
            applyScreenSize(force: true)
        }

        if consoleText.count < renderedCharacterCount {
            terminalView.getTerminal().resetToInitialState()
            renderedCharacterCount = 0
            inputBuffer = ""
        }

        if consoleText.count > renderedCharacterCount {
            let start = consoleText.index(consoleText.startIndex, offsetBy: renderedCharacterCount)
            let newText = String(consoleText[start...]).replacingOccurrences(of: "\n", with: "\r\n")
            feedTerminal(newText)
            renderedCharacterCount = consoleText.count
        }

        if revision != renderedRevision {
            overlayView.framebuffer = graphics
            overlayView.needsDisplay = true
            renderedRevision = revision
        }
    }

    private func applyScreenSize(force: Bool) {
        let screenSize = renderedScreenSize ?? .flexible
        if let dimensions = screenSize.dimensions {
            terminalView.getTerminal().resize(cols: dimensions.cols, rows: dimensions.rows)
            let optimalSize = terminalView.getOptimalFrameSize().size
            let width = min(bounds.width, optimalSize.width)
            let height = min(bounds.height, optimalSize.height)
            let frame = CGRect(
                x: bounds.midX - width / 2,
                y: bounds.midY - height / 2,
                width: width,
                height: height
            )
            terminalView.frame = frame
            overlayView.frame = frame
            terminalView.needsDisplay = true
            overlayView.needsDisplay = true
            return
        }

        guard force || bounds.width > 0 else { return }
        terminalView.frame = bounds
        overlayView.frame = bounds
        terminalView.sizeChanged(source: terminalView.getTerminal())
        terminalView.needsDisplay = true
        overlayView.needsDisplay = true
    }

    private func feedTerminal(_ text: String) {
        terminalView.getTerminal().feed(text: text)
        refreshTerminalDisplay()
    }

    private func refreshTerminalDisplay() {
        let terminal = terminalView.getTerminal()
        terminal.refresh(startRow: 0, endRow: max(0, terminal.rows - 1))
        terminalView.needsDisplay = true
        terminalView.setNeedsDisplay(terminalView.bounds)
        positionSwiftTermCaret()
    }

    private func positionSwiftTermCaret() {
        guard terminalView.frame.width > 0, terminalView.frame.height > 0 else { return }

        let terminal = terminalView.getTerminal()
        let cellWidth = terminalView.frame.width / CGFloat(max(terminal.cols, 1))
        let cellHeight = terminalView.frame.height / CGFloat(max(terminal.rows, 1))
        let x = CGFloat(min(max(terminal.buffer.x, 0), max(terminal.cols - 1, 0))) * cellWidth
        let y = terminalView.frame.height - (CGFloat(min(max(terminal.buffer.y, 0), max(terminal.rows - 1, 0))) + 1) * cellHeight

        for subview in terminalView.subviews where String(describing: type(of: subview)).contains("CaretView") {
            subview.frame.origin = CGPoint(x: x, y: y)
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        var operations: [TerminalInputOperation] = []

        for byte in data {
            switch byte {
            case 10, 13:
                let command = inputBuffer
                inputBuffer = ""
                operations.append(.submit(command))
            case 8, 127:
                guard !inputBuffer.isEmpty else { continue }
                inputBuffer.removeLast()
                operations.append(.append("\u{8} \u{20}\u{8}"))
            case 32...126:
                let scalar = UnicodeScalar(byte)
                let character = String(Character(scalar))
                inputBuffer.append(character)
                operations.append(.append(character))
            default:
                break
            }
        }

        guard !operations.isEmpty else { return }
        Task { @MainActor [weak model] in
            model?.handleTerminalInput(operations)
        }
    }
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

final class GraphicsOverlayView: NSView {
    weak var framebuffer: GraphicsFramebuffer?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let framebuffer, framebuffer.isEnabled else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let destination = aspectFitRect(
            source: CGSize(width: framebuffer.mode.width, height: framebuffer.mode.height),
            destination: bounds.insetBy(dx: 8, dy: 8)
        )
        guard destination.width > 0, destination.height > 0 else { return }

        context.saveGState()
        context.interpolationQuality = .none
        context.setFillColor(NSColor.black.withAlphaComponent(0.08).cgColor)
        context.fill(destination)

        let pixelWidth = destination.width / CGFloat(framebuffer.mode.width)
        let pixelHeight = destination.height / CGFloat(framebuffer.mode.height)

        for y in 0..<framebuffer.mode.height {
            for x in 0..<framebuffer.mode.width {
                let color = framebuffer.getPixel(x: x, y: y)
                guard color != 0 else { continue }
                context.setFillColor(Self.palette[color % Self.palette.count].cgColor)
                context.fill(CGRect(
                    x: destination.minX + CGFloat(x) * pixelWidth,
                    y: destination.maxY - CGFloat(y + 1) * pixelHeight,
                    width: max(1, pixelWidth),
                    height: max(1, pixelHeight)
                ))
            }
        }

        context.restoreGState()
    }

    private func aspectFitRect(source: CGSize, destination: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return .zero }
        let scale = min(destination.width / source.width, destination.height / source.height)
        let width = floor(source.width * scale)
        let height = floor(source.height * scale)
        return CGRect(
            x: destination.midX - width / 2,
            y: destination.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static let palette: [NSColor] = [
        .clear,
        .white,
        .systemRed,
        .systemGreen,
        .systemBlue,
        .systemYellow,
        .systemPurple,
        .systemOrange,
        .systemCyan,
        .systemPink,
        .lightGray,
        .darkGray,
        NSColor(calibratedRed: 0.0, green: 0.7, blue: 0.35, alpha: 1),
        NSColor(calibratedRed: 0.6, green: 0.35, blue: 1.0, alpha: 1),
        NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.1, alpha: 1),
        .black
    ]
}
