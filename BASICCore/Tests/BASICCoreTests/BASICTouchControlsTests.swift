//
//  BASICTouchControlsTests.swift
//  BASICCoreTests
//
//  `TouchControls` (BASIC-11): a program places a joystick, a d-pad, a wheel
//  and buttons on a host with a touch screen, and polls them; on a host
//  without one, every call is accepted and does nothing.
//

import Foundation
import Testing
@testable import BASICCore

/// A host with a touch screen that records what the program placed and
/// answers polls from states the test sets.
private final class TouchHost: BASICHost, BASICTouchControlsHost {
    var output: [String] = []
    var pending = ""
    var placed: [BASICTouchControl] = []
    var removed: [String] = []
    var clears = 0
    var states: [String: BASICTouchControlState] = [:]
    var turns: [String: Double] = [:]

    func print(_ text: String, terminator: String) {
        pending += text + terminator
        while let newline = pending.firstIndex(of: "\n") {
            output.append(String(pending[..<newline]))
            pending = String(pending[pending.index(after: newline)...])
        }
    }

    func printLine(_ text: String) { print(text, terminator: "\n") }
    func readLine(prompt: String) -> String? { nil }

    var touchControlsAvailable: Bool { true }
    func placeTouchControl(_ control: BASICTouchControl) { placed.append(control) }
    func removeTouchControl(id: String) { removed.append(id) }
    func clearTouchControls() { clears += 1 }
    func touchControlState(id: String) -> BASICTouchControlState { states[id] ?? BASICTouchControlState() }
    func takeTouchWheelTurn(id: String) -> Double {
        let turn = turns[id] ?? 0
        turns[id] = 0
        return turn
    }
}

@Suite("Touch controls")
struct BASICTouchControlsTests {
    private func run(_ source: String, on host: BASICHost) {
        let session = BASICSession(host: host)
        session.program.loadSource(source)
        session.submit("RUN")
    }

    @Test("Without a touch screen every call is accepted and does nothing")
    func noTouchScreen() {
        let host = TestHost()
        run("""
        touch = TouchControls()
        touch.Joystick("stick", "BOTTOMRIGHT", 40, 40, 160)
        touch.Button("fire", "BOTTOMLEFT", 40, 40, 90, "FIRE", "#ff3b30")
        touch.Directions("stick", "HORIZONTAL")
        PRINT touch.Available; touch.X("stick"); touch.Held("fire"); touch.Turn("wheel")
        touch.Remove("fire")
        touch.Clear()
        PRINT "done"
        """, on: host)
        #expect(host.output.map { $0.replacingOccurrences(of: " ", with: "") } == ["FALSE0FALSE0", "done"])
    }

    @Test("Each kind is placed with its anchor, offsets, size and the gamepad name it reports as")
    func placing() throws {
        let host = TouchHost()
        run("""
        touch = TouchControls()
        PRINT touch.Available
        touch.Joystick("stick", "bottom-right", 40, 30, 160)
        touch.DPad("pad", "LEFT", 20, 0, 150)
        touch.Wheel("spin", "BottomRight", 40, 40, 180)
        touch.Button("fire", "BOTTOMLEFT", 40, 40, 90, "FIRE", "#ff3b30")
        touch.Button("zap", "BOTTOMLEFT", 150, 80, 70, "ZAP", "#ffd60a", "b")
        touch.Joystick("aim", "TOPRIGHT", 10, 10, 120, "RIGHT_STICK")
        """, on: host)
        #expect(host.output == ["TRUE"])
        #expect(host.placed.map(\.id) == ["stick", "pad", "spin", "fire", "zap", "aim"])
        let stick = try #require(host.placed.first)
        #expect(stick == BASICTouchControl(id: "stick", kind: .joystick, anchor: .bottomRight, offsetX: 40, offsetY: 30, size: 160))
        #expect(stick.reportsAs == "LEFT_STICK")
        #expect(host.placed.map(\.kind) == [.joystick, .dpad, .wheel, .button, .button, .joystick])
        #expect(host.placed.map(\.reportsAs) == ["LEFT_STICK", "DPAD", "WHEEL", "A", "B", "RIGHT_STICK"])
        #expect(host.placed[3].label == "FIRE" && host.placed[3].color == "#ff3b30")
        #expect(host.placed[1].anchor == .left)
    }

