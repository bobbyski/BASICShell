import Foundation

// BASICRT events — `ON RESIZE/MOUSE/GAMEPAD/FRAME … CALL`, `ON timer GOSUB`,
// `SecondsTimer`, and the queue they are delivered through.
//
// The interpreter posts an event from its host, queues it, and runs the
// handlers between statements: up to sixteen after each statement, up to
// eight at a `YIELD`. Everything here keeps that: a handler is registered
// by selector, the payload is the interpreter's dictionary of lowerCamel
// keys (converted to a typed event object when the handler asks for one),
// and a handler runs only at a drain point, never inside the statement that
// posted the event.
//
// A timer is due when the drain reaches it — the interpreter runs a GCD
// timer that posts into the same queue, so the observable difference is
// only that a compiled program cannot fall behind its own queue.

/// The host's mouse-reporting switch (BASICRTHost) — or the stub that says no.
@_silgen_name("basic_rt_host_mouse_reporting") func rtHostMouseReporting(_ enabled: Bool)
/// Whether the host has a VTG terminal at all.
@_silgen_name("basic_rt_host_graphics_available") func rtHostGraphicsAvailableForEvents() -> Bool

/// A queued event: the selector it was posted for and its fields.
final class RTEvent {
    let type: String
    let subtype: String
    let fields: [String: RTValue]

    init(type: String, subtype: String, fields: [String: RTValue]) {
        self.type = type
        self.subtype = subtype
        self.fields = fields
    }
}

/// A registered handler: the trampoline the compiler emitted, and the type
/// index of the event object it wants (-1 for a VARIANT/DICTIONARY).
struct RTEventHandler {
    let trampoline: RTEventTrampoline
    let typeIndex: Int
}

typealias RTEventTrampoline = @convention(c) (UnsafeMutableRawPointer?) -> Void

/// A `SecondsTimer` object's state.
package final class RTTimer {
    package let id: Int
    package var intervalSeconds: Double
    package var repeating = false
    package var isRunning = false
    /// How many times it has fired: the interpreter's tick sequence.
    package var sequence = 0
    /// When it next comes due, on the monotonic clock.
    package var nextFire: Double = 0

    init(id: Int, intervalSeconds: Double) {
        self.id = id
        self.intervalSeconds = intervalSeconds
    }
}

enum RTEvents {
    nonisolated(unsafe) static var handlers: [String: RTEventHandler] = [:]
    nonisolated(unsafe) static var queue: [RTEvent] = []
    nonisolated(unsafe) static var timers: [Int: RTTimer] = [:]
    nonisolated(unsafe) static var nextTimerID = 1
    /// A handler's own statements must not re-enter the drain.
    nonisolated(unsafe) static var dispatching = false
    /// Whether any handler wants mouse or resize events, so `INKEY$` knows
    /// to ask the terminal for them.
    nonisolated(unsafe) static var wantsHostInput = false

    static func key(_ type: String, _ subtype: String) -> String {
        subtype.isEmpty ? type : "\(type).\(subtype)"
    }

    /// The handler for a selector: the exact one, else the type's.
    static func handler(for event: RTEvent) -> RTEventHandler? {
        handlers[key(event.type, event.subtype)] ?? handlers[event.type]
    }

    static func post(type: String, subtype: String, fields: [String: RTValue]) {
        // Selectors are normalized to uppercase, registration and post alike.
        let event = RTEvent(type: type.uppercased(), subtype: subtype.uppercased(), fields: fields)
        guard handler(for: event) != nil else { return }
        queue.append(event)
    }

    /// Seconds on a clock that does not jump.
    static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Posts whatever the running timers owe, oldest first.
    static func postDueTimerEvents() {
        let time = now()
        for id in timers.keys.sorted() {
            guard let timer = timers[id], timer.isRunning, timer.intervalSeconds > 0 else { continue }
            while timer.isRunning, time >= timer.nextFire {
                timer.sequence += 1
                postTimerEvent(timer)
                if timer.repeating {
                    timer.nextFire += timer.intervalSeconds
                } else {
                    timer.isRunning = false
                }
            }
        }
    }

