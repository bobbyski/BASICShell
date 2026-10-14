// A module under SwiftPM; compiled into the same module as the runtime when
// basicc builds its runtime from sources (RuntimeLibrary.sharedModules).
#if canImport(BASICSound)
import BASICSound
#endif
import Foundation

// BASICRT event traps — ON TIMER, KEY, PLAY, STRIG, COM and PEN GOSUB
// (BBC_ADINS.md A14).
//
// The rules are BASICSound's `BASICEventTraps`, the model the interpreter
// polls too. A program that sets a trap polls as each line of main starts
// (BIR's `.trapPoll`): when one fires, the runtime pushes the GOSUB, marked
// with its event, and names the handler; the handler's RETURN releases the
// trap. No poll runs while an ON ERROR handler does, as in the interpreter.

enum RTEventTraps {
    nonisolated(unsafe) static let traps = BASICEventTraps()
    /// The event each trap-made GOSUB was for, by the stack depth below it.
    nonisolated(unsafe) static var frames: [Int: BASICEventTraps.Event] = [:]

    /// An event from the numbers basicc passes: the kind in `EventTrap.Kind`'s
    /// order (TIMER, KEY, PLAY, STRIG, COM, PEN), and KEY's, STRIG's or
    /// COM's number.
    static func event(code: Double, number: Double) -> BASICEventTraps.Event {
        let n = Int(number.rounded())
        switch Int(code) {
        case 0: return .timer
        case 1: return .key(n)
        case 2: return .play
        case 3: return .strig(n)
        case 4: return .com(n)
        default: return .pen
        }
    }

    /// Runs `body`, failing the program with a refused trap's BASIC error.
    static func checked(_ body: () throws -> Void) {
        do {
            try body()
        } catch let error as BASICSoundError {
            basic_rt_fail(error.message)
        } catch {
            basic_rt_fail("\(error)")
        }
    }

    /// The GOSUB stack is back to `depth`: a trap's frame that was there has
    /// returned.
    static func returned(toDepth depth: Int) {
        guard !frames.isEmpty, let event = frames.removeValue(forKey: depth) else { return }
        traps.release(event)
    }
}

/// `ON event GOSUB handler`; `handler` -1 is `GOSUB 0`. `argument` is
/// TIMER's seconds or PLAY's count of notes.
@_cdecl("basic_rt_trap_set")
public func basic_rt_trap_set(_ code: Double, _ number: Double, _ argument: Double, _ handler: Double) {
    let event = RTEventTraps.event(code: code, number: number)
    let takesArgument = event == .timer || event == .play
    RTEventTraps.checked {
        try RTEventTraps.traps.setTarget(event, argument: takesArgument ? argument : nil, target: handler < 0 ? nil : Int(handler))
    }
}

/// `event ON` (1), `OFF` (0) or `STOP` (2).
@_cdecl("basic_rt_trap_state")
public func basic_rt_trap_state(_ code: Double, _ number: Double, _ state: Double) {
    let event = RTEventTraps.event(code: code, number: number)
    RTEventTraps.checked {
        try RTEventTraps.traps.setState(event, BASICEventTraps.State(rawValue: Int(state)) ?? .off)
    }
}

/// `KEY n, x$`: key 15–20 for `ON KEY`.
@_cdecl("basic_rt_key_define")
public func basic_rt_key_define(_ number: Double, _ definition: UnsafeMutableRawPointer?) {
    let text = rtText(definition)
    RTEventTraps.checked { try RTEventTraps.traps.defineKey(Int(number.rounded()), as: text) }
}

/// As a line of main starts: the handler to GOSUB to, with the GOSUB to
/// `resume` already pushed, or -1.
@_cdecl("basic_rt_trap_poll")
public func basic_rt_trap_poll(_ resume: Int) -> Int {
    let traps = RTEventTraps.traps
    guard traps.isWatching, !RTError.isHandling else { return -1 }
    if traps.isWatchingKeys {
        RTKeys.takeTrappedKeys { traps.takeKey(named: $0) }
    }
    guard let fired = traps.poll(playCount: RTSound.musicQueueCount) else { return -1 }
    RTEventTraps.frames[RTGosubStack.entries.count] = fired.event
    RTGosubStack.entries.append(resume)
    return fired.target
}
