//
//  BASICEventTrapping.swift
//  BASICCore
//
//  The interpreter's half of GW-BASIC's event traps.
//

import Foundation

/// What the interpreter adds to `BASICEventTraps`, the model both engines
/// share (BBC_ADINS.md A14): which event a statement names, and the keys a
/// trap has to see before `INKEY$` does.
///
/// The interpreter polls the model as each line of the main program starts,
/// and a trap that fires is a `GOSUB` whose frame remembers the event, so
/// its `RETURN` can release it.
enum BASICEventTrapping {
    /// The event `trap` names, its number evaluated.
    static func event(for trap: EventTrap, number: (Expression) throws -> Int) throws -> BASICEventTraps.Event {
        func numbered() throws -> Int {
            guard let argument = trap.argument else { throw BASICError.syntax("Expected (n) after \(trap.kind.rawValue)") }
            return try number(argument)
        }
        switch trap.kind {
        case .timer: return .timer
        case .play: return .play
        case .pen: return .pen
        case .key: return .key(try numbered())
        case .strig: return .strig(try numbered())
        case .com: return .com(try numbered())
        }
    }

    /// The model's state for `ON`, `OFF` or `STOP`.
    static func state(_ state: EventTrapState) -> BASICEventTraps.State {
        switch state {
        case .on: return .on
        case .off: return .off
        case .stop: return .stopped
        }
    }

    /// Reads every key waiting, giving each to a key trap that wants it and
    /// keeping the rest, in order, for `INKEY$` and `INPUT$`.
    static func takeKeys(for traps: BASICEventTraps, from read: () -> String?, encoding: BASICKeyEncoding,
                         keeping kept: inout [String]) {
        while let raw = read(), !raw.isEmpty {
            let key = BASICKeyNormalizer.normalize(raw, encoding: encoding)
            if let name = BASICKeyName.canonical(key), traps.takeKey(named: name) { continue }
            kept.append(raw)
        }
    }

    /// How a trap's frame is named in the debugger's call stack.
    static func frameName(_ event: BASICEventTraps.Event) -> String {
        switch event {
        case .timer: return "ON TIMER"
        case .key(let number): return "ON KEY(\(number))"
        case .play: return "ON PLAY"
        case .strig(let number): return "ON STRIG(\(number))"
        case .com(let number): return "ON COM(\(number))"
        case .pen: return "ON PEN"
        }
    }
}