    /// The interpreter's timer payload, for every `ON timer, n` whose tick
    /// count divides the sequence.
    private static func postTimerEvent(_ timer: RTTimer) {
        let milliseconds = Int((timer.intervalSeconds * 1000).rounded())
        let prefix = "\(timer.id):"
        for subtype in handlers.keys.sorted() where subtype.hasPrefix("TIMER.\(prefix)") {
            let tail = subtype.dropFirst("TIMER.".count)
            guard let ticks = Int(tail.dropFirst(prefix.count)), ticks > 0, timer.sequence % ticks == 0 else { continue }
            queue.append(RTEvent(type: "TIMER", subtype: String(tail), fields: [
                "type": .string(RTText("TIMER")),
                "subtype": .string(RTText(String(tail))),
                "timerID": .number(Double(timer.id)),
                "timerId": .number(Double(timer.id)),
                "sequence": .number(Double(timer.sequence)),
                "tick": .number(Double(ticks)),
                "ticks": .number(Double(ticks)),
                "interval": .number(Double(milliseconds)),
                "baseInterval": .number(Double(milliseconds)),
                "elapsed": .number(Double(timer.sequence) * Double(milliseconds) / 1000.0),
            ]))
        }
    }

    /// The payload a handler receives: the dictionary the interpreter posts,
    /// or the typed event object when the handler's parameter names one.
    static func payload(for event: RTEvent, typeIndex: Int) -> RTValue {
        guard typeIndex >= 0 else {
            let dictionary = RTDictionary()
            for (name, value) in event.fields { dictionary.values[name] = value.copied() }
            return .dictionary(dictionary)
        }
        let type = RTTypes.type(typeIndex)
        let composite = RTComposite(typeIndex: typeIndex)
        // The dictionary's keys are lowerCamel and the fields are declared in
        // Pascal case, so they match on the normalized name.
        var byName: [String: RTValue] = [:]
        for (name, value) in event.fields { byName[name.uppercased()] = value }
        for (slot, field) in type.fields.enumerated() {
            guard let value = byName[field.name] else { continue }
            guard let coerced = try? RTCoerce.coerce(value, to: field.type, name: field.displayName) else { continue }
            composite.fields[slot] = coerced
        }
        return .composite(composite)
    }

    /// Runs up to `limit` queued events. Timers come due here too.
    static func drain(limit: Int) {
        guard !dispatching else { return }
        guard !handlers.isEmpty else { return }
        dispatching = true
        defer { dispatching = false }
        postDueTimerEvents()
        var delivered = 0
        while delivered < limit, !queue.isEmpty {
            let event = queue.removeFirst()
            delivered += 1
            guard let handler = handler(for: event) else { continue }
            let box = rtOwned(payload(for: event, typeIndex: handler.typeIndex))
            defer { basic_rt_value_release(box) }
            handler.trampoline(box)
        }
    }
}

// MARK: - The ABI

/// `ON <selector> CALL handler` / `ON timer, n GOSUB handler`.
@_cdecl("basic_rt_event_register")
public func basic_rt_event_register(_ type: UnsafePointer<CChar>, _ subtype: UnsafePointer<CChar>, _ handler: UnsafeMutableRawPointer, _ typeIndex: Int) {
    let selectorType = String(cString: type).uppercased()
    let selectorSubtype = String(cString: subtype).uppercased()
    RTEvents.handlers[RTEvents.key(selectorType, selectorSubtype)] = RTEventHandler(
        trampoline: unsafeBitCast(handler, to: RTEventTrampoline.self),
        typeIndex: typeIndex
    )
    if selectorType == "MOUSE" || selectorType == "RESIZE" || selectorType == "GAMEPAD" || selectorType == "FRAME" {
        RTEvents.wantsHostInput = true
    }
    // The interpreter turns mouse reporting on as soon as a program asks for
    // mouse events, and only when the terminal can carry them.
    if selectorType == "MOUSE", rtHostGraphicsAvailableForEvents() {
        rtHostMouseReporting(true)
    }
}

/// Posts an event the host read from the terminal.
@_cdecl("basic_rt_event_post")
public func basic_rt_event_post(_ type: UnsafePointer<CChar>, _ subtype: UnsafePointer<CChar>, _ fields: UnsafeMutableRawPointer?) {
    guard case .dictionary(let dictionary) = rtValue(fields) else { return }
    RTEvents.post(type: String(cString: type).uppercased(), subtype: String(cString: subtype).uppercased(), fields: dictionary.values)
}

/// The drain the compiler emits between statements.
@_cdecl("basic_rt_events_drain")
public func basic_rt_events_drain(_ limit: Int) {
    RTEvents.drain(limit: limit)
}

