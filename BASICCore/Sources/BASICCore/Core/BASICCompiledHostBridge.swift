//
//  BASICCompiledHostBridge.swift
//  BASICCore
//
//  What BASICStudio gives a compiled program it runs (BASIC-45): the user's
//  events, and the touch controls.
//

import Foundation

/// The host's events, on their way to a program compiled to WebAssembly.
///
/// Studio's console and windows post what the user does to the session:
/// `postMouseEvent`, `postResizeEvent`, `postGamepadEvent`, `postAUIEvent`.
/// While Studio runs a compiled program the session sends them here instead
/// (``BASICSession/sendsHostEventsToCompiledProgram``), and the compiled
/// runtime takes them at its next drain, so the program's handlers run on
/// its own thread, as the interpreter's do. An event that coalesces replaces
/// one of its kind still waiting, as in the session.
public enum BASICCompiledEvents {
    /// A field's value: the shapes that cross between the two runtimes.
    public typealias Value = BASICCompiledTUI.Value

    /// One event: its selector and the interpreter's lowerCamel fields.
    public struct Event: Sendable, Equatable {
        public let type: String
        public let subtype: String
        public let fields: [String: Value]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [(event: Event, coalesces: Bool)] = []

    /// Queues an event. Safe from any thread.
    public static func post(type: String, subtype: String, fields: [String: Value], coalesces: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let event = Event(type: type.uppercased(), subtype: subtype.uppercased(), fields: fields)
        if coalesces, let index = queue.lastIndex(where: {
            $0.coalesces && $0.event.type == event.type && $0.event.subtype == event.subtype
        }) {
            queue[index] = (event, true)
        } else {
            queue.append((event, coalesces))
        }
    }

    /// The session's event, as the session would have queued it.
    static func post(type: String, subtype: String, fields: [String: BASICValue], coalesces: Bool) {
        post(type: type, subtype: subtype, fields: fields.mapValues(value), coalesces: coalesces)
    }

    /// Everything queued since the last call, oldest first.
    public static func take() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        let taken = queue.map(\.event)
        queue = []
        return taken
    }

    /// A new run: nothing waiting.
    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        queue = []
    }

    private static func value(_ value: BASICValue) -> Value {
        switch value {
        case .number(let number): return .number(number)
        case .string(let text): return .string(text.description)
        case .boolean(let flag): return .boolean(flag)
        default: return .empty
        }
    }
}

/// `TouchControls` as a compiled program sees it: the interpreter's own
/// object, over the host's touch screen, so the two engines place the same
/// controls and read them back alike.
public enum BASICCompiledTouchControls {
    public typealias Value = BASICCompiledTUI.Value
    public typealias Failure = BASICCompiledTUI.Failure

    /// What the program has placed: one set per run, as the interpreter has.
    nonisolated(unsafe) private static var controls = BASICTouchControlsCall()

    /// A new run: nothing placed.
    public static func reset() {
        controls = BASICTouchControlsCall()
    }

    /// Calls `method` on the program's `TouchControls`.
    public static func call(method: String, arguments: [Value], host: BASICTouchControlsHost?) throws -> Value {
        let values: [BASICValue] = arguments.map { argument in
            switch argument {
            case .number(let number): return .number(number)
            case .string(let text): return .string(BASICString(text))
            case .boolean(let flag): return .boolean(flag)
            case .handle, .empty: return .empty
            }
        }
        do {
            switch try controls.method(method, arguments: values, host: host) {
            case .number(let number): return .number(number)
            case .boolean(let flag): return .boolean(flag)
            case .string(let text): return .string(text.description)
            default: return .empty
            }
        } catch let error as BASICError {
            if case .runtime(let message) = error { throw Failure(message: message) }
            throw Failure(message: error.description)
        }
    }
}
