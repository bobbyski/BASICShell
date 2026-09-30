//
//  StudioTUIDriver.swift
//  BASICStudio
//
//  The surface a TUI program draws on in Studio: the console pane
//  (TUIKIT_PLAN.md §7, option A).
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import TUIKit

/// Runs a TUIKit application in the console pane.
///
/// The console is a VectorTerminal view, the terminal BASICShell runs in, so
/// it reads ANSI exactly as that one does. This driver writes what
/// `ANSIDriver` writes (the alternate screen, SGR mouse reporting, frames
/// from `ANSIEncoder`) into the console, and reads back the bytes the
/// console's terminal sends for the keyboard and the mouse, decoded by
/// TUIKit's own `ANSIInputDecoder`. What it leaves out is what needs a tty:
/// raw mode means nothing here, and the size comes from the pane.
///
/// Everything a session writes is taken back out of the console when it
/// ends (``StudioModel/endTUISession(_:)``), so the main screen comes back
/// as the program left it and the frames do not pile up in the scrollback.
actor StudioTUIDriver: TerminalDriver {
    /// What the console hands the driver, in the order it happened.
    enum Incoming: Sendable {
        /// Bytes the console's terminal sent for a key or the mouse.
        case bytes([UInt8])
        /// The pane has a new size, in cells.
        case resize(TUIKit.Size)
    }

    private let model: StudioModel
    /// How the console reaches the driver. `yield` is synchronous and keeps
    /// the order, which a task per keystroke would not.
    nonisolated let incoming: AsyncStream<Incoming>.Continuation
    private let incomingEvents: AsyncStream<Incoming>

    private var decoder = ANSIInputDecoder()
    private var escapeGeneration = 0
    private var pump: Task<Void, Never>?
    private var continuations: [Int: AsyncStream<TerminalInput>.Continuation] = [:]
    private var nextContinuationID = 0
    private var presentedLines: [String]?
    private var currentSize = TUIKit.Size(width: 80, height: 24)
    private var isActive = false

    init(model: StudioModel) {
        self.model = model
        let (events, continuation) = AsyncStream<Incoming>.makeStream()
        incomingEvents = events
        incoming = continuation
    }

    var size: TUIKit.Size {
        get async { currentSize }
    }

    func begin() async throws {
        guard !isActive else {
            throw ANSIDriver.DriverError.alreadyBegan
        }
        isActive = true
        presentedLines = nil
        currentSize = await model.beginTUISession(self)
        // What ANSIDriver writes: alternate screen, hidden cursor, SGR mouse.
        await model.appendTUIOutput("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?1002h\u{1B}[?1006h\u{1B}[2J\u{1B}[H")
        startPump()
    }

    func end() async {
        pump?.cancel()
        pump = nil
        incoming.finish()
        if isActive {
            await model.endTUISession(self)
        }
        isActive = false
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    func present(_ buffer: CellBuffer) async {
        let lines = ANSIEncoder.encode(buffer)
        let frame = ANSIEncoder.frame(lines: lines, previous: presentedLines)
        presentedLines = lines
        guard !frame.isEmpty else { return }
        await model.appendTUIOutput(frame)
    }

    func setCursor(_ cursor: TerminalCursor) async {
        var sequence = "\u{1B}[\(cursor.position.y + 1);\(cursor.position.x + 1)H"
        sequence += cursor.isVisible ? "\u{1B}[?25h" : "\u{1B}[?25l"
        await model.appendTUIOutput(sequence)
    }

    func inputStream() async -> AsyncStream<TerminalInput> {
        AsyncStream { continuation in
            let id = nextContinuationID
            nextContinuationID += 1
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { [weak self] in
                    await self?.removeContinuation(id)
                }
            }
        }
    }

    /// The real pasteboard. ANSIDriver asks the terminal with OSC 52; here
    /// the pasteboard is in reach.
    func setClipboard(_ text: String) async {
        await MainActor.run {
            #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #else
            UIPasteboard.general.string = text
            #endif
        }
    }

    // MARK: Input

    private func startPump() {
        let events = incomingEvents
        pump = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: Incoming) {
        switch event {
        case .bytes(let bytes):
            escapeGeneration += 1
            for input in decoder.feed(bytes) {
                publish(input)
            }
            // A lone ESC might begin a sequence; it is the Escape key if
            // nothing follows shortly, as ANSIDriver decides it.
            if decoder.hasPendingEscape {
                let generation = escapeGeneration
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(25))
                    await self?.flushPendingEscape(ifStillGeneration: generation)
                }
            }
        case .resize(let size):
            guard size != currentSize else { return }
            currentSize = size
            // The console reflowed nothing; the next frame redraws it all.
            presentedLines = nil
            publish(.resize(size))
        }
    }

    private func flushPendingEscape(ifStillGeneration generation: Int) {
        guard generation == escapeGeneration else { return }
        for input in decoder.flushPending() {
            publish(input)
        }
    }

    private func publish(_ input: TerminalInput) {
        for continuation in continuations.values {
            continuation.yield(input)
        }
    }

    private func removeContinuation(_ id: Int) {
        continuations[id] = nil
    }
}
