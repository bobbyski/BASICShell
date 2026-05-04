import BASICCore
import AppKit
import SwiftUI
import SwiftTerm

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

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Program")
                        .font(.headline)
                    TextEditor(text: $model.programText)
                        .font(.system(.body, design: .monospaced))
                        .border(Color.secondary.opacity(0.35))
                }
                .frame(minWidth: 320)
                .padding()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Console")
                        .font(.headline)
                    SwiftTermGraphicsConsole(model: model)
                    .border(Color.secondary.opacity(0.35))
                }
                .frame(minWidth: 300)
                .padding()
            }

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
        .onAppear {
            model.runStartupProgramIfNeeded()
        }
    }
}

@MainActor
final class StudioModel: ObservableObject {
    @Published var programText = """
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
    @Published var consoleText = ""
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

    func runEditorProgram() {
        rebuildProgramFromEditor()
        appendConsole("> RUN")
        _ = session.submit("RUN")
    }

    func listProgram() {
        rebuildProgramFromEditor()
        appendConsole("> LIST")
        _ = session.submit("LIST")
    }

    func clearProgram() {
        _ = session.submit("NEW")
        programText = ""
        consoleText = ""
        graphics.clear(color: nil)
        graphicsRevision += 1
    }

    func submitCommand() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appendConsole("> \(trimmed)")
        _ = session.submit(trimmed)
        command = ""
    }

    private func rebuildProgramFromEditor() {
        _ = session.submit("NEW")
        session.program.loadSource(programText)
    }

    private func appendConsole(_ text: String) {
        if consoleText.isEmpty {
            consoleText = text
        } else {
            consoleText += "\n" + text
        }
    }

    private func expandedPath(_ path: String) -> String {
        if path == "~" || path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst())
        }
        return path
    }
}

extension StudioModel: BASICHost {
    nonisolated func printLine(_ text: String) {
        Task { @MainActor in
            appendConsole(text)
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
        AIBasicTerminalContainerView()
    }

    func updateNSView(_ nsView: AIBasicTerminalContainerView, context: Context) {
        nsView.render(consoleText: model.consoleText, graphics: model.graphics, revision: model.graphicsRevision)
    }
}

final class AIBasicTerminalContainerView: NSView, @preconcurrency TerminalViewDelegate {
    private let terminalView = TerminalView(frame: .zero, font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
    private let overlayView = GraphicsOverlayView(frame: .zero)
    private var renderedCharacterCount = 0
    private var renderedRevision = -1

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

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.terminalDelegate = self
        terminalView.configureNativeColors()
        terminalView.linkReporting = .none

        overlayView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(terminalView)
        addSubview(overlayView, positioned: .above, relativeTo: terminalView)

        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func render(consoleText: String, graphics: GraphicsFramebuffer, revision: Int) {
        if consoleText.count < renderedCharacterCount {
            terminalView.getTerminal().resetToInitialState()
            renderedCharacterCount = 0
        }

        if consoleText.count > renderedCharacterCount {
            let start = consoleText.index(consoleText.startIndex, offsetBy: renderedCharacterCount)
            let newText = String(consoleText[start...]).replacingOccurrences(of: "\n", with: "\r\n")
            terminalView.getTerminal().feed(text: newText)
            terminalView.needsDisplay = true
            renderedCharacterCount = consoleText.count
        }

        if revision != renderedRevision {
            overlayView.framebuffer = graphics
            overlayView.needsDisplay = true
            renderedRevision = revision
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
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
