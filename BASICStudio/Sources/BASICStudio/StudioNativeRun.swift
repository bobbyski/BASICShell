//
//  StudioNativeRun.swift
//  BASICStudio
//
//  A compiled ⚡ program on a pseudo-terminal, with Studio's console as the
//  terminal.
//

#if os(macOS)
import Foundation
import SwiftTerm

/// Runs a natively compiled program the way VGTerm runs BASICShell.
///
/// Both ends of this were always the same component: Studio's console is a
/// `VectorTerminalView`, and VGTerm — where BASICShell's ⚡ graphics work — is
/// the same view driven by `LocalProcess`. The only thing Studio was missing
/// is the pseudo-terminal between them.
///
/// It matters because the compiled runtime finds its graphics by *asking*:
/// it writes VTG's `capabilities?` and waits for the terminal to answer. On
/// a pipe nothing answers, `RTHostCanvas.probe()` comes back nil, and the
/// first `vtg.` call fails with "VectorTerminal graphics are not supported by
/// this host" — which is exactly what a ⚡ LLVM run of a graphics program did.
/// On a pty the console answers, because answering is what it already does
/// for the interpreter.
///
/// `LocalProcess` is SwiftTerm's own, so the pty, the fork and the window
/// size are the tested ones rather than a second implementation here.
@MainActor
final class StudioNativeRun: NSObject, LocalProcessDelegate {
    /// The console's size, kept where any thread may read it.
    ///
    /// `LocalProcess` asks for the window size on whichever thread it is
    /// starting or reading on, so this cannot be main-actor state: hopping
    /// would deadlock and asserting would crash.
    private final class Size: @unchecked Sendable {
        private let lock = NSLock()
        private var value = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

        func set(columns: Int, rows: Int) {
            lock.lock()
            defer { lock.unlock() }
            value = winsize(
                ws_row: UInt16(max(1, rows)), ws_col: UInt16(max(1, columns)),
                ws_xpixel: 0, ws_ypixel: 0
            )
        }

        func get() -> winsize {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// Raw bytes from the program, for the console's terminal to parse.
    private let output: ([UInt8]) -> Void
    /// Called when the program ends, with its exit status.
    private let finished: (Int32?) -> Void
    private let size = Size()

    private var process: LocalProcess!

    init(
        output: @escaping ([UInt8]) -> Void,
        finished: @escaping (Int32?) -> Void
    ) {
        self.output = output
        self.finished = finished
        super.init()
        process = LocalProcess(delegate: self)
    }

    func start(binary: String) {
        process.startProcess(executable: binary)
    }

    /// What the console's terminal sends: keys, and the VTG and mouse reports
    /// the program is waiting on.
    func send(_ bytes: ArraySlice<UInt8>) {
        process.send(data: bytes)
    }

    func stop() {
        process.terminate()
    }

    /// The console's new size, so the program's next `TIOCGWINSZ` agrees with
    /// what it can see.
    func resized(columns: Int, rows: Int) {
        size.set(columns: columns, rows: rows)
        guard process.childfd >= 0 else { return }
        var updated = size.get()
        _ = ioctl(process.childfd, TIOCSWINSZ, &updated)
    }

    // MARK: - LocalProcessDelegate

    nonisolated func dataReceived(slice: ArraySlice<UInt8>) {
        let bytes = Array(slice)
        Task { @MainActor [weak self] in
            self?.output(bytes)
        }
    }

    nonisolated func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            self?.finished(exitCode)
        }
    }

    nonisolated func getWindowSize() -> winsize {
        size.get()
    }
}
#endif
