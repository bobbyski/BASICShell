//
//  StudioTouchControls.swift
//  BASICStudio
//
//  The on-screen controls a running program places (BASIC-11), and the
//  fingers on them: where each control sits, what a finger on it means, and
//  the game controller events that meaning becomes.
//
//  Platform-neutral on purpose. iOS draws these and feeds it touches
//  (`StudioTouchControlsView`); the Mac has no touch screen, so it keeps what
//  the program placed and never shows it — and its tests drive the same
//  tracking with made-up touches.
//

import BASICCore
import CoreGraphics
import Foundation

/// The program's on-screen controls and the fingers on them.
///
/// The interpreter places, removes and polls from its own thread; the view
/// reports touches on the main thread. A lock guards the lot, and the
/// callbacks run outside it.
final class StudioTouchControls: @unchecked Sendable {
    /// The game controller number the on-screen controls report as; real
    /// controllers count up from 0.
    static let controllerNumber = -1

    /// Whether this platform has a touch screen to put controls on.
    static var screenHasTouch: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    /// A control as the view draws it: where it is placed, and where the
    /// finger on it has put it.
    struct Drawn: Equatable {
        var control: BASICTouchControl
        var state: BASICTouchControlState
        /// A d-pad's arms that are pressed: `LEFT`, `UP`…
        var pressed: Set<String>
        /// How far a wheel has turned since it was placed, in degrees.
        var angle: Double
    }

    /// A game controller event: subtype (`BUTTON`, `WHEEL`), control name,
    /// value.
    var post: ((String, String, Double) -> Void)?
    /// A press, put where `INKEY$` reads a game controller's: `[GP:A`.
    var pushKey: ((String) -> Void)?
    /// After the program changes the controls, on the main thread.
    var onChange: (@MainActor @Sendable () -> Void)?

    private struct Live {
        var state = BASICTouchControlState()
        var pressed: Set<String> = []
        var angle: Double = 0
        var turn: Double = 0
    }

    private struct Finger {
        var controlID: String
        /// A wheel's: the angle the finger was at last, in degrees.
        var lastAngle: Double
    }

    private let lock = NSLock()
    private var controls: [BASICTouchControl] = []
    private var live: [String: Live] = [:]
    private var fingers: [Int: Finger] = [:]

    // MARK: - The program's side

    /// Shows `control`, in place of one with the same id.
    func place(_ control: BASICTouchControl) {
        lock.lock()
        if let index = controls.firstIndex(where: { $0.id == control.id }) {
            controls[index] = control
        } else {
            controls.append(control)
            live[control.id] = Live()
        }
        lock.unlock()
        changed()
    }

    func remove(id: String) {
        lock.lock()
        controls.removeAll { $0.id == id }
        live[id] = nil
        fingers = fingers.filter { $0.value.controlID != id }
        lock.unlock()
        changed()
    }

    /// Every control gone: the program asked, or it stopped.
    func clear() {
        lock.lock()
        let hadAny = !controls.isEmpty
        controls.removeAll()
        live.removeAll()
        fingers.removeAll()
        lock.unlock()
        if hadAny { changed() }
    }

    func state(id: String) -> BASICTouchControlState {
        lock.lock()
        defer { lock.unlock() }
        return live[id]?.state ?? BASICTouchControlState()
    }

