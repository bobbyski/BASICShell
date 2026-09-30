#if os(iOS)
import SwiftTerm
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The console's terminal on iPhone and iPad: SwiftTerm's view, with the
/// console asked about each hardware key before SwiftTerm is.
///
/// This is the iOS twin of the Mac console's `NSEvent` key monitor. SwiftTerm
/// turns a key into the bytes a terminal sends, and those cannot carry what a
/// BASIC program reads with INKEY$: a modifier held with an arrow or function
/// key, Shift+Return, Option with a letter, or Page Up and Page Down (which
/// SwiftTerm spends on scrolling). A key the console takes never reaches
/// SwiftTerm; every other key goes on to it unchanged.
final class ConsoleTerminalView: VectorTerminalView {
    /// Asked first about each key press. True means the console took it.
    var pressInterceptor: ((ConsoleKeyPress) -> Bool)?

    /// Presses the console took, so their end is not handed to SwiftTerm
    /// either — it never saw them begin.
    private var interceptedPresses: Set<UIPress> = []
    private var repeatingPress: UIPress?
    private var repeatTimer: Timer?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var forwarded: Set<UIPress> = []
        for press in presses {
            guard let key = press.key, let pressInterceptor else {
                forwarded.insert(press)
                continue
            }
            let keyPress = ConsoleKeyPress(key)
            if pressInterceptor(keyPress) {
                interceptedPresses.insert(press)
                startRepeating(press, keyPress)
            } else {
                forwarded.insert(press)
            }
        }
        if !forwarded.isEmpty {
            super.pressesBegan(forwarded, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let forwarded = release(presses)
        if !forwarded.isEmpty {
            super.pressesEnded(forwarded, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let forwarded = release(presses)
        if !forwarded.isEmpty {
            super.pressesCancelled(forwarded, with: event)
        }
    }

    /// Forgets the console's presses among `presses`, and returns the rest.
    private func release(_ presses: Set<UIPress>) -> Set<UIPress> {
        let ours = presses.intersection(interceptedPresses)
        interceptedPresses.subtract(ours)
        if let repeatingPress, ours.contains(repeatingPress) {
            stopRepeating()
        }
        return presses.subtracting(ours)
    }

    /// iOS sends a key once, however long it is held; SwiftTerm repeats the
    /// keys it handles with a timer, and so does this for the keys the console
    /// takes — a program moving something while an arrow is held needs it.
    /// Same cadence as SwiftTerm's: a pause, then ten a second.
    private func startRepeating(_ press: UIPress, _ keyPress: ConsoleKeyPress) {
        stopRepeating()
        // ^C and ^I act once; only a key that sends a sequence repeats.
        guard keyPress.rawSequence != nil else { return }
        repeatingPress = press
        let timer = Timer(fire: Date(timeIntervalSinceNow: 0.4), interval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Asked again each time: a program that has stopped reading
                // keys should not keep receiving them.
                if self.pressInterceptor?(keyPress) != true {
                    self.stopRepeating()
                }
            }
        }
        RunLoop.current.add(timer, forMode: .default)
        repeatTimer = timer
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatingPress = nil
    }
}

extension ConsoleKeyPress {
    /// A UIKit key press, in the console's terms.
    init(_ key: UIKey) {
        var modifiers: ConsoleKeyModifiers = []
        if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if key.modifierFlags.contains(.alternate) { modifiers.insert(.option) }
        if key.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if key.modifierFlags.contains(.control) { modifiers.insert(.control) }
        self.init(
            special: Self.special(for: key.keyCode),
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            modifiers: modifiers
        )
    }

    static func special(for keyCode: UIKeyboardHIDUsage) -> ConsoleSpecialKey? {
        switch keyCode {
        case .keyboardUpArrow: return .up
        case .keyboardDownArrow: return .down
        case .keyboardRightArrow: return .right
        case .keyboardLeftArrow: return .left
        case .keyboardHome: return .home
        case .keyboardEnd: return .end
        case .keyboardInsert: return .insert
        case .keyboardDeleteForward: return .forwardDelete
        case .keyboardPageUp: return .pageUp
        case .keyboardPageDown: return .pageDown
        case .keyboardReturnOrEnter, .keyboardReturn, .keypadEnter: return .returnKey
        default:
            // F1–F12 and F13–F24 are each a contiguous run of HID usages.
            let code = keyCode.rawValue
            if (UIKeyboardHIDUsage.keyboardF1.rawValue...UIKeyboardHIDUsage.keyboardF12.rawValue).contains(code) {
                return .function(code - UIKeyboardHIDUsage.keyboardF1.rawValue + 1)
            }
            if (UIKeyboardHIDUsage.keyboardF13.rawValue...UIKeyboardHIDUsage.keyboardF24.rawValue).contains(code) {
                return .function(code - UIKeyboardHIDUsage.keyboardF13.rawValue + 13)
            }
            return nil
        }
    }
}

/// Watches one touch on the terminal and reports it as a mouse — down, moves,
/// up — for a VTG program, without ever recognising. SwiftTerm's own taps,
/// selection and scrolling keep every touch; this only listens.
final class ConsoleTouchMouseRecognizer: UIGestureRecognizer {
    enum Phase {
        case down, move, up
    }

    var onTouch: ((Phase, UITouch, UIEvent) -> Void)?
    /// The first finger down. A second one is a gesture, not a second mouse.
    private var tracked: UITouch?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil, let touch = touches.first else { return }
        tracked = touch
        onTouch?(.down, touch, event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        onTouch?(.move, tracked, event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, event)
    }

    private func finish(_ touches: Set<UITouch>, _ event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        onTouch?(.up, tracked, event)
        self.tracked = nil
        // Never recognised: this lets UIKit reset it for the next touch.
        state = .failed
    }

    override func reset() {
        super.reset()
        tracked = nil
    }

    // Neither stops nor is stopped by any other recognizer — SwiftTerm's pan
    // recognising must not cut this one's touches short.
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
#endif
