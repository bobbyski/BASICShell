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

struct SwiftTermGraphicsConsole: NSViewRepresentable {
    @ObservedObject var model: StudioModel

    func makeNSView(context: Context) -> AIBasicTerminalContainerView {
        let view = AIBasicTerminalContainerView()
        view.model = model
        view.connectVTG(to: model)
        return view
    }

    func updateNSView(_ nsView: AIBasicTerminalContainerView, context: Context) {
        nsView.model = model
        nsView.connectVTG(to: model)
        nsView.render(
            consoleText: model.consoleText,
            screenSize: model.terminalScreenSize,
            fontFamily: model.fontFamily,
            fontSize: model.fontSize,
            graphicsLayersVisible: model.areGraphicsLayersVisible
        )
    }
}

@MainActor
final class AIBasicTerminalContainerView: NSView, @preconcurrency TerminalViewDelegate {
    weak var model: StudioModel?

    private let terminalView = VectorTerminalView(frame: .zero, font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
    private var renderedCharacterCount = 0
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
    private var keyMonitor: Any?
    private var mouseUpMonitor: Any?
    private var pendingEscapeBytes: [UInt8] = []
    private var pendingEscapeFlushID = 0
    private var mouseTrackingArea: NSTrackingArea?
    private var lastMouseEventTimestamp: TimeInterval?
    private var lastMouseMovePostTimestamp: TimeInterval?
    private var lastPostedVTGCanvasSize: (width: Int, height: Int)?

    deinit {
        MainActor.assumeIsolated {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
        }
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }
        }
    }

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
        installKeyMonitor()
        installMouseUpMonitor()

        addSubview(terminalView)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.window === self.window else { return event }
            guard self.handleProgramKeyEvent(event) else { return event }
            return nil
        }
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

    private func applyFont(family: String, size: Double) {
        let font = NSFont(name: family, size: CGFloat(size))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
        terminalView.font = font
        applyScreenSize(force: true)
        refreshTerminalDisplay()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(terminalView)
        updateMouseTrackingArea()
    }

    override func layout() {
        super.layout()
        applyScreenSize(force: false)
        updateMouseTrackingArea()
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

    func render(
        consoleText: String,
        screenSize: TerminalScreenSize,
        fontFamily: String,
        fontSize: Double,
        graphicsLayersVisible: Bool
    ) {
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
            applyScreenSize(force: true)
        }

        if consoleText.count < renderedCharacterCount {
            terminalView.getTerminal().resetToInitialState()
            renderedCharacterCount = 0
            inputBuffer = ""
            inputCursor = 0
            hasInitializedLineInputDefault = false
        }

        if consoleText.count > renderedCharacterCount {
            let start = consoleText.index(consoleText.startIndex, offsetBy: renderedCharacterCount)
            let newText = String(consoleText[start...]).replacingOccurrences(of: "\n", with: "\r\n")
            feedTerminal(newText)
            renderedCharacterCount = consoleText.count
        }
    }

    private func applyScreenSize(force: Bool) {
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
            postResizeEventIfNeeded(width: canvas.width, height: canvas.height)
            terminalView.needsDisplay = true
            return
        }

        guard force || bounds.width > 0 else { return }
        terminalView.frame = bounds
        terminalView.sizeChanged(source: terminalView.getTerminal())
        let terminal = terminalView.getTerminal()
        model?.updateLiveTerminalSize(columns: terminal.cols, rows: terminal.rows)
        let canvas = terminalView.currentVTGCanvas()
        model?.updateLiveVTGCanvasSize(width: canvas.width, height: canvas.height)
        postResizeEventIfNeeded(width: canvas.width, height: canvas.height)
        terminalView.needsDisplay = true
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
        let optimalSize = terminalView.getOptimalFrameSize().size
        let cellWidth = min(terminalView.frame.width, optimalSize.width) / CGFloat(max(terminal.cols, 1))
        let cellHeight = min(terminalView.frame.height, optimalSize.height) / CGFloat(max(terminal.rows, 1))
        let x = CGFloat(min(max(terminal.buffer.x, 0), max(terminal.cols - 1, 0))) * cellWidth
        let y = terminalView.frame.height - (CGFloat(min(max(terminal.buffer.y, 0), max(terminal.rows - 1, 0))) + 1) * cellHeight

        for subview in terminalView.subviews where String(describing: type(of: subview)).contains("CaretView") {
            subview.frame.origin = CGPoint(x: x, y: y)
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        model?.updateLiveTerminalSize(columns: newCols, rows: newRows)
        let canvas = terminalView.currentVTGCanvas()
        model?.updateLiveVTGCanvasSize(width: canvas.width, height: canvas.height)
        terminalView.notifyVTGResizeIfNeeded()
        postResizeEventIfNeeded(width: canvas.width, height: canvas.height)
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func connectVTG(to model: StudioModel) {
        model.vtgDataSink = { [weak self] data in
            self?.feedVTG(data)
        }
    }

    private func feedVTG(_ data: Data) {
        terminalView.feedVTG(data)
        invalidateVTGDisplay()
    }

    private func invalidateVTGDisplay() {
        terminalView.vtgOverlayView.needsDisplay = true
        terminalView.vtgOverlayView.setNeedsDisplay(terminalView.vtgOverlayView.bounds)

        terminalView.needsDisplay = true
        terminalView.setNeedsDisplay(terminalView.bounds)

        needsDisplay = true
        setNeedsDisplay(bounds)

        terminalView.vtgOverlayView.displayIfNeeded()
        terminalView.displayIfNeeded()
        displayIfNeeded()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.terminalView.vtgOverlayView.needsDisplay = true
            self.terminalView.vtgOverlayView.setNeedsDisplay(self.terminalView.vtgOverlayView.bounds)
            self.terminalView.needsDisplay = true
            self.terminalView.setNeedsDisplay(self.terminalView.bounds)
        }
    }

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

    private func postMouseEvent(
        from event: NSEvent,
        subtype: String,
        deltaX: Double = 0,
        deltaY: Double = 0
    ) {
        guard terminalView.frame.width > 0, terminalView.frame.height > 0 else { return }
        if subtype == "MOVE" {
            let previousMove = lastMouseMovePostTimestamp ?? 0
            guard event.timestamp - previousMove >= 1.0 / 30.0 else { return }
            lastMouseMovePostTimestamp = event.timestamp
        }
        let pointInSelf = convert(event.locationInWindow, from: nil)
        guard terminalView.frame.contains(pointInSelf) else { return }

        let point = terminalView.convert(pointInSelf, from: self)
        let canvas = terminalView.currentVTGCanvas()
        let canvasWidth = max(1, canvas.width)
        let canvasHeight = max(1, canvas.height)
        let x = min(max(Double(point.x / terminalView.bounds.width) * Double(canvasWidth), 0), Double(canvasWidth))
        let y = min(max(Double((terminalView.bounds.height - point.y) / terminalView.bounds.height) * Double(canvasHeight), 0), Double(canvasHeight))
        let previousTimestamp = lastMouseEventTimestamp ?? event.timestamp
        lastMouseEventTimestamp = event.timestamp
        let hit = model?.hitRegion(atX: x, y: y)
        model?.postVTGMouseEvent(
            subtype: subtype,
            x: x,
            y: y,
            button: max(0, event.buttonNumber),
            buttons: Int(NSEvent.pressedMouseButtons),
            duration: max(0, event.timestamp - previousTimestamp),
            deltaX: deltaX,
            deltaY: deltaY,
            hitID: hit?.id ?? "",
            target: hit?.target ?? ""
        )
    }

    private func handleProgramKeyEvent(_ event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "c",
           model?.shouldProgramStopOnTerminalInterrupt() == true {
            model?.stopProgram()
            return true
        }

        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "i",
           model?.shouldCaptureTerminalKeyOnly() != true {
            _ = model?.toggleConsoleOverwriteModeFromTerminal()
            return true
        }

        let shouldCaptureProgramKey = model?.shouldCaptureTerminalKeyOnly() == true
        let shouldExitLineInput = model?.shouldExitLineInputOnSpecialKey() == true
        guard shouldCaptureProgramKey || shouldExitLineInput,
              let rawKey = Self.rawSpecialKeySequence(from: event)
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

    private static func rawSpecialKeySequence(from event: NSEvent) -> String? {
        guard let characters = event.charactersIgnoringModifiers,
              let scalar = characters.unicodeScalars.first
        else {
            return nil
        }

        let key = Int(scalar.value)
        let modifier = modifierParameter(for: event)
        let escape = "\u{1B}"

        if key == 10 || key == 13 || key == NSCarriageReturnCharacter || key == NSEnterCharacter {
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift) else {
                return nil
            }
            return "\(escape)[!M"
        }

        if let modifiedCharacter = modifiedPrintableCharacter(from: event, modifier: modifier) {
            return "\(escape)[\(modifiedCharacter)"
        }

        func csi(_ base: String, final: String) -> String {
            if let modifier {
                return "\(escape)[\(base);\(modifier)\(final)"
            }
            return "\(escape)[\(base)\(final)"
        }

        func csiFinal(_ final: String) -> String {
            if let modifier {
                return "\(escape)[1;\(modifier)\(final)"
            }
            return "\(escape)[\(final)"
        }

        func ss3OrCsi(_ final: String) -> String {
            if let modifier {
                return "\(escape)[1;\(modifier)\(final)"
            }
            return "\(escape)O\(final)"
        }

        switch key {
        case NSUpArrowFunctionKey: return csiFinal("A")
        case NSDownArrowFunctionKey: return csiFinal("B")
        case NSRightArrowFunctionKey: return csiFinal("C")
        case NSLeftArrowFunctionKey: return csiFinal("D")
        case NSHomeFunctionKey: return csiFinal("H")
        case NSEndFunctionKey: return csiFinal("F")
        case NSInsertFunctionKey: return csi("2", final: "~")
        case NSDeleteFunctionKey: return csi("3", final: "~")
        case NSPageUpFunctionKey: return csi("5", final: "~")
        case NSPageDownFunctionKey: return csi("6", final: "~")
        case NSF1FunctionKey: return ss3OrCsi("P")
        case NSF2FunctionKey: return ss3OrCsi("Q")
        case NSF3FunctionKey: return ss3OrCsi("R")
        case NSF4FunctionKey: return ss3OrCsi("S")
        case NSF5FunctionKey: return csi("15", final: "~")
        case NSF6FunctionKey: return csi("17", final: "~")
        case NSF7FunctionKey: return csi("18", final: "~")
        case NSF8FunctionKey: return csi("19", final: "~")
        case NSF9FunctionKey: return csi("20", final: "~")
        case NSF10FunctionKey: return csi("21", final: "~")
        case NSF11FunctionKey: return csi("23", final: "~")
        case NSF12FunctionKey: return csi("24", final: "~")
        case NSF13FunctionKey: return csi("25", final: "~")
        case NSF14FunctionKey: return csi("26", final: "~")
        case NSF15FunctionKey: return csi("28", final: "~")
        case NSF16FunctionKey: return csi("29", final: "~")
        case NSF17FunctionKey: return csi("31", final: "~")
        case NSF18FunctionKey: return csi("32", final: "~")
        case NSF19FunctionKey: return csi("33", final: "~")
        case NSF20FunctionKey: return csi("34", final: "~")
        case NSF21FunctionKey: return csi("35", final: "~")
        case NSF22FunctionKey: return csi("36", final: "~")
        default: return nil
        }
    }

    private static func modifiedPrintableCharacter(from event: NSEvent, modifier: Int?) -> String? {
        guard let modifier,
              let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let character = characters.first,
              character.unicodeScalars.allSatisfy({ (32...126).contains(Int($0.value)) })
        else {
            return nil
        }

        switch modifier {
        case 3: return "#\(character)"
        case 4: return "!#\(character)"
        default: return nil
        }
    }

    private static func modifierParameter(for event: NSEvent) -> Int? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        let command = flags.contains(.command)

        switch (shift, option, command) {
        case (false, false, false): return nil
        case (true, false, false): return 2
        case (false, true, false): return 3
        case (true, true, false): return 4
        case (false, false, true): return 9
        case (true, false, true): return 10
        case (false, true, true): return 11
        case (true, true, true): return 12
        }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
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
                    appendRawSpecialKeySequence("\t", operations: &operations)
                } else {
                    appendText("\t", to: &operations)
                }
            case 8, 127:
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
                }
            case 32...126:
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
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
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
