//
//  BASICEventTraps.swift
//  BASICSound
//
//  GW-BASIC's event trapping: ON TIMER, KEY, PLAY, STRIG, COM and PEN GOSUB.
//

import Foundation

/// GW-BASIC's event traps, as both engines run them (BBC_ADINS.md A14,
/// Bobby's ruling B9, 2026-10-13).
///
/// ```text
///   ON TIMER(n) GOSUB line     n seconds after TIMER ON, and every n after
///   ON KEY(n) GOSUB line       F1–F10 are 1–10, the arrows 11–14, 15–20 as KEY n, x$ defines
///   ON PLAY(n) GOSUB line      the background queue goes from n notes to n − 1
///   ON STRIG(n), ON COM(n), ON PEN GOSUB line
///                              accepted, armed and disarmed, never fired: no such hardware
///   event ON | OFF | STOP      armed; off and forgotten; held, and remembered
/// ```
///
/// The rules are the GW-BASIC User's Guide's ("ON COM(n), ON KEY(n), ON PEN,
/// ON PLAY(n), ON STRIG(n), and ON TIMER(n) Statements"):
///
/// - An engine asks `poll` as each statement of the main program starts (a
///   line of colon-separated statements is several). An event
///   that has happened to a trap that is `ON`, with a line to go to, fires:
///   the engine `GOSUB`s there, returning to the line it was about to run.
/// - A trap that fires is held, "so recursive traps can never take place",
///   until the engine reports its handler's `RETURN` with `release`. The trap
///   is then on again, unless the handler turned it `OFF` (or `STOP`ped it).
/// - `STOP` remembers an event and fires it once the trap is `ON` again;
///   `OFF` forgets it.
/// - An engine does not poll while an `ON ERROR` handler runs, or inside a
///   `FUNCTION`: a `GOSUB` cannot leave a routine, so an event waits for the
///   main program.
///
/// It lives in `BASICSound` because that is the module both engines already
/// share, and `ON PLAY` reads the sound session's queue.
public final class BASICEventTraps {
    /// What a trap watches.
    public enum Event: Hashable, Sendable {
        case timer
        case key(Int)
        case play
        case strig(Int)
        case com(Int)
        case pen
    }

    /// `event ON`, `event OFF` or `event STOP`.
    public enum State: Int, Sendable {
        case off = 0
        case on = 1
        case stopped = 2
    }

    /// The highest key `ON KEY(n)` takes: 1–10 are F1–F10, 11–14 the arrows,
    /// and 15–20 whatever `KEY n, x$` defines.
    public static let keyCount = 20

    private struct Trap {
        /// Where the handler is, in the engine's own terms; nil for `GOSUB 0`.
        var target: Int?
        var state: State = .off
        /// It happened, and has not fired yet.
        var pending = false
        /// Its handler is running.
        var held = false
    }

    private var traps: [Event: Trap] = [:]
    private let clock: () -> TimeInterval
    private var timerInterval: TimeInterval = 0
    private var timerDue: TimeInterval?
    private var playThreshold = 1
    private var lastPlayCount = 0
    /// `KEY 15`–`KEY 20`, as `KEY n, CHR$(shift) + CHR$(scan code)` set them.
    private var definedKeys: [Int: String] = [:]

    /// Traps on `clock`, the machine's uptime unless a test says otherwise.
    public init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    /// Whether any trap is `ON` or `STOP`ped: with none, there is nothing to
    /// poll, and an engine skips the call.
    public var isWatching: Bool { traps.values.contains { $0.state != .off } }

    /// Whether a key trap is `ON` or `STOP`ped, so keys pressed now have to
    /// be looked at before `INKEY$` sees them.
    public var isWatchingKeys: Bool {
        traps.contains { entry in
            if case .key = entry.key { return entry.value.state != .off }
            return false
        }
    }

    // MARK: Statements

    /// `ON event GOSUB target`. `argument` is `TIMER`'s seconds and `PLAY`'s
    /// note count; `target` nil is GW's `GOSUB 0`, which turns the trap off.
    public func setTarget(_ event: Event, argument: Double?, target: Int?) throws {
        switch event {
        case .timer:
            guard let seconds = argument, seconds > 0, seconds.isFinite else { throw BASICSoundError.illegalFunctionCall }
            timerInterval = seconds
            if traps[.timer]?.state == .on || traps[.timer]?.state == .stopped { timerDue = clock() + seconds }
        case .play:
            guard let count = argument, (1...Double(BASICSoundSession.backgroundCapacity)).contains(count.rounded()) else {
                throw BASICSoundError.illegalFunctionCall
            }
            playThreshold = Int(count.rounded())
        case .key(let number):
            guard (1...Self.keyCount).contains(number) else { throw BASICSoundError.illegalFunctionCall }
        case .strig, .com, .pen:
            break
        }
        traps[event, default: Trap()].target = target
        if target == nil {
            traps[event]?.state = .off
            traps[event]?.pending = false
        }
    }