    @Test("Directions changes a control already placed, and one placed later")
    func directions() {
        let host = TouchHost()
        run("""
        touch = TouchControls()
        touch.Joystick("paddle", "BOTTOM", 0, 30, 140)
        touch.Directions("paddle", "horizontal")
        touch.Directions("pad", "4")
        touch.DPad("pad", "BOTTOMLEFT", 30, 30, 150)
        """, on: host)
        #expect(host.placed.map(\.id) == ["paddle", "paddle", "pad"])
        #expect(host.placed.map(\.directions) == [.all, .horizontal, .four])
    }

    @Test("Polling reads the host: axes, held, and a wheel's turn since it was last read")
    func polling() {
        let host = TouchHost()
        host.states["stick"] = BASICTouchControlState(x: 0.5, y: -1, held: true)
        host.turns["spin"] = 30
        run("""
        touch = TouchControls()
        PRINT touch.X("stick"); touch.Y("stick"); touch.Held("stick"); touch.Held("fire")
        PRINT touch.Turn("spin"); touch.Turn("spin")
        """, on: host)
        #expect(host.output.map { $0.replacingOccurrences(of: " ", with: "") } == ["0.5-1TRUEFALSE", "300"])
    }

    @Test("Remove and Clear reach the host")
    func removeAndClear() {
        let host = TouchHost()
        run("""
        touch = TouchControls()
        touch.Button("fire", "BOTTOMLEFT", 40, 40, 90, "FIRE", "#ff3b30")
        touch.Remove("fire")
        touch.Clear()
        """, on: host)
        #expect(host.removed == ["fire"])
        #expect(host.clears == 1)
    }

    @Test("A place that is not on the screen, a missing argument, and an unknown member are errors")
    func errors() {
        for (line, message) in [
            ("touch.Joystick(\"s\", \"MIDDLE\", 0, 0, 100)", "MIDDLE is not a place on the screen"),
            ("touch.Button(\"f\", \"LEFT\", 0, 0, 90, \"FIRE\")", "Button expects"),
            ("touch.Joystick(\"s\", \"LEFT\", 0, 0, 0)", "size must be more than 0"),
            ("touch.Directions(\"s\", \"DIAGONAL\")", "Directions expects ALL, 4, 8"),
            ("touch.Shake()", "TouchControls has no method Shake"),
        ] {
            let host = TouchHost()
            run("touch = TouchControls()\n" + line, on: host)
            #expect(host.output.last?.contains(message) == true, "\(line): \(host.output)")
        }
    }

    @Test("A gamepad press and its release both arrive, even between two statements")
    func gamepadEventsAreNotMerged() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        let control = BASICExecutionControl()
        let pauseAtYield = BASICBreakpointLocation(lineNumber: 3, statementNumber: 0)
        control.setBreakpoints([BASICBreakpoint(location: pauseAtYield)])
        session.program.loadSource("""
        on gamepad button call Pressed
        print "ready"
        yield
        print "done"

        function Pressed(event as BASICGamepadEvent)
            print event.Control + str$(event.Value)
        end function
        """)
        do {
            try session.runProgram(executionControl: control)
            Issue.record("Expected breakpoint before event drain")
        } catch BASICError.breakpoint(let location) {
            #expect(location == pauseAtYield)
        }
        session.postGamepadEvent(subtype: "button", controller: -1, control: "A", value: 1)
        session.postGamepadEvent(subtype: "button", controller: -1, control: "A", value: 0)
        control.ignoreBreakpointOnce(at: pauseAtYield)
        try session.continueProgram(executionControl: control)
        #expect(host.output == ["ready", "A 1", "A 0", "done"])
    }
}
