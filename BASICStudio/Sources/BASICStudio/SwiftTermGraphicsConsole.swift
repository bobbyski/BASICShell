import BASICCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreText
import GameController
import MarkdownUI
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import VectorTerminalSDK
import WebKit

#if os(macOS)
struct SwiftTermGraphicsConsole: NSViewRepresentable {
    @ObservedObject var model: StudioModel

    func makeNSView(context: Context) -> AIBasicTerminalContainerView {
        let view = AIBasicTerminalContainerView()
        view.attach(to: model)
        return view
    }

    func updateNSView(_ nsView: AIBasicTerminalContainerView, context: Context) {
        nsView.attach(to: model)
        nsView.render(ConsoleRenderInput(model))
    }
}
#endif

#if os(macOS)
/// The console's base view and font: AppKit's on the Mac, UIKit's on iPhone
/// and iPad, where SwiftTerm's VectorTerminalView is a UIKit view.
typealias ConsoleBaseView = NSView
typealias ConsoleFont = NSFont
typealias ConsoleTerminal = VectorTerminalView
#else
typealias ConsoleBaseView = UIView
typealias ConsoleFont = UIFont
/// SwiftTerm's view with the console asked about hardware keys first.
typealias ConsoleTerminal = ConsoleTerminalView
#endif

@MainActor
final class AIBasicTerminalContainerView: ConsoleBaseView, @preconcurrency TerminalViewDelegate {
    weak var model: StudioModel?

    private let terminalView = ConsoleTerminal(frame: .zero, font: ConsoleFont.monospacedSystemFont(ofSize: 13, weight: .regular))
    private var renderedCharacterCount = 0
    private var renderedScrollbackLines: Int?
    private var renderedScreenSize: TerminalScreenSize?
    private var renderedFontFamily: String?
    private var renderedFontSize: Double?
    private var renderedGraphicsLayersVisible: Bool?
    private var inputBuffer = ""
    private var inputCursor = 0
    private var inputFieldViewStart = 0
    private var inputFieldDisplayCursor = 0
    private var hasInitializedLineInputDefault = false
    private var commandHistory = AIBasicTerminalContainerView.loadCommandHistory()
    private var commandHistoryIndex: Int?
    private var draftBeforeCommandHistory = ""
    private var completionMenu: CompletionMenu?
    private var keyMonitor: Any?
    private var mouseUpMonitor: Any?
    /// Key-ups and modifier changes, for KEYDOWN (``StudioHeldKeys``).
    private var heldKeyMonitor: Any?
    private var heldKeyObservers: [NSObjectProtocol] = []
    private var pendingEscapeBytes: [UInt8] = []
    private var pendingEscapeFlushID = 0
    #if os(macOS)
    private var mouseTrackingArea: NSTrackingArea?
    #else
    /// The program's on-screen controls, over the terminal (BASIC-11).
    private let touchControlsView = StudioTouchControlsView(frame: .zero)
    /// The button a touch or pointer press went down with, for its moves and
    /// its release: 0 for a finger or a primary click, 1 for a secondary one.
    private var touchMouseButton = 0
    #endif
    private var lastMouseEventTimestamp: TimeInterval?
    private var lastMouseMovePostTimestamp: TimeInterval?
    private var lastPostedVTGCanvasSize: (width: Int, height: Int)?
    private var isVTGDisplayInvalidationScheduled = false