    /// `event ON`, `OFF` or `STOP`.
    public func setState(_ event: Event, _ state: State) throws {
        if case .key(let number) = event, !(1...Self.keyCount).contains(number) {
            throw BASICSoundError.illegalFunctionCall
        }
        let was = traps[event]?.state ?? .off
        traps[event, default: Trap()].state = state
        if state == .off { traps[event]?.pending = false }
        guard was == .off, state != .off else { return }
        // Watching starts now: the timer counts from here, and PLAY from
        // the queue as it stands.
        switch event {
        case .timer: timerDue = timerInterval > 0 ? clock() + timerInterval : nil
        case .play: lastPlayCount = 0
        default: break
        }
    }

    /// `KEY n, x$` for keys 15–20: `x$` is `CHR$(shift) + CHR$(scan code)`,
    /// as GW's User's Guide describes. The shift byte is accepted and not
    /// checked; the scan code names the key.
    public func defineKey(_ number: Int, as definition: String) throws {
        let bytes = Array(definition.unicodeScalars.map(\.value))
        guard (15...20).contains(number), bytes.count == 2, let name = Self.keyName(scanCode: Int(bytes[1])) else {
            throw BASICSoundError.illegalFunctionCall
        }
        definedKeys[number] = name
    }

    // MARK: Polling

    /// A key the program read, by its canonical name (`F1`, `UP`, `A`): true
    /// when a key trap that is `ON` or `STOP`ped took it, so `INKEY$` must
    /// not see it.
    public func takeKey(named name: String) -> Bool {
        for number in 1...Self.keyCount where Self.name(ofKey: number, defined: definedKeys) == name {
            guard let trap = traps[.key(number)], trap.state != .off else { continue }
            traps[.key(number)]?.pending = true
            return true
        }
        return false
    }

    /// At the start of a statement: the trap to fire now, and where its handler
    /// is, or nil. `playCount` is how many notes the music queue holds. The
    /// trap fired is held until `release`.
    public func poll(playCount: Int) -> (event: Event, target: Int)? {
        let now = clock()
        if let due = timerDue, now >= due, let state = traps[.timer]?.state, state != .off {
            traps[.timer]?.pending = true
            timerDue = now + timerInterval
        }
        if let state = traps[.play]?.state, state != .off {
            if lastPlayCount >= playThreshold, playCount < playThreshold {
                traps[.play]?.pending = true
            }
            lastPlayCount = playCount
        }
        for event in Self.order {
            guard let trap = traps[event], trap.pending, trap.state == .on, !trap.held, let target = trap.target else { continue }
            traps[event]?.pending = false
            traps[event]?.held = true
            return (event, target)
        }
        return nil
    }

    /// The handler for `event` returned: its trap is no longer held.
    public func release(_ event: Event) {
        traps[event]?.held = false
    }

    /// Every trap off, and every definition gone, as a fresh run starts.
    public func reset() {
        traps.removeAll()
        timerDue = nil
        timerInterval = 0
        playThreshold = 1
        lastPlayCount = 0
        definedKeys.removeAll()
    }

    /// Which fires first when several are pending.
    private static let order: [Event] = [.timer] + (1...keyCount).map { .key($0) } + [.play]

    // MARK: Keys

    /// The canonical name of key trap `number`, as `KEYDOWN` names keys.
    static func name(ofKey number: Int, defined: [Int: String]) -> String? {
        switch number {
        case 1...10: return "F\(number)"
        case 11: return "UP"
        case 12: return "LEFT"
        case 13: return "RIGHT"
        case 14: return "DOWN"
        default: return defined[number]
        }
    }

    /// A PC keyboard's scan code (GW-BASIC User's Guide, Appendix H), by the
    /// canonical name of its key.
    static func keyName(scanCode: Int) -> String? {
        switch scanCode {
        case 1: return "ESCAPE"
        case 2...10: return String(scanCode - 1)
        case 11: return "0"
        case 12: return "-"
        case 13: return "="
        case 14: return "BACKSPACE"
        case 15: return "TAB"
        case 16...25: return String(Array("QWERTYUIOP")[scanCode - 16])
        case 26: return "["
        case 27: return "]"
        case 28: return "ENTER"
        case 30...38: return String(Array("ASDFGHJKL")[scanCode - 30])
        case 39: return ";"
        case 40: return "'"
        case 41: return "`"
        case 43: return "\\"
        case 44...50: return String(Array("ZXCVBNM")[scanCode - 44])
        case 51: return ","
        case 52: return "."
        case 53: return "/"
        case 55: return "*"
        case 57: return "SPACE"
        case 59...68: return "F\(scanCode - 58)"
        case 71: return "HOME"
        case 72: return "UP"
        case 73: return "PAGEUP"
        case 74: return "-"
        case 75: return "LEFT"
        case 77: return "RIGHT"
        case 78: return "+"
        case 79: return "END"
        case 80: return "DOWN"
        case 81: return "PAGEDOWN"
        case 82: return "INSERT"
        case 83: return "DELETE"
        default: return nil
        }
    }
}