/// Whether any handler asked for terminal input events.
@_cdecl("basic_rt_events_wants_host_input")
public func basic_rt_events_wants_host_input() -> Bool {
    RTEvents.wantsHostInput
}

/// `SecondsTimer(interval)`.
@_cdecl("basic_rt_timer_new")
public func basic_rt_timer_new(_ intervalSeconds: Double) -> UnsafeMutableRawPointer {
    let timer = RTTimer(id: RTEvents.nextTimerID, intervalSeconds: intervalSeconds)
    RTEvents.nextTimerID += 1
    RTEvents.timers[timer.id] = timer
    return rtOwned(.system(RTSystemObject(typeName: "SecondsTimer", payload: timer)))
}

/// `ON timer, ticks GOSUB handler`: the interpreter keys a timer handler by
/// the timer's id and its tick count.
@_cdecl("basic_rt_timer_on")
public func basic_rt_timer_on(_ pointer: UnsafeMutableRawPointer?, _ ticks: Double, _ handler: UnsafeMutableRawPointer, _ typeIndex: Int) {
    guard case .system(let object) = rtValue(pointer), let timer = object.payload as? RTTimer else {
        basic_rt_fail("ON TIMER requires a SecondsTimer")
    }
    let count = max(1, Int(ticks.rounded()))
    RTEvents.handlers["TIMER.\(timer.id):\(count)"] = RTEventHandler(
        trampoline: unsafeBitCast(handler, to: RTEventTrampoline.self),
        typeIndex: typeIndex
    )
}

// MARK: - Terminal event bytes

// The Shell reads its resize and mouse events out of the same stream as its
// keys: a VTG response (`ESC _VTG;…`), an SGR mouse report (`ESC [<…M`), or
// an X10 one (`ESC [M…`). `INKEY$` hands those bytes here instead of
// returning them as a key, and this posts what they mean.

enum RTTerminalEvents {
    /// The last canvas size seen, so a resize only posts when it changed.
    nonisolated(unsafe) static var canvasSize = (width: 0, height: 0)

    /// The `name=value` pairs of a VTG response.
    static func fields(of response: String) -> [String: String] {
        var payload = response
        if let start = payload.range(of: "_VTG;") { payload = String(payload[start.upperBound...]) }
        payload = payload.replacingOccurrences(of: "\u{1B}\\", with: "").replacingOccurrences(of: "\u{07}", with: "")
        var result: [String: String] = [:]
        for part in payload.split(separator: ",") {
            guard let equals = part.firstIndex(of: "=") else { continue }
            result[String(part[..<equals])] = String(part[part.index(after: equals)...])
        }
        return result
    }

    /// The Shell's mouse subtypes.
    static func mouseSubtype(_ subtype: String) -> String {
        let lowered = subtype.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered == "up" || lowered.hasSuffix("up") || lowered.contains("release") { return "up" }
        if lowered == "move" || lowered.hasSuffix("move") || lowered == "motion" || lowered == "drag" || lowered.hasSuffix("drag") { return "move" }
        if lowered == "click" || lowered.hasSuffix("click") { return "click" }
        if lowered == "scroll" || lowered.hasSuffix("scroll") { return "scroll" }
        return lowered.isEmpty ? "down" : lowered
    }

    static func vtgButton(_ value: String?) -> Int {
        guard let value else { return 0 }
        switch value.lowercased() {
        case "left", "primary", "main": return 0
        case "middle", "center": return 1
        case "right", "secondary": return 2
        default: return Int(value) ?? 0
        }
    }

    /// The Shell's button number for an ANSI report.
    static func ansiButton(_ rawButton: Int) -> Int {
        if (rawButton & 64) != 0 { return 0 }
        return rawButton & 3
    }

    /// The scroll delta an ANSI wheel report carries.
    static func scrollDelta(_ rawButton: Int) -> (x: Double, y: Double) {
        guard (rawButton & 64) != 0 else { return (0, 0) }
        switch rawButton & 3 {
        case 0: return (0, 1)
        case 1: return (0, -1)
        case 2: return (-1, 0)
        default: return (1, 0)
        }
    }