    /// How far the wheel `id` has turned since this was last asked.
    func takeTurn(id: String) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let turn = live[id]?.turn ?? 0
        live[id]?.turn = 0
        return turn
    }

    /// What the view draws, bottom first.
    func snapshot() -> [Drawn] {
        lock.lock()
        defer { lock.unlock() }
        return controls.map { control in
            let now = live[control.id] ?? Live()
            return Drawn(control: control, state: now.state, pressed: now.pressed, angle: now.angle)
        }
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return controls.isEmpty
    }

    private func changed() {
        guard let onChange else { return }
        Task { @MainActor in onChange() }
    }

    // MARK: - Where they go

    /// Where `control` sits in `bounds`: `size` across, its offsets measured
    /// in from the side or corner it is anchored to; along a centered axis,
    /// a shift right or down.
    static func frame(of control: BASICTouchControl, in bounds: CGRect) -> CGRect {
        let size = CGFloat(control.size)
        let dx = CGFloat(control.offsetX)
        let dy = CGFloat(control.offsetY)
        let x: CGFloat
        switch control.anchor {
        case .topLeft, .left, .bottomLeft: x = bounds.minX + dx
        case .topRight, .right, .bottomRight: x = bounds.maxX - dx - size
        case .top, .center, .bottom: x = bounds.midX - size / 2 + dx
        }
        let y: CGFloat
        switch control.anchor {
        case .topLeft, .top, .topRight: y = bounds.minY + dy
        case .bottomLeft, .bottom, .bottomRight: y = bounds.maxY - dy - size
        case .left, .center, .right: y = bounds.midY - size / 2 + dy
        }
        return CGRect(x: x, y: y, width: size, height: size)
    }

    /// The control a finger landing at `point` takes: the last placed of
    /// those it is on, as that one is drawn on top.
    func control(at point: CGPoint, in bounds: CGRect) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return controlLocked(at: point, in: bounds)?.id
    }

    private func controlLocked(at point: CGPoint, in bounds: CGRect) -> BASICTouchControl? {
        controls.last { control in
            let frame = Self.frame(of: control, in: bounds)
            let distance = hypot(point.x - frame.midX, point.y - frame.midY)
            return distance <= frame.width / 2
        }
    }

    // MARK: - Fingers

    /// A finger down at `point`. True when it landed on a control, which
    /// then has it until it lifts.
    @discardableResult
    func touchBegan(_ finger: Int, at point: CGPoint, in bounds: CGRect) -> Bool {
        lock.lock()
        guard let control = controlLocked(at: point, in: bounds) else {
            lock.unlock()
            return false
        }
        let frame = Self.frame(of: control, in: bounds)
        fingers[finger] = Finger(controlID: control.id, lastAngle: Self.degrees(from: frame, to: point))
        var events: [Event] = []
        var now = live[control.id] ?? Live()
        now.state.held = true
        switch control.kind {
        case .button:
            events.append(Event(subtype: "BUTTON", control: control.reportsAs, value: 1))
        case .joystick:
            events = steer(control, &now, toward: point, in: frame)
        case .dpad:
            events = press(control, &now, at: point, in: frame)
        case .wheel:
            break
        }
        live[control.id] = now
        lock.unlock()
        send(events)
        return true
    }

    func touchMoved(_ finger: Int, to point: CGPoint, in bounds: CGRect) {
        lock.lock()
        guard var held = fingers[finger], let control = controls.first(where: { $0.id == held.controlID }) else {
            lock.unlock()
            return
        }
        let frame = Self.frame(of: control, in: bounds)
        var events: [Event] = []
        var now = live[control.id] ?? Live()
        switch control.kind {
        case .button:
            break
        case .joystick:
            events = steer(control, &now, toward: point, in: frame)
        case .dpad:
            events = press(control, &now, at: point, in: frame)
        case .wheel:
            let angle = Self.degrees(from: frame, to: point)
            var delta = angle - held.lastAngle
            if delta > 180 { delta -= 360 }
            if delta <= -180 { delta += 360 }
            held.lastAngle = angle
            fingers[finger] = held
            if delta != 0 {
                now.angle += delta
                now.turn += delta
                events.append(Event(subtype: "WHEEL", control: control.reportsAs, value: delta))
            }
        }
        live[control.id] = now
        lock.unlock()
        send(events)
    }

    /// A finger lifted, or the system took it away.
    func touchEnded(_ finger: Int) {
        lock.lock()
        guard let held = fingers.removeValue(forKey: finger), let control = controls.first(where: { $0.id == held.controlID }) else {
            lock.unlock()
            return
        }
        var now = live[control.id] ?? Live()
        var events: [Event] = []
        // Another finger may still be on it.
        if !fingers.values.contains(where: { $0.controlID == control.id }) {
            now.state = BASICTouchControlState()
            for direction in now.pressed.sorted() {
                events.append(Event(subtype: "BUTTON", control: control.reportsAs + "_" + direction, value: 0))
            }
            now.pressed = []
            if control.kind == .button {
                events.append(Event(subtype: "BUTTON", control: control.reportsAs, value: 0))
            }
        }
        live[control.id] = now
        lock.unlock()
        send(events)
    }

    // MARK: - What a finger means

    private struct Event {
        var subtype: String
        var control: String
        var value: Double
    }

    /// Each press is also put where `INKEY$` reads a controller's, as a real
    /// controller's is.
    private func send(_ events: [Event]) {
        for event in events {
            if event.subtype == "BUTTON", event.value > 0 { pushKey?("[GP:" + event.control) }
            post?(event.subtype, event.control, event.value)
        }
    }

    /// The finger's angle about the control's middle, in degrees, clockwise
    /// on the screen from pointing right.
    private static func degrees(from frame: CGRect, to point: CGPoint) -> Double {
        Double(atan2(point.y - frame.midY, point.x - frame.midX)) * 180 / .pi
    }

    /// Where `point` is from the middle of `frame`, as a fraction of its
    /// radius: no further than the rim.
    private static func deflection(of point: CGPoint, in frame: CGRect) -> (x: Double, y: Double) {
        let radius = Double(frame.width / 2)
        var x = Double(point.x - frame.midX) / radius
        var y = Double(point.y - frame.midY) / radius
        let length = (x * x + y * y).squareRoot()
        if length > 1 {
            x /= length
            y /= length
        }
        return (x, y)
    }

    /// A joystick follows the finger, within its directions; each direction
    /// it leans past halfway is a game controller's stick direction pressed,
    /// and released again once it is back under a third.
    private func steer(_ control: BASICTouchControl, _ now: inout Live, toward point: CGPoint, in frame: CGRect) -> [Event] {
        var (x, y) = Self.deflection(of: point, in: frame)
        switch control.directions {
        case .all: break
        case .horizontal: y = 0
        case .vertical: x = 0
        case .four:
            if abs(x) >= abs(y) { y = 0 } else { x = 0 }
        case .eight:
            let snapped = Self.eightWay(x, y)
            x = snapped.x
            y = snapped.y
        }
        now.state.x = x
        now.state.y = y
        var events: [Event] = []
        for (direction, amount) in [("LEFT", -x), ("RIGHT", x), ("UP", -y), ("DOWN", y)] {
            let isPressed = now.pressed.contains(direction)
            if !isPressed, amount >= 0.5 {
                now.pressed.insert(direction)
                events.append(Event(subtype: "BUTTON", control: control.reportsAs + "_" + direction, value: 1))
            } else if isPressed, amount < 0.3 {
                now.pressed.remove(direction)
                events.append(Event(subtype: "BUTTON", control: control.reportsAs + "_" + direction, value: 0))
            }
        }
        return events
    }

    /// Which way a d-pad is pressed: none in its middle, else the arm or arms
    /// the finger is over.
    private func press(_ control: BASICTouchControl, _ now: inout Live, at point: CGPoint, in frame: CGRect) -> [Event] {
        var (x, y) = Self.deflection(of: point, in: frame)
        if (x * x + y * y).squareRoot() < 0.25 {
            x = 0
            y = 0
        } else {
            switch control.directions {
            case .all, .eight:
                let snapped = Self.eightWay(x, y)
                x = snapped.x
                y = snapped.y
            case .four:
                if abs(x) >= abs(y) {
                    x = x < 0 ? -1 : 1
                    y = 0
                } else {
                    y = y < 0 ? -1 : 1
                    x = 0
                }
            case .horizontal:
                x = x < 0 ? -1 : 1
                y = 0
            case .vertical:
                y = y < 0 ? -1 : 1
                x = 0
            }
        }
        now.state.x = x
        now.state.y = y
        var wanted: Set<String> = []
        if x < 0 { wanted.insert("LEFT") }
        if x > 0 { wanted.insert("RIGHT") }
        if y < 0 { wanted.insert("UP") }
        if y > 0 { wanted.insert("DOWN") }
        var events: [Event] = []
        for direction in now.pressed.subtracting(wanted).sorted() {
            events.append(Event(subtype: "BUTTON", control: control.reportsAs + "_" + direction, value: 0))
        }
        for direction in wanted.subtracting(now.pressed).sorted() {
            events.append(Event(subtype: "BUTTON", control: control.reportsAs + "_" + direction, value: 1))
        }
        now.pressed = wanted
        return events
    }

    /// The nearest of eight directions, as -1, 0 or 1 on each axis; none
    /// near the middle.
    private static func eightWay(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        guard (x * x + y * y).squareRoot() >= 0.25 else { return (0, 0) }
        let sector = Int(((atan2(y, x) * 180 / .pi) + 360 + 22.5).truncatingRemainder(dividingBy: 360) / 45)
        let steps: [(Double, Double)] = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
        return steps[sector]
    }
}
