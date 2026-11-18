//
//  NativeAUIHost.swift
//  BASICRTActiveUI
//
//  The program thread's side of a compiled program's windows.
//

import BASICCore
import Foundation

/// The ``BASICAUIHost`` a compiled program's AUI classes talk to (BASIC-31):
/// each request carried from the program's thread to the main thread, where
/// ``NativeAUIBridge`` carries it out, and the answer carried back.
///
/// ```text
///   program thread                      main thread
///   auiPerform(.setText …) ─ sync ──►  bridge.perform  (AppKit, ActiveUI)
///   auiPerform(.show dialog) ─ async ─► the alert; the program waits for
///        ◄──────── signal ───────────  the button, the main thread stays free
/// ```
///
/// A dialog's `show` is the one request that waits for the user, and it
/// waits here, on the program's thread, so the main thread can run the alert.
/// Console text is the process's own: stdout and stdin.
final class NativeAUIHost: BASICAUIHost, @unchecked Sendable {
    /// The windows, on the main thread.
    private let bridge: NativeAUIBridge

    /// A host over `bridge`.
    init(bridge: NativeAUIBridge) {
        self.bridge = bridge
    }

    /// Text to stdout, as the program's PRINT writes it.
    func print(_ text: String, terminator: String) {
        fputs(text + terminator, stdout)
    }

    /// A line to stdout.
    func printLine(_ text: String) {
        fputs(text + "\n", stdout)
    }

    /// A line from stdin.
    func readLine(prompt: String) -> String? {
        fputs(prompt, stdout)
        fflush(stdout)
        return Swift.readLine(strippingNewline: true)
    }

    /// Carries out `request` on the main thread, waiting for a dialog's
    /// button when the request shows one.
    func auiPerform(_ request: BASICAUIRequest) throws -> BASICAUIAnswer {
        let bridge = self.bridge
        if case .show(let id) = request, Self.onMain({ bridge.isDialog(id) }) {
            let answered = DispatchSemaphore(value: 0)
            let choice = ChoiceBox()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    bridge.showDialog(id) { index in
                        choice.set(index)
                        answered.signal()
                    }
                }
            }
            answered.wait()
            return .number(Double(choice.value))
        }
        let result: Result<BASICAUIAnswer, BASICError> = Self.onMain {
            do {
                return .success(try bridge.perform(request))
            } catch let error as BASICError {
                return .failure(error)
            } catch {
                return .failure(.runtime("\(error)"))
            }
        }
        return try result.get()
    }

    /// Runs `body` on the main thread and gives back what it answered: at
    /// once when this is the main thread, else waiting for it there.
    static func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(body)
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated(body)
        }
    }
}

/// The button a dialog answered, handed from the main thread to the
/// program's.
private final class ChoiceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var choice = -1

    /// The button's index, -1 until one is pressed.
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return choice
    }

    /// Records the button pressed.
    func set(_ value: Int) {
        lock.lock()
        choice = value
        lock.unlock()
    }
}