    static func postMouse(subtype: String, x: Int, y: Int, button: Int, deltaX: Double = 0, deltaY: Double = 0, hitID: String = "", target: String = "") {
        let normalized = mouseSubtype(subtype)
        let pressed = normalized == "down" || normalized == "click" || (normalized == "move" && button > 0) ? button : 0
        RTEvents.post(type: "MOUSE", subtype: normalized, fields: [
            "type": .string(RTText("MOUSE")),
            "subtype": .string(RTText(normalized.uppercased())),
            "x": .number(Double(x)),
            "y": .number(Double(y)),
            "button": .number(Double(button)),
            "buttons": .number(Double(pressed)),
            "duration": .number(0),
            "deltaX": .number(deltaX),
            "deltaY": .number(deltaY),
            "hitId": .string(RTText(hitID)),
            "target": .string(RTText(target)),
        ])
    }

    static func postResize(width: Int, height: Int) {
        RTEvents.post(type: "RESIZE", subtype: "", fields: [
            "type": .string(RTText("RESIZE")),
            "subtype": .string(RTText("")),
            "width": .number(Double(max(1, width))),
            "height": .number(Double(max(1, height))),
        ])
    }

    /// Handles one escape sequence read from the terminal. Returns the key it
    /// carried (a VTG key response), "" when it was an event and no key, or
    /// nil when these bytes are an ordinary key sequence after all.
    static func handle(_ bytes: [UInt8]) -> String? {
        guard bytes.first == 0x1b, bytes.count > 1 else { return nil }
        if bytes.count == 6, bytes[1] == UInt8(ascii: "["), bytes[2] == UInt8(ascii: "M") {
            let rawButton = Int(bytes[3]) - 32
            postANSIMouse(rawButton: rawButton, x: Int(bytes[4]) - 32, y: Int(bytes[5]) - 32, isRelease: rawButton & 3 == 3)
            return ""
        }
        guard let response = String(bytes: bytes, encoding: .utf8) else { return nil }
        if response.contains("_VTG;key") {
            let found = fields(of: response)
            let key = found["key"] ?? found["char"] ?? found["value"] ?? ""
            return key.count == 1 ? key : ""
        }
        if response.contains("_VTG;resize") || response.contains("_VTG;canvas") || response.contains("_VTG;size") {
            let found = fields(of: response)
            guard let width = found["width"].flatMap(Int.init), let height = found["height"].flatMap(Int.init) else { return "" }
            if width != canvasSize.width || height != canvasSize.height {
                canvasSize = (width, height)
                postResize(width: width, height: height)
            }
            return ""
        }
        if response.contains("_VTG;mouse") {
            let found = fields(of: response)
            guard let x = found["virtualX"].flatMap(Int.init) ?? found["x"].flatMap(Int.init),
                  let y = found["virtualY"].flatMap(Int.init) ?? found["y"].flatMap(Int.init) else { return "" }
            postMouse(
                subtype: mouseSubtype(found["type"] ?? "down"),
                x: x, y: y, button: vtgButton(found["button"]),
                deltaX: Double(found["deltaX"] ?? found["scrollX"] ?? "") ?? 0,
                deltaY: Double(found["deltaY"] ?? found["scrollY"] ?? "") ?? 0,
                hitID: found["hit"] ?? found["hitID"] ?? "",
                target: found["target"] ?? found["targetID"] ?? ""
            )
            return ""
        }
        if response.hasPrefix("\u{1B}[<"), response.hasSuffix("M") || response.hasSuffix("m") {
            let body = response.dropFirst(3).dropLast().split(separator: ";")
            guard body.count == 3, let rawButton = Int(body[0]), let x = Int(body[1]), let y = Int(body[2]) else { return "" }
            postANSIMouse(rawButton: rawButton, x: x, y: y, isRelease: response.hasSuffix("m"))
            return ""
        }
        // A VTG response this runtime has no use for is still not a key.
        if bytes.count > 1, bytes[1] == UInt8(ascii: "_") { return "" }
        return nil
    }

    private static func postANSIMouse(rawButton: Int, x: Int, y: Int, isRelease: Bool) {
        let delta = scrollDelta(rawButton)
        let subtype: String
        if (rawButton & 64) != 0 { subtype = "scroll" }
        else if (rawButton & 32) != 0 { subtype = "move" }
        else if isRelease { subtype = "up" }
        else { subtype = "down" }
        postMouse(subtype: subtype, x: x, y: y, button: ansiButton(rawButton), deltaX: delta.x, deltaY: delta.y)
    }
}