    deinit {
        #if os(macOS)
        MainActor.assumeIsolated {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
        }
        if let heldKeyMonitor {
            NSEvent.removeMonitor(heldKeyMonitor)
        }
        heldKeyObservers.forEach(NotificationCenter.default.removeObserver)
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }
        }
        #else
        MainActor.assumeIsolated {
            heldKeyObservers.forEach(NotificationCenter.default.removeObserver)
        }
        #endif
    }

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        #if os(macOS)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        #else
        backgroundColor = .systemBackground
        #endif

        terminalView.terminalDelegate = self
        #if os(macOS)
        terminalView.configureNativeColors()
        #else
        applyNativeColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (console: Self, _: UITraitCollection) in
            console.applyNativeColors()
        }
        #endif
        terminalView.linkReporting = .none
        terminalView.getTerminal().resize(cols: 80, rows: 25)
        #if os(macOS)
        installKeyMonitor()
        installHeldKeyMonitor()
        installMouseUpMonitor()
        #else
        // On iPhone and iPad the terminal view takes the keyboard itself and
        // hands its bytes to `send`; it asks here first about each hardware
        // key, as the Mac's key monitor does.
        terminalView.pressInterceptor = { [weak self] press in
            self?.handleProgramKey(press) ?? false
        }
        terminalView.onKeyHeld = { [weak self] name, down in
            self?.model?.heldKeys.set(name, down: down)
        }
        // Away from the app, no key-up arrives for what is held.
        heldKeyObservers = [
            NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model?.heldKeys.releaseAll() }
            },
        ]
        installTouchMouse()
        #endif

        addSubview(terminalView)
        #if os(iOS)
        addSubview(touchControlsView)
        #endif
    }

    #if os(macOS)
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.window === self.window else { return event }
            // Held, whoever takes the key: KEYDOWN sees it either way.
            if let name = Self.consoleKeyPress(from: event).heldKeyName {
                self.model?.heldKeys.set(name, down: true)
            }
            guard self.handleProgramKeyEvent(event) else { return event }
            return nil
        }
    }

    /// The other half of a held key: its key-up, and the modifiers, which
    /// AppKit reports as flag changes rather than as keys. When the window
    /// or the app loses the keyboard no key-up will come, so everything
    /// counts as released.
    private func installHeldKeyMonitor() {
        guard heldKeyMonitor == nil else { return }
        heldKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.window, let held = self.model?.heldKeys else { return event }
            if event.type == .keyUp {
                if let name = Self.consoleKeyPress(from: event).heldKeyName {
                    held.set(name, down: false)
                }
            } else {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                held.set("SHIFT", down: flags.contains(.shift))
                held.set("CONTROL", down: flags.contains(.control))
                held.set("OPTION", down: flags.contains(.option))
                held.set("COMMAND", down: flags.contains(.command))
            }
            return event
        }
        let releaseAll: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.model?.heldKeys.releaseAll() }
        }
        heldKeyObservers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: releaseAll),
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main, using: releaseAll),
        ]
    }

    private func installMouseUpMonitor() {
        guard mouseUpMonitor == nil else { return }
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] event in
            guard let self else { return event }
            guard event.window === self.window else { return event }
            self.postMouseEvent(from: event, subtype: "UP")
            return event
        }
    }
    #endif

    private func applyFont(family: String, size: Double) {
        let font = ConsoleFont(name: family, size: CGFloat(size))
            ?? ConsoleFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
        terminalView.font = font
        applyScreenSize()
        refreshTerminalDisplay()
    }

    #if os(macOS)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(terminalView)
        updateMouseTrackingArea()
    }

    override func layout() {
        super.layout()
        applyScreenSize()
        updateMouseTrackingArea()
        updateScrollerVisibility()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateMouseTrackingArea()
    }

    override func mouseMoved(with event: NSEvent) {
        postMouseEvent(from: event, subtype: "MOVE")
        super.mouseMoved(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        postMouseEvent(from: event, subtype: "MOVE")
        super.mouseDragged(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        postMouseEvent(from: event, subtype: "DOWN")
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        postMouseEvent(from: event, subtype: "DOWN")
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        postMouseEvent(from: event, subtype: "DOWN")
        super.otherMouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        postMouseEvent(from: event, subtype: "UP")
        super.mouseUp(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        postMouseEvent(from: event, subtype: "UP")
        super.rightMouseUp(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        postMouseEvent(from: event, subtype: "UP")
        super.otherMouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        postMouseEvent(
            from: event,
            subtype: "SCROLL",
            deltaX: Double(event.scrollingDeltaX),
            deltaY: Double(event.scrollingDeltaY)
        )
        super.scrollWheel(with: event)
    }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            applyNativeColors()
            _ = terminalView.becomeFirstResponder()
        }
    }

    /// The colors the Mac's `configureNativeColors` sets, for this view's
    /// appearance. SwiftTerm's iOS view starts with a clear background, and
    /// its draw fills with it before each redraw, so a clear one erased
    /// nothing: rows that scrolled away stayed under the new ones. The
    /// terminal takes the colors resolved, so they are set again when the
    /// appearance changes.
    private func applyNativeColors() {
        terminalView.nativeForegroundColor = UIColor.label.resolvedColor(with: traitCollection)
        terminalView.nativeBackgroundColor = UIColor.systemBackground.resolvedColor(with: traitCollection)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyScreenSize()
        // Over what the terminal shows, clear of the notch and the home bar.
        touchControlsView.frame = terminalView.frame.intersection(bounds.inset(by: safeAreaInsets))
    }

    /// The program placed or took away on-screen controls: draw them, and
    /// keep the keyboard and its key bar out of the way while there are any —
    /// the program is played by touch, and they would take half the screen.
    /// SwiftTerm keeps the view first responder, so a hardware keyboard,
    /// INKEY$ and KEYDOWN still work; the keyboard comes back when the
    /// controls go.
    private func touchControlsChanged() {
        touchControlsView.setNeedsDisplay()
        terminalView.isSoftwareKeyboardHidden = model.map { !$0.touchControls.isEmpty } ?? false
    }

    /// Touch as the mouse, for VTG programs: a finger is the left button, and
    /// an iPad's pointer adds hovering, the secondary click and scrolling. A
    /// TUI program's mouse reporting is SwiftTerm's, from the same touches.
    private func installTouchMouse() {
        let touches = ConsoleTouchMouseRecognizer()
        touches.onTouch = { [weak self] phase, touch, event in
            self?.postTouch(phase, touch, event)
        }
        terminalView.addGestureRecognizer(touches)

        terminalView.addGestureRecognizer(
            UIHoverGestureRecognizer(target: self, action: #selector(pointerHovered(_:)))
        )

        // Scroll events only — a trackpad or wheel. A finger's pan stays
        // SwiftTerm's, and so does the scrolling itself, as on the Mac.
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(pointerScrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        scroll.cancelsTouchesInView = false
        scroll.delegate = self
        terminalView.addGestureRecognizer(scroll)
    }

    /// Where `location` (in this view) falls in the terminal's visible area.
    /// The terminal is a scroll view, so its own coordinates move with its
    /// scrollback; the canvas does not.
    private func terminalPoint(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x - terminalView.frame.minX, y: location.y - terminalView.frame.minY)
    }

    private func postTouch(_ phase: ConsoleTouchMouseRecognizer.Phase, _ touch: UITouch, _ event: UIEvent) {
        let location = touch.location(in: self)
        switch phase {
        case .down:
            touchMouseButton = event.buttonMask.contains(.secondary) ? 1 : 0
            postVTGMouseEvent(atTerminalPoint: terminalPoint(location), subtype: "DOWN",
                              button: touchMouseButton, buttons: 1 << touchMouseButton,
                              timestamp: touch.timestamp)
        case .move:
            // As on the Mac, a drag reports only while it is over the terminal.
            guard terminalView.frame.contains(location) else { return }
            postVTGMouseEvent(atTerminalPoint: terminalPoint(location), subtype: "MOVE",
                              button: touchMouseButton, buttons: 1 << touchMouseButton,
                              timestamp: touch.timestamp)
        case .up:
            // Always sent, clamped to the edge: a program must not be left
            // holding a button because the finger lifted outside.
            postVTGMouseEvent(atTerminalPoint: terminalPoint(location), subtype: "UP",
                              button: touchMouseButton, buttons: 0,
                              timestamp: touch.timestamp)
        }
    }

    @objc private func pointerHovered(_ hover: UIHoverGestureRecognizer) {
        guard hover.state == .began || hover.state == .changed else { return }
        let location = hover.location(in: self)
        guard terminalView.frame.contains(location) else { return }
        postVTGMouseEvent(atTerminalPoint: terminalPoint(location), subtype: "MOVE",
                          button: 0, buttons: 0,
                          timestamp: ProcessInfo.processInfo.systemUptime)
    }

    @objc private func pointerScrolled(_ scroll: UIPanGestureRecognizer) {
        guard scroll.state == .began || scroll.state == .changed else { return }
        let location = scroll.location(in: self)
        let delta = scroll.translation(in: terminalView)
        scroll.setTranslation(.zero, in: terminalView)
        guard terminalView.frame.contains(location), delta != .zero else { return }
        postVTGMouseEvent(atTerminalPoint: terminalPoint(location), subtype: "SCROLL",
                          button: 0, buttons: 0,
                          timestamp: ProcessInfo.processInfo.systemUptime,
                          deltaX: Double(delta.x), deltaY: Double(delta.y))
    }
    #endif

    /// Points this view at `model`: its input goes there, and the model's
    /// VTG drawing comes here. Safe to call on every update.
    func attach(to model: StudioModel) {
        self.model = model
        connectVTG(to: model)
        #if os(iOS)
        touchControlsView.attach(model.touchControls)
        model.touchControls.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.touchControlsChanged() }
        }
        // The keyboard button can put the keyboard away altogether; a tap on
        // the console brings it back, but not while touch controls are up,
        // where a tap is the program's.
        terminalView.showsHiddenKeyboardOnTap = { [weak model] in
            MainActor.assumeIsolated { model?.touchControls.isEmpty ?? true }
        }
        #endif
    }

    /// Draws `input`: only what changed since the last call.
    func render(_ input: ConsoleRenderInput) {
        render(
            consoleText: input.consoleText,
            trimmedCharacters: input.trimmedCharacters,
            scrollbackLines: input.scrollbackLines,
            screenSize: input.screenSize,
            fontFamily: input.fontFamily,
            fontSize: input.fontSize,
            graphicsLayersVisible: input.graphicsLayersVisible
        )
    }

    func render(
        consoleText: String,
        trimmedCharacters: Int,
        scrollbackLines: Int,
        screenSize: TerminalScreenSize,
        fontFamily: String,
        fontSize: Double,
        graphicsLayersVisible: Bool
    ) {
        if renderedScrollbackLines != scrollbackLines {
            terminalView.getTerminal().changeScrollback(scrollbackLines)
            renderedScrollbackLines = scrollbackLines
        }

        if renderedFontFamily != fontFamily || renderedFontSize != fontSize {
            applyFont(family: fontFamily, size: fontSize)
            renderedFontFamily = fontFamily
            renderedFontSize = fontSize
        }

        if renderedGraphicsLayersVisible != graphicsLayersVisible {
            terminalView.setGraphicsLayersVisible(graphicsLayersVisible)
            renderedGraphicsLayersVisible = graphicsLayersVisible
            invalidateVTGDisplay()
        }

        if renderedScreenSize != screenSize {
            renderedScreenSize = screenSize
            applyScreenSize()
        }

        // `trimmedCharacters` counts what scrollback trimming has dropped off the front of
        // the model's buffer, so this total keeps rising across a trim. Without it a trim
        // would look like the console shrank and force a full terminal reset and refeed.
        let emittedCharacterCount = trimmedCharacters + consoleText.count

        if emittedCharacterCount < renderedCharacterCount {
            terminalView.getTerminal().resetToInitialState()
            renderedCharacterCount = 0
            inputBuffer = ""
            inputCursor = 0
            completionMenu = nil
            hasInitializedLineInputDefault = false
        }

        if emittedCharacterCount > renderedCharacterCount {
            // Index from the end so the walk is proportional to what is new, not to the
            // whole buffer. Clamped in case a trim outran an update and dropped characters
            // this view had not fed yet.
            let pending = min(emittedCharacterCount - renderedCharacterCount, consoleText.count)
            let start = consoleText.index(consoleText.endIndex, offsetBy: -pending)
            let newText = String(consoleText[start...]).replacingOccurrences(of: "\n", with: "\r\n")
            feedTerminal(newText)
            renderedCharacterCount = emittedCharacterCount
        }
    }

    private func applyScreenSize() {
        let screenSize = renderedScreenSize ?? .flexible
        if let dimensions = screenSize.dimensions {
            terminalView.getTerminal().resize(cols: dimensions.cols, rows: dimensions.rows)
            model?.updateLiveTerminalSize(columns: dimensions.cols, rows: dimensions.rows)
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
            let canvas = terminalView.currentVTGCanvas()
            model?.updateLiveVTGCanvasSize(width: canvas.width, height: canvas.height)
            updateLiveVTGCellSize()
            postResizeEventIfNeeded(width: canvas.width, height: canvas.height)
            redisplay(terminalView)
            return
        }

        // Only a real size. ActiveUI lays the tree out once before it is in a
        // window, at a width and no height (168 × 0), and SwiftTerm refuses
        // only 0 × 0: sized from that, the terminal had 18 columns when the
        // first prompt arrived and wrapped it there, and a terminal does not
        // reflow what it has drawn. Until then it keeps setup's 80 × 25.
        guard bounds.width > 0, bounds.height > 0 else { return }
        terminalView.frame = bounds
        terminalView.sizeChanged(source: terminalView.getTerminal())
        let terminal = terminalView.getTerminal()
        model?.updateLiveTerminalSize(columns: terminal.cols, rows: terminal.rows)
        let canvas = terminalView.currentVTGCanvas()
        model?.updateLiveVTGCanvasSize(width: canvas.width, height: canvas.height)
        updateLiveVTGCellSize()
        postResizeEventIfNeeded(width: canvas.width, height: canvas.height)
        redisplay(terminalView)
    }

    private func feedTerminal(_ text: String) {
        terminalView.getTerminal().feed(text: text)
        refreshTerminalDisplay()
    }

    private func refreshTerminalDisplay() {
        let terminal = terminalView.getTerminal()
        terminal.refresh(startRow: 0, endRow: max(0, terminal.rows - 1))
        redisplay(terminalView)
        terminalView.setNeedsDisplay(terminalView.bounds)
        positionSwiftTermCaret()
        updateScrollerVisibility()
    }

    /// Shows the scroller only when there is scrollback to move through.
    ///
    /// SwiftTerm's is a bare `NSScroller`, and an overlay style hides itself
    /// only inside an `NSScrollView`, so on its own it is always drawn. It is
    /// private to SwiftTerm, hence finding it among the subviews.
    private func updateScrollerVisibility() {
        #if os(macOS)
        let isHidden = !terminalView.canScroll
        for case let scroller as NSScroller in terminalView.subviews where scroller.isHidden != isHidden {
            scroller.isHidden = isHidden
        }
        #endif
    }

    /// Marks `view` for drawing, in whichever framework draws it.
    private func redisplay(_ view: ConsoleBaseView) {
        #if os(macOS)
        view.needsDisplay = true
        #else
        view.setNeedsDisplay()
        #endif
    }

    private func positionSwiftTermCaret() {
        #if os(macOS)
        guard terminalView.frame.width > 0, terminalView.frame.height > 0 else { return }

        let terminal = terminalView.getTerminal()
        let optimalSize = terminalView.getOptimalFrameSize().size
        let cellWidth = min(terminalView.frame.width, optimalSize.width) / CGFloat(max(terminal.cols, 1))
        let cellHeight = min(terminalView.frame.height, optimalSize.height) / CGFloat(max(terminal.rows, 1))
        let x = CGFloat(min(max(terminal.buffer.x, 0), max(terminal.cols - 1, 0))) * cellWidth
        let y = terminalView.frame.height - (CGFloat(min(max(terminal.buffer.y, 0), max(terminal.rows - 1, 0))) + 1) * cellHeight

        for subview in terminalView.subviews where String(describing: type(of: subview)).contains("CaretView") {
            subview.frame.origin = CGPoint(x: x, y: y)
        }
        #endif
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        model?.updateLiveTerminalSize(columns: newCols, rows: newRows)
        let canvas = terminalView.currentVTGCanvas()
        model?.updateLiveVTGCanvasSize(width: canvas.width, height: canvas.height)
        updateLiveVTGCellSize()
        terminalView.notifyVTGResizeIfNeeded()
        postResizeEventIfNeeded(width: canvas.width, height: canvas.height)
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func connectVTG(to model: StudioModel) {
        model.vtgDataSink = { [weak self] data in
            Task { @MainActor [weak self] in
                self?.feedVTG(data)
            }
        }
    }

    private func feedVTG(_ data: Data) {
        terminalView.feedVTG(data)
        updateLiveVTGCellSize()
        invalidateVTGDisplay()
    }

    private func invalidateVTGDisplay() {
        guard !isVTGDisplayInvalidationScheduled else { return }
        isVTGDisplayInvalidationScheduled = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isVTGDisplayInvalidationScheduled = false

            self.redisplay(self.terminalView.vtgOverlayView)
            self.terminalView.vtgOverlayView.setNeedsDisplay(self.terminalView.vtgOverlayView.bounds)

            self.redisplay(self.terminalView)
            self.terminalView.setNeedsDisplay(self.terminalView.bounds)

            self.redisplay(self)
            self.setNeedsDisplay(self.bounds)
        }
    }

    private func updateLiveVTGCellSize() {
        guard let cellSize = terminalView.currentVTGCellSize() else { return }
        model?.updateLiveVTGCellSize(width: cellSize.width, height: cellSize.height)
    }

    #if os(macOS)
    private func updateMouseTrackingArea() {
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }
        let area = NSTrackingArea(
            rect: terminalView.frame,
            options: [.activeInKeyWindow, .mouseMoved, .enabledDuringMouseDrag, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        mouseTrackingArea = area
        addTrackingArea(area)
    }
    #endif

    private func postResizeEventIfNeeded(width: Int, height: Int) {
        let normalized = (width: max(1, width), height: max(1, height))
        guard lastPostedVTGCanvasSize?.width != normalized.width
            || lastPostedVTGCanvasSize?.height != normalized.height
        else {
            return
        }
        lastPostedVTGCanvasSize = normalized
        model?.postVTGResizeEvent(width: normalized.width, height: normalized.height)
    }

    /// Posts one mouse event to a VTG program. `point` is in the terminal
    /// view's visible area, from its top-left corner; the program gets it in
    /// its canvas. The Mac's mouse and iOS's touches and pointer both come
    /// here.
    private func postVTGMouseEvent(
        atTerminalPoint point: CGPoint,
        subtype: String,
        button: Int,
        buttons: Int,
        timestamp: TimeInterval,
        deltaX: Double = 0,
        deltaY: Double = 0
    ) {
        let width = terminalView.bounds.width
        let height = terminalView.bounds.height
        guard width > 0, height > 0 else { return }
        if subtype == "MOVE" {
            let previousMove = lastMouseMovePostTimestamp ?? 0
            guard timestamp - previousMove >= 1.0 / 30.0 else { return }
            lastMouseMovePostTimestamp = timestamp
        }

        let canvas = terminalView.currentVTGCanvas()
        let canvasWidth = max(1, canvas.width)
        let canvasHeight = max(1, canvas.height)
        let x = min(max(Double(point.x / width) * Double(canvasWidth), 0), Double(canvasWidth))
        let y = min(max(Double(point.y / height) * Double(canvasHeight), 0), Double(canvasHeight))
        let previousTimestamp = lastMouseEventTimestamp ?? timestamp
        lastMouseEventTimestamp = timestamp
        let hit = model?.hitRegion(atX: x, y: y)
        model?.postVTGMouseEvent(
            subtype: subtype,
            x: x,
            y: y,
            button: button,
            buttons: buttons,
            duration: max(0, timestamp - previousTimestamp),
            deltaX: deltaX,
            deltaY: deltaY,
            hitID: hit?.id ?? "",
            target: hit?.target ?? ""
        )
    }

    #if os(macOS)
    private func postMouseEvent(
        from event: NSEvent,
        subtype: String,
        deltaX: Double = 0,
        deltaY: Double = 0
    ) {
        let pointInSelf = convert(event.locationInWindow, from: nil)
        guard terminalView.frame.contains(pointInSelf) else { return }

        // AppKit counts up from the bottom; a VTG canvas counts down from the top.
        let point = terminalView.convert(pointInSelf, from: self)
        postVTGMouseEvent(
            atTerminalPoint: CGPoint(x: point.x, y: terminalView.bounds.height - point.y),
            subtype: subtype,
            button: max(0, event.buttonNumber),
            buttons: Int(NSEvent.pressedMouseButtons),
            timestamp: event.timestamp,
            deltaX: deltaX,
            deltaY: deltaY
        )
    }

    private func handleProgramKeyEvent(_ event: NSEvent) -> Bool {
        handleProgramKey(Self.consoleKeyPress(from: event))
    }

    private static func consoleKeyPress(from event: NSEvent) -> ConsoleKeyPress {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: ConsoleKeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        let characters = event.charactersIgnoringModifiers ?? ""
        return ConsoleKeyPress(
            special: characters.unicodeScalars.first.flatMap { consoleSpecialKey(for: Int($0.value)) },
            charactersIgnoringModifiers: characters,
            modifiers: modifiers
        )
    }

    private static func consoleSpecialKey(for key: Int) -> ConsoleSpecialKey? {
        switch key {
        case 10, 13, NSCarriageReturnCharacter, NSEnterCharacter: return .returnKey
        case NSUpArrowFunctionKey: return .up
        case NSDownArrowFunctionKey: return .down
        case NSRightArrowFunctionKey: return .right
        case NSLeftArrowFunctionKey: return .left
        case NSHomeFunctionKey: return .home
        case NSEndFunctionKey: return .end
        case NSInsertFunctionKey: return .insert
        case NSDeleteFunctionKey: return .forwardDelete
        case NSPageUpFunctionKey: return .pageUp
        case NSPageDownFunctionKey: return .pageDown
        case NSF1FunctionKey...NSF35FunctionKey: return .function(key - NSF1FunctionKey + 1)
        default: return nil
        }
    }
    #endif

    /// A hardware key press, before SwiftTerm sees it: the Mac's key monitor
    /// and the iOS terminal view's presses both come here. Returns whether the
    /// console took the key; one it leaves goes on to SwiftTerm as usual.
    private func handleProgramKey(_ press: ConsoleKeyPress) -> Bool {
        // A TUI application has every key, ^C included, as it does in
        // BASICShell. SwiftTerm turns the key into the bytes a terminal
        // sends, and `send` hands them to the driver.
        if model?.activeTUIDriver != nil {
            return false
        }

        if press.isInterrupt, model?.shouldProgramStopOnTerminalInterrupt() == true {
            model?.stopProgram()
            return true
        }

        if press.isOverwriteToggle, model?.shouldCaptureTerminalKeyOnly() != true {
            _ = model?.toggleConsoleOverwriteModeFromTerminal()
            return true
        }

        let shouldCaptureProgramKey = model?.shouldCaptureTerminalKeyOnly() == true
        let shouldExitLineInput = model?.shouldExitLineInputOnSpecialKey() == true
        guard shouldCaptureProgramKey || shouldExitLineInput,
              let rawKey = press.rawSequence
        else {
            return false
        }

        var operations: [TerminalInputOperation] = []
        appendRawSpecialKeySequence(rawKey, operations: &operations)
        guard !operations.isEmpty else { return true }
        Task { @MainActor [weak model] in
            model?.handleTerminalInput(operations)
        }
        return true
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let driver = model?.activeTUIDriver {
            driver.incoming.yield(.bytes(Array(data)))
            return
        }

        var operations: [TerminalInputOperation] = []
        var bytes = Array(data)
        if !pendingEscapeBytes.isEmpty {
            bytes = pendingEscapeBytes + bytes
            pendingEscapeBytes = []
            pendingEscapeFlushID += 1
        }
        var iterator = bytes.makeIterator()
        var previousByteWasCarriageReturn = false

        while let byte = iterator.next() {
            if byte == 10 && previousByteWasCarriageReturn {
                previousByteWasCarriageReturn = false
                continue
            }
            previousByteWasCarriageReturn = byte == 13

            switch byte {
            case 10, 13:
                if acceptCompletionSelection(operations: &operations) {
                    continue
                }
                clearCompletionMenu()
                if model?.shouldCaptureTerminalKeyOnly() == true {
                    operations.append(.key("\n"))
                } else {
                    ensureLineInputDefaultInitialized()
                    let command = inputBuffer
                    if usesCommandHistory {
                        appendCommandHistory(command)
                    }
                    inputBuffer = ""
                    inputCursor = 0
                    commandHistoryIndex = nil
                    draftBeforeCommandHistory = ""
                    resetInputFieldState()
                    hasInitializedLineInputDefault = false
                    operations.append(.submit(command))
                }
            case 9:
                if model?.shouldCaptureTerminalKeyOnly() == true || model?.shouldExitLineInputOnSpecialKey() == true {
                    clearCompletionMenu()
                    appendRawSpecialKeySequence("\t", operations: &operations)
                } else {
                    completeLine(operations: &operations)
                }
            case 8, 127:
                clearCompletionMenu()
                if model?.shouldCaptureTerminalKeyOnly() == true {
                    operations.append(.key(BASICRawKey.backspace))
                } else {
                    backspace(in: &operations)
                }
            case 1...31:
                if byte == 3, model?.shouldProgramStopOnTerminalInterrupt() == true {
                    model?.stopProgram()
                } else if model?.shouldCaptureTerminalKeyOnly() == true {
                    operations.append(.key(String(UnicodeScalar(byte))))
                } else {
                    clearCompletionMenu()
                }
            case 32...126:
                clearCompletionMenu()
                if byte == UInt8(ascii: "["),
                   let compactRead = readCompactBracketSequence(from: &iterator) {
                    if let compactSequence = compactRead.sequence {
                        handleEditingEscape("\u{1B}" + compactSequence, operations: &operations)
                    } else {
                        for fallbackByte in compactRead.fallback {
                            appendPrintableByte(fallbackByte, operations: &operations)
                        }
                    }
                } else {
                    appendPrintableByte(byte, operations: &operations)
                }
            case 27:
                clearCompletionMenu()
                var bytes = [byte]
                while let next = iterator.next() {
                    bytes.append(next)
                    if isCompleteEscapeSequence(bytes) { break }
                }
                if !isCompleteEscapeSequence(bytes), bytes.count < 8 {
                    pendingEscapeBytes = bytes
                    schedulePendingEscapeFlush()
                } else {
                    handleEscapeBytes(bytes, operations: &operations)
                }
            default:
                break
            }
        }

        guard !operations.isEmpty else { return }
        Task { @MainActor [weak model] in
            model?.handleTerminalInput(operations)
        }
    }

    private func appendPrintableByte(_ byte: UInt8, operations: inout [TerminalInputOperation]) {
        let scalar = UnicodeScalar(byte)
        let character = String(Character(scalar))
        if model?.shouldCaptureTerminalKeyOnly() == true {
            operations.append(.key(character))
        } else {
            appendText(character, to: &operations)
        }
    }

    private func readCompactBracketSequence(from iterator: inout Array<UInt8>.Iterator) -> (sequence: String?, fallback: [UInt8])? {
        guard let next = iterator.next() else { return nil }
        switch next {
        case UInt8(ascii: "A"), UInt8(ascii: "B"), UInt8(ascii: "C"), UInt8(ascii: "D"),
             UInt8(ascii: "F"), UInt8(ascii: "H"), UInt8(ascii: "Z"):
            return ("[" + String(Character(UnicodeScalar(next))), [])
        default:
            return (nil, [UInt8(ascii: "["), next])
        }
    }

    private func schedulePendingEscapeFlush() {
        pendingEscapeFlushID += 1
        let flushID = pendingEscapeFlushID
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self,
                  self.pendingEscapeFlushID == flushID,
                  !self.pendingEscapeBytes.isEmpty
            else {
                return
            }

            let bytes = self.pendingEscapeBytes
            self.pendingEscapeBytes = []
            var operations: [TerminalInputOperation] = []
            self.handleEscapeBytes(bytes, operations: &operations)
            guard !operations.isEmpty else { return }
            self.model?.handleTerminalInput(operations)
        }
    }

    private func handleEscapeBytes(_ bytes: [UInt8], operations: inout [TerminalInputOperation]) {
        let raw = String(bytes: bytes, encoding: .utf8) ?? "\u{1B}"
        appendRawSpecialKeySequence(raw, operations: &operations)
    }

    private func appendRawSpecialKeySequence(_ raw: String, operations: inout [TerminalInputOperation]) {
        if model?.shouldCaptureTerminalKeyOnly() == true {
            operations.append(.key(raw))
        } else if model?.shouldExitLineInputOnSpecialKey() == true {
            finishLineInput(exitKey: BASICKeyNormalizer.normalize(raw), operations: &operations)
        } else {
            handleEditingEscape(raw, operations: &operations)
        }
    }

    private func finishLineInput(exitKey: String, operations: inout [TerminalInputOperation]) {
        ensureLineInputDefaultInitialized()
        let command = inputBuffer
        inputBuffer = ""
        inputCursor = 0
        resetInputFieldState()
        hasInitializedLineInputDefault = false
        operations.append(.lineInputExit(command, exitKey))
    }

    private func appendText(_ text: String, to operations: inout [TerminalInputOperation]) {
        guard !text.isEmpty else { return }
        ensureLineInputDefaultInitialized()
        commandHistoryIndex = nil
        let textCount = text.count
        let options = model?.activeLineInputOptions() ?? BASICLineInputOptions()
        let replacedCount = model?.isConsoleOverwriteMode == true && inputCursor < inputBuffer.count ? min(textCount, inputBuffer.count - inputCursor) : 0
        if let maxLength = options.maxLength, inputBuffer.count - replacedCount + textCount > maxLength {
            return
        }
        if model?.isConsoleOverwriteMode == true, inputCursor < inputBuffer.count {
            inputBuffer.removeSubrange(range(offset: inputCursor, length: min(textCount, inputBuffer.count - inputCursor)))
        }
        inputBuffer.insert(contentsOf: text, at: inputBuffer.index(inputBuffer.startIndex, offsetBy: inputCursor))
        let targetCursor = inputCursor + textCount
        operations.append(.append(redrawInputFromCursor(targetCursor: targetCursor)))
        inputCursor = targetCursor
    }

    private func backspace(in operations: inout [TerminalInputOperation]) {
        ensureLineInputDefaultInitialized()
        commandHistoryIndex = nil
        guard inputCursor > 0 else { return }
        inputCursor -= 1
        inputBuffer.removeSubrange(range(offset: inputCursor, length: 1))
        if model?.activeLineInputOptions().fieldLength != nil {
            operations.append(.append(redrawInputFromCursor(targetCursor: inputCursor)))
        } else {
            operations.append(.append("\u{1B}[D" + redrawInputFromCursor(targetCursor: inputCursor)))
        }
    }

    private func deleteForward(in operations: inout [TerminalInputOperation]) {
        ensureLineInputDefaultInitialized()
        commandHistoryIndex = nil
        guard inputCursor < inputBuffer.count else { return }
        inputBuffer.removeSubrange(range(offset: inputCursor, length: 1))
        operations.append(.append(redrawInputFromCursor(targetCursor: inputCursor)))
    }

    private func moveInputCursor(to newCursor: Int, operations: inout [TerminalInputOperation]) {
        ensureLineInputDefaultInitialized()
        let clamped = min(max(newCursor, 0), inputBuffer.count)
        guard clamped != inputCursor else { return }
        if model?.activeLineInputOptions().fieldLength != nil {
            inputCursor = clamped
            operations.append(.append(redrawInputFromCursor(targetCursor: inputCursor)))
            return
        }
        let delta = clamped - inputCursor
        inputCursor = clamped
        if delta > 0 {
            operations.append(.append(String(repeating: "\u{1B}[C", count: delta)))
        } else {
            operations.append(.append(String(repeating: "\u{1B}[D", count: -delta)))
        }
    }

    private struct CompletionMenu {
        let candidates: [String]
        let context: BASICCompletionContext
        var selectedIndex: Int?
        var displayLineCount = 0
    }

    private func completeLine(operations: inout [TerminalInputOperation]) {
        guard model?.activeLineInputOptions().fieldLength == nil else { return }
        ensureLineInputDefaultInitialized()

        if var menu = completionMenu {
            guard menu.context == BASICCompletionEngine.context(buffer: inputBuffer, cursor: inputCursor) else {
                clearCompletionMenu()
                return
            }
            if let selectedIndex = menu.selectedIndex {
                menu.selectedIndex = (selectedIndex + 1) % menu.candidates.count
            } else {
                menu.selectedIndex = 0
            }
            renderCompletionMenu(&menu)
            completionMenu = menu
            return
        }

        let context = BASICCompletionEngine.context(buffer: inputBuffer, cursor: inputCursor)
        let candidates = completionCandidates(for: context)
        guard !candidates.isEmpty else {
            feedTerminal("\u{07}")
            return
        }

        if candidates.count == 1 {
            replaceCompletionToken(with: candidates[0], context: context, operations: &operations)
            return
        }

        let common = BASICCompletionEngine.commonPrefix(candidates)
        if common.count > context.token.count {
            replaceCompletionToken(with: common, context: context, operations: &operations)
            return
        }

        var menu = CompletionMenu(candidates: candidates, context: context)
        renderCompletionMenu(&menu)
        completionMenu = menu
    }

    private func completionCandidates(for context: BASICCompletionContext) -> [String] {
        var commandWords = BASICCompletionEngine.shellBuiltinWords
            + BASICCompletionEngine.basicKeywordWords
            + (model?.consoleCompletionAliasWords() ?? [])
        if model?.consoleCompletionIncludesExternalCommands() == true {
            commandWords += pathExecutableCompletionWords()
        }
        return BASICCompletionEngine.candidates(
            for: context,
            pathCandidates: pathCompletionCandidates(for: context.token),
            commandWords: commandWords,
            symbolWords: model?.consoleCompletionSymbolWords() ?? []
        )
    }

    private func pathCompletionCandidates(for token: String) -> [String] {
        let split = splitPathCompletionToken(token)
        let directoryPath = expandedPath(split.directory)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directoryPath) else { return [] }

        let visibleDirectory = split.directory
        return entries
            .filter { BASICCompletionEngine.caseInsensitiveHasPrefix($0, prefix: split.partial) }
            .map { entry in
                let fullPath = URL(fileURLWithPath: directoryPath).appendingPathComponent(entry).path
                let suffix = FileManager.default.fileExists(atPath: fullPath, isDirectory: nil) && isDirectory(fullPath) ? "/" : ""
                return visibleDirectory + escapedCompletionPathComponent(entry) + suffix
            }
    }

    private func splitPathCompletionToken(_ token: String) -> (directory: String, partial: String) {
        if let slash = token.lastIndex(of: "/") {
            let directory = String(token[...slash])
            let partial = String(token[token.index(after: slash)...])
            return (directory, partial)
        }
        return ("", token)
    }

    private func expandedPath(_ visibleDirectory: String) -> String {
        if visibleDirectory.isEmpty {
            return model?.consoleCompletionWorkingDirectoryPath() ?? FileManager.default.currentDirectoryPath
        }
        if visibleDirectory == "~/" {
            return StudioHome.url.path
        }
        if visibleDirectory.hasPrefix("~/") {
            let rest = visibleDirectory.dropFirst(2)
            return StudioHome.url.appendingPathComponent(String(rest)).path
        }
        if visibleDirectory.hasPrefix("/") {
            return NSString(string: visibleDirectory).expandingTildeInPath
        }
        let base = URL(
            fileURLWithPath: model?.consoleCompletionWorkingDirectoryPath() ?? FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        return URL(fileURLWithPath: visibleDirectory, relativeTo: base).standardizedFileURL.path
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func escapedCompletionPathComponent(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "\\ ")
    }

    private func pathExecutableCompletionWords() -> [String] {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var words: [String] = []
        var seen = Set<String>()
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: String(directory)) else { continue }
            for entry in entries where seen.insert(entry).inserted {
                let fullPath = URL(fileURLWithPath: String(directory)).appendingPathComponent(entry).path
                guard access(fullPath, X_OK) == 0, !isDirectory(fullPath) else { continue }
                words.append(entry)
            }
        }
        return words
    }

    private func replaceCompletionToken(
        with replacement: String,
        context: BASICCompletionContext,
        operations: inout [TerminalInputOperation]
    ) {
        let oldCursor = inputCursor
        let tokenRange = range(offset: context.startOffset, length: inputCursor - context.startOffset)
        inputBuffer.replaceSubrange(tokenRange, with: replacement)
        inputCursor = context.startOffset + replacement.count

        let redrawStart = min(context.startOffset, oldCursor)
        let moveToRedrawStart = terminalCursorMovement(from: oldCursor, to: redrawStart)
        let suffix = String(inputBuffer.dropFirst(redrawStart))
        let backtrack = max(0, inputBuffer.count - inputCursor)
        operations.append(.append(moveToRedrawStart + "\u{1B}[K" + suffix + String(repeating: "\u{1B}[D", count: backtrack)))
    }

    private func acceptCompletionSelection(operations: inout [TerminalInputOperation]) -> Bool {
        guard let menu = completionMenu, let selectedIndex = menu.selectedIndex else {
            return false
        }
        clearCompletionMenu()
        replaceCompletionToken(with: menu.candidates[selectedIndex], context: menu.context, operations: &operations)
        return true
    }

    private func clearCompletionMenu() {
        guard let menu = completionMenu, menu.displayLineCount > 0 else {
            completionMenu = nil
            return
        }
        let output = "\u{1B}[s"
            + terminalCursorMovement(from: inputCursor, to: inputBuffer.count)
            + String(repeating: "\r\n\u{1B}[2K", count: menu.displayLineCount)
            + "\u{1B}[u"
        feedTerminal(output)
        completionMenu = nil
    }

    private func renderCompletionMenu(_ menu: inout CompletionMenu) {
        var oldMenu = completionMenu
        clearCompletionMenu(&oldMenu)

        let lines = completionMenuLines(candidates: menu.candidates, selectedIndex: menu.selectedIndex)
        guard !lines.isEmpty else { return }

        let output = "\u{1B}[s"
            + terminalCursorMovement(from: inputCursor, to: inputBuffer.count)
            + lines.map { "\r\n\u{1B}[2K" + $0 }.joined()
            + "\u{1B}[u"
        feedTerminal(output)
        menu.displayLineCount = lines.count
    }

    private func clearCompletionMenu(_ menu: inout CompletionMenu?) {
        guard let existing = menu, existing.displayLineCount > 0 else {
            menu = nil
            return
        }
        let output = "\u{1B}[s"
            + terminalCursorMovement(from: inputCursor, to: inputBuffer.count)
            + String(repeating: "\r\n\u{1B}[2K", count: existing.displayLineCount)
            + "\u{1B}[u"
        feedTerminal(output)
        menu = nil
    }

    private func completionMenuLines(candidates: [String], selectedIndex: Int?) -> [String] {
        let columns = max(1, terminalView.getTerminal().cols)
        let cellWidth = min(max((candidates.map(\.count).max() ?? 0) + 2, 8), columns)
        let columnCount = max(1, columns / cellWidth)
        var lines: [String] = []
        var line = ""
        for (index, candidate) in candidates.enumerated() {
            let padded = candidate.padding(toLength: cellWidth, withPad: " ", startingAt: 0)
            let rendered = index == selectedIndex ? "\u{1B}[30;42m" + padded + "\u{1B}[39;49m" : padded
            line += rendered
            if (index + 1).isMultiple(of: columnCount) {
                lines.append(line)
                line = ""
            }
        }
        if !line.isEmpty {
            lines.append(line)
        }
        return lines
    }

    private func terminalCursorMovement(from oldCursor: Int, to newCursor: Int) -> String {
        let delta = newCursor - oldCursor
        if delta > 0 {
            return String(repeating: "\u{1B}[C", count: delta)
        }
        if delta < 0 {
            return String(repeating: "\u{1B}[D", count: -delta)
        }
        return ""
    }

    private func handleEditingEscape(_ raw: String, operations: inout [TerminalInputOperation]) {
        let key = BASICKeyNormalizer.normalize(raw)
        switch key {
        case "[H":
            guard usesCommandHistory else { break }
            showPreviousCommand(operations: &operations)
        case "[P":
            guard usesCommandHistory else { break }
            showNextCommand(operations: &operations)
        case "[K": moveInputCursor(to: inputCursor - 1, operations: &operations)
        case "[M": moveInputCursor(to: inputCursor + 1, operations: &operations)
        case "[G": moveInputCursor(to: 0, operations: &operations)
        case "[O": moveInputCursor(to: inputBuffer.count, operations: &operations)
        case "[S": deleteForward(in: &operations)
        case "[R": _ = model?.toggleConsoleOverwriteModeFromTerminal()
        default: break
        }
    }

    private var usesCommandHistory: Bool {
        guard model?.shouldUseTerminalCommandHistory() == true else { return false }
        let options = model?.activeLineInputOptions() ?? BASICLineInputOptions()
        return options.fieldLength == nil
            && options.maxLength == nil
            && options.defaultText == nil
    }

    private func showPreviousCommand(operations: inout [TerminalInputOperation]) {
        guard !commandHistory.isEmpty else { return }
        if let index = commandHistoryIndex {
            commandHistoryIndex = max(0, index - 1)
        } else {
            draftBeforeCommandHistory = inputBuffer
            commandHistoryIndex = commandHistory.count - 1
        }
        guard let index = commandHistoryIndex else { return }
        replaceInputLine(with: commandHistory[index], operations: &operations)
    }

    private func showNextCommand(operations: inout [TerminalInputOperation]) {
        guard let index = commandHistoryIndex else { return }
        if index < commandHistory.count - 1 {
            commandHistoryIndex = index + 1
            replaceInputLine(with: commandHistory[index + 1], operations: &operations)
        } else {
            commandHistoryIndex = nil
            replaceInputLine(with: draftBeforeCommandHistory, operations: &operations)
        }
    }

    private func replaceInputLine(with text: String, operations: inout [TerminalInputOperation]) {
        let moveToStart = String(repeating: "\u{1B}[D", count: inputCursor)
        inputBuffer = text
        inputCursor = inputBuffer.count
        operations.append(.append(moveToStart + "\u{1B}[K" + inputBuffer))
    }

    private func appendCommandHistory(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if commandHistory.last == command { return }
        commandHistory.append(command)
        if commandHistory.count > Self.maxCommandHistoryEntries {
            commandHistory.removeFirst(commandHistory.count - Self.maxCommandHistoryEntries)
        }
        saveCommandHistory()
    }

    private static let maxCommandHistoryEntries = 500
    private static let commandHistoryURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? StudioHome.url.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AIBasic", isDirectory: true).appendingPathComponent("BASICShellHistory.txt")
    }()

    private static func loadCommandHistory() -> [String] {
        guard let contents = try? String(contentsOf: commandHistoryURL, encoding: .utf8) else {
            return []
        }
        return contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(maxCommandHistoryEntries)
            .map(String.init)
    }

    private func saveCommandHistory() {
        let directory = Self.commandHistoryURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try commandHistory.joined(separator: "\n").write(to: Self.commandHistoryURL, atomically: true, encoding: .utf8)
        } catch {
            // History is a convenience feature; keep Studio input usable if persistence fails.
        }
    }

    private func redrawInputFromCursor(targetCursor: Int) -> String {
        if let fieldLength = model?.activeLineInputOptions().fieldLength {
            ensureInputFieldViewContains(cursor: targetCursor, fieldLength: fieldLength)
            let visible = visibleInputField(fieldLength: fieldLength)
            let displayCursor = targetCursor - inputFieldViewStart
            let output = String(repeating: "\u{1B}[D", count: inputFieldDisplayCursor)
                + visible
                + String(repeating: "\u{1B}[D", count: max(0, fieldLength - displayCursor))
            inputFieldDisplayCursor = displayCursor
            return output
        }
        let suffix = String(inputBuffer.dropFirst(inputCursor))
        let backtrack = max(0, inputBuffer.count - targetCursor)
        return "\u{1B}[K" + suffix + String(repeating: "\u{1B}[D", count: backtrack)
    }

    private func resetInputFieldState() {
        inputFieldViewStart = 0
        inputFieldDisplayCursor = 0
    }

    private func ensureLineInputDefaultInitialized() {
        guard !hasInitializedLineInputDefault,
              let options = model?.activeLineInputOptions(),
              let defaultText = options.defaultText
        else { return }

        let limited = options.maxLength.map { String(defaultText.prefix($0)) } ?? defaultText
        inputBuffer = limited
        inputCursor = inputBuffer.count
        if let fieldLength = options.fieldLength {
            ensureInputFieldViewContains(cursor: inputCursor, fieldLength: fieldLength)
            inputFieldDisplayCursor = inputCursor - inputFieldViewStart
        }
        hasInitializedLineInputDefault = true
    }

    private func ensureInputFieldViewContains(cursor: Int, fieldLength: Int) {
        if cursor < inputFieldViewStart {
            inputFieldViewStart = cursor
        } else if cursor > inputFieldViewStart + fieldLength {
            inputFieldViewStart = cursor - fieldLength
        }
    }

    private func visibleInputField(fieldLength: Int) -> String {
        let visible = String(inputBuffer.dropFirst(inputFieldViewStart).prefix(fieldLength))
        return visible + String(repeating: " ", count: max(0, fieldLength - visible.count))
    }

    private func range(offset: Int, length: Int) -> Range<String.Index> {
        let start = inputBuffer.index(inputBuffer.startIndex, offsetBy: offset)
        let end = inputBuffer.index(start, offsetBy: length)
        return start..<end
    }
    func scrolled(source: TerminalView, position: Double) {}
    #if !os(macOS)
    /// SwiftTerm defaults this on the Mac and not on iOS. Links open nothing
    /// here: `linkReporting` is off.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    #endif
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}

    private func isCompleteEscapeSequence(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        if bytes[1] == UInt8(ascii: "O") {
            return bytes.count >= 3
        }
        if bytes[1] == UInt8(ascii: "[") {
            guard let last = bytes.last else { return false }
            if (65...90).contains(last) || (97...122).contains(last) || last == UInt8(ascii: "~") {
                return true
            }
        }
        return bytes.count >= 8
    }
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

#if os(iOS)
extension AIBasicTerminalContainerView: UIGestureRecognizerDelegate {
    /// The pointer-scroll recognizer reports alongside SwiftTerm's own
    /// scrolling rather than instead of it.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
#endif
