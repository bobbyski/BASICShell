import BASICCore
import AppKit
import MarkdownUI
import SwiftUI
import SwiftTerm
import WebKit

@main
struct BASICStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("AIBasic Studio") {
            StudioView()
                .frame(minWidth: 760, minHeight: 520)
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
    @StateObject private var model = StudioModel()
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
                    errorLine: model.editorErrorLine
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
            Color.clear
                .frame(width: 8)
        }
        .frame(width: 8)
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

enum TerminalScreenSize: String, CaseIterable {
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

struct MonacoEditor: NSViewRepresentable {
    @Binding var text: String
    let showsLineNumbers: Bool
    let errorLine: Int?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
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
        context.coordinator.sync(text: text, showsLineNumbers: showsLineNumbers, errorLine: errorLine)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "basicStudio")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        var text: Binding<String>
        weak var webView: WKWebView?
        private var isReady = false
        private var pendingText: String?
        private var pendingShowsLineNumbers: Bool?
        private var pendingErrorLine: Int?
        private var lastAppliedText: String?
        private var lastAppliedShowsLineNumbers: Bool?
        private var lastAppliedErrorLine: Int?

        init(text: Binding<String>) {
            self.text = text
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
            default:
                break
            }
        }

        func sync(text: String, showsLineNumbers: Bool, errorLine: Int?) {
            pendingText = text
            pendingShowsLineNumbers = showsLineNumbers
            pendingErrorLine = errorLine
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

            if pendingErrorLine != lastAppliedErrorLine {
                if let pendingErrorLine {
                    webView.evaluateJavaScript("window.basicStudioSetErrorLine(\(pendingErrorLine));")
                } else {
                    webView.evaluateJavaScript("window.basicStudioSetErrorLine(null);")
                }
                lastAppliedErrorLine = pendingErrorLine
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
          background: #ffffff;
        }
        .basic-error-line {
          background: rgba(255, 59, 48, 0.16);
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
        let suppressChange = false;
        let errorDecorations = [];

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
            glyphMargin: false,
            folding: show
          });
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

        require.config({ paths: { vs: "https://cdn.jsdelivr.net/npm/monaco-editor@0.49.0/min/vs" } });
        require(["vs/editor/editor.main"], function() {
          monaco.languages.register({ id: "aibasic" });
          monaco.languages.setMonarchTokensProvider("aibasic", {
            ignoreCase: true,
            tokenizer: {
              root: [
                [/\\b(PRINT|LET|GLOBAL|LOCAL|OPTION|INPUT|GOTO|GOSUB|RETURN|IF|THEN|SELECT|CASE|ELSE|END|EXIT|REM|RUN|LIST|LOAD|NEW|CLEAR|HELP|SCREEN|COLOR|CLS|PSET|PRESET|LINE|POINT|TO|IS|AS|TRUE|FALSE)\\b/, "keyword"],
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
            theme: "vs",
            automaticLayout: true,
            minimap: { enabled: false },
            scrollBeyondLastLine: false,
            fontFamily: "SFMono-Regular, Menlo, Monaco, Consolas, monospace",
            fontSize: 13,
            lineNumbers: pendingLineNumbers ? "on" : "off",
            glyphMargin: false,
            folding: pendingLineNumbers,
            lineDecorationsWidth: 8,
            lineNumbersMinChars: 3,
            renderLineHighlight: "line",
            wordWrap: "off"
          });

          editor.onDidChangeModelContent(function() {
            if (!suppressChange) {
              post({ type: "change", text: editor.getValue() });
            }
          });

          post({ type: "ready" });
        });
      </script>
    </body>
    </html>
    """
}

@MainActor
final class StudioModel: ObservableObject {
    private let prompt = "READY\n> "

    @Published var selectedPane: StudioPane = .console
    @Published var inspectorPane: InspectorPane?
    @Published var isCommandBarVisible = false
    @Published var isEditorGutterVisible = false
    @Published var editorErrorLine: Int?
    @Published var terminalScreenSize: TerminalScreenSize = .flexible
    @Published var programText = StudioModel.defaultProgramSource()
    @Published var consoleText = "READY\n> "
    @Published var command = ""
    @Published var graphicsRevision = 0

    let graphics = GraphicsFramebuffer()
    private var shouldRunStartupProgram = false

    private lazy var session = BASICSession(host: self)

    init() {
        if let path = CommandLine.arguments.dropFirst().first,
           let source = try? String(contentsOfFile: expandedPath(path), encoding: .utf8) {
            programText = source
            shouldRunStartupProgram = true
        }
    }

    func runStartupProgramIfNeeded() {
        guard shouldRunStartupProgram else { return }
        shouldRunStartupProgram = false
        runEditorProgram()
    }

    func toggleInspector(_ pane: InspectorPane) {
        inspectorPane = inspectorPane == pane ? nil : pane
    }

    func runEditorProgram() {
        rebuildProgramFromEditor()
        selectedPane = .console
        submitConsoleCommand("RUN", echo: true)
    }

    func listProgram() {
        rebuildProgramFromEditor()
        selectedPane = .console
        submitConsoleCommand("LIST", echo: true)
    }

    func clearProgram() {
        _ = session.submit("NEW")
        programText = ""
        consoleText = prompt
        graphics.clear(color: nil)
        graphicsRevision += 1
    }

    func submitCommand() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectedPane = .console
        submitConsoleCommand(trimmed, echo: true)
        command = ""
    }

    func submitConsoleLineFromTerminal(_ command: String) {
        submitConsoleCommand(command, echo: false)
    }

    private func rebuildProgramFromEditor() {
        _ = session.submit("NEW")
        session.program.loadSource(programText)
    }

    private func appendConsoleOutput(_ text: String) {
        consoleText += text + "\n"
    }

    private func submitConsoleCommand(_ command: String, echo: Bool) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        editorErrorLine = nil
        if shouldUseEditorProgram(for: trimmed) {
            rebuildProgramFromEditor()
        }

        if echo {
            if !consoleText.hasSuffix(prompt) {
                consoleText += prompt
            }
            consoleText += command + "\n"
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

    private func shouldUseEditorProgram(for command: String) -> Bool {
        let keyword = command.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return keyword == "LIST" || keyword == "RUN"
    }

    private func shouldSyncEditorAfterCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let uppercased = trimmed.uppercased()
        return trimmed.first?.isNumber == true || uppercased == "NEW" || uppercased.hasPrefix("LOAD ")
    }

    private func syncEditorFromSession() {
        programText = session.program.listing()
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

    private func expandedPath(_ path: String) -> String {
        if path == "~" || path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst())
        }
        return path
    }

    private static func defaultProgramSource() -> String {
        let fileManager = FileManager.default
        let relativePath = "basicPrograms/BASICStudio/test-suite.bas"
        let sourcePath = String(#filePath)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let candidates = [
            fileManager.currentDirectoryPath + "/" + relativePath,
            fileManager.currentDirectoryPath + "/../../" + relativePath,
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Debug")
                .font(.headline)

            Divider()

            debugRow("View", value: model.selectedPane == .editor ? "Editor" : "Console")
            debugRow("Program Lines", value: "\(model.programLineCount)")
            debugRow("Console Lines", value: "\(model.consoleLineCount)")
            debugRow("Screen Size", value: model.terminalScreenSize.label)
            debugRow("Graphics Mode", value: "\(model.graphics.mode.number)")
            debugRow("Graphics Size", value: graphicsSize)
            debugRow("Graphics Colors", value: "\(model.graphics.mode.colorCount)")
            debugRow("Current Color", value: "\(model.graphics.currentColor)")
            debugRow("Revision", value: "\(model.graphicsRevision)")

            Spacer(minLength: 0)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var graphicsSize: String {
        guard model.graphics.isEnabled else { return "Off" }
        return "\(model.graphics.mode.width) x \(model.graphics.mode.height)"
    }

    private func debugRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.callout)
    }
}

struct UserDocumentationPane: View {
    @State private var docs = UserDoc.loadAll()
    @State private var selectedDocID: UserDoc.ID?

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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            HSplitView {
                List(docs, selection: $selectedDocID) { doc in
                    Text(doc.title)
                        .lineLimit(1)
                        .tag(doc.id)
                }
                .frame(minWidth: 120, idealWidth: 150, maxWidth: 190)

                ScrollView {
                    if let selectedDoc {
                        Markdown(selectedDoc.content)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    } else {
                        Text("No documentation found.")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                }
                .frame(minWidth: 170)
            }
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

extension StudioModel: BASICHost {
    nonisolated func printLine(_ text: String) {
        MainActor.assumeIsolated {
            highlightErrorIfPresent(text)
            appendConsoleOutput(text)
        }
    }

    nonisolated func readLine(prompt: String) -> String? {
        nil
    }
}

extension StudioModel: @preconcurrency BASICGraphicsHost {
    func setScreenMode(_ mode: BASICScreenMode) {
        graphics.setMode(mode)
        graphicsRevision += 1
    }

    func setGraphicsColor(_ color: Int) {
        graphics.currentColor = color
    }

    func clearGraphics(color: Int?) {
        graphics.clear(color: color)
        graphicsRevision += 1
    }

    func setPixel(x: Int, y: Int, color: Int) {
        graphics.setPixel(x: x, y: y, color: color)
        graphicsRevision += 1
    }

    func getPixel(x: Int, y: Int) -> Int {
        graphics.getPixel(x: x, y: y)
    }

    func drawLine(x1: Int, y1: Int, x2: Int, y2: Int, color: Int) {
        graphics.drawLine(x1: x1, y1: y1, x2: x2, y2: y2, color: color)
        graphicsRevision += 1
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
        for byte in data {
            switch byte {
            case 10, 13:
                feedTerminal("\r\n")
                let command = inputBuffer
                inputBuffer = ""
                Task { @MainActor [weak model] in
                    model?.submitConsoleLineFromTerminal(command)
                }
            case 8, 127:
                guard !inputBuffer.isEmpty else { continue }
                inputBuffer.removeLast()
                feedTerminal("\u{8} \u{20}\u{8}")
            case 32...126:
                let scalar = UnicodeScalar(byte)
                let character = String(Character(scalar))
                inputBuffer.append(character)
                feedTerminal(character)
            default:
                break
            }
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
