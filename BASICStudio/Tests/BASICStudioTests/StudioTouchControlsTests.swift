//
//  StudioTouchControlsTests.swift
//  BASICStudioTests
//
//  The on-screen controls (BASIC-11), with made-up touches: where each one
//  sits, what a finger on it means, and the game controller events that
//  reach the program.
//

import BASICCore
import CoreGraphics
import Foundation
import Testing
@testable import BASICStudio

@Suite("On-screen touch controls")
struct StudioTouchControlsTests {
    /// A 1000 × 600 screen.
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

    /// The store, with every event and key it sends written down.
    private final class Recorder: @unchecked Sendable {
        var events: [String] = []
        var keys: [String] = []
    }

    private func store(_ controls: BASICTouchControl...) -> (StudioTouchControls, Recorder) {
        let store = StudioTouchControls()
        let recorder = Recorder()
        store.post = { subtype, control, value in
            recorder.events.append("\(subtype) \(control) \(value == value.rounded() ? String(Int(value)) : String(value))")
        }
        store.pushKey = { recorder.keys.append($0) }
        controls.forEach(store.place)
        return (store, recorder)
    }

    /// The middle of `control` on the test screen, moved by a fraction of
    /// its radius.
    private func point(_ control: BASICTouchControl, _ x: Double = 0, _ y: Double = 0) -> CGPoint {
        let frame = StudioTouchControls.frame(of: control, in: screen)
        return CGPoint(x: frame.midX + CGFloat(x) * frame.width / 2, y: frame.midY + CGFloat(y) * frame.width / 2)
    }

    private let stick = BASICTouchControl(id: "stick", kind: .joystick, anchor: .bottomRight, offsetX: 40, offsetY: 40, size: 160)
    private let fire = BASICTouchControl(id: "fire", kind: .button, anchor: .bottomLeft, offsetX: 40, offsetY: 40, size: 90, label: "FIRE", color: "#ff3b30")

    @Test("Each anchor measures its offsets in from its own side, and shifts along a centered axis")
    func anchors() {
        func frame(_ anchor: BASICTouchAnchor) -> CGRect {
            StudioTouchControls.frame(of: BASICTouchControl(id: "c", kind: .button, anchor: anchor, offsetX: 10, offsetY: 20, size: 100), in: screen)
        }
        #expect(frame(.topLeft) == CGRect(x: 10, y: 20, width: 100, height: 100))
        #expect(frame(.bottomRight) == CGRect(x: 890, y: 480, width: 100, height: 100))
        #expect(frame(.bottomLeft) == CGRect(x: 10, y: 480, width: 100, height: 100))
        #expect(frame(.topRight) == CGRect(x: 890, y: 20, width: 100, height: 100))
        #expect(frame(.left) == CGRect(x: 10, y: 270, width: 100, height: 100))
        #expect(frame(.bottom) == CGRect(x: 460, y: 480, width: 100, height: 100))
        #expect(frame(.center) == CGRect(x: 460, y: 270, width: 100, height: 100))
    }

    @Test("A finger takes the control it lands on, and nothing between them")
    func landing() {
        let (store, recorder) = store(stick, fire)
        #expect(!store.touchBegan(1, at: CGPoint(x: 500, y: 300), in: screen))
        #expect(store.control(at: point(fire), in: screen) == "fire")
        #expect(store.control(at: point(fire, 0.9, 0.9), in: screen) == nil, "outside the round button, in its square's corner")
        #expect(recorder.events.isEmpty)
    }

    @Test("A button is A while held, and its press reaches INKEY$ as a controller's does")
    func button() {
        let (store, recorder) = store(fire)
        #expect(store.touchBegan(1, at: point(fire), in: screen))
        #expect(store.state(id: "fire").held)
        store.touchEnded(1)
        #expect(!store.state(id: "fire").held)
        #expect(recorder.events == ["BUTTON A 1", "BUTTON A 0"])
        #expect(recorder.keys == ["[GP:A"])
    }

    @Test("A joystick follows the thumb, and a lean past halfway is the stick's direction pressed")
    func joystick() {
        let (store, recorder) = store(stick)
        store.touchBegan(1, at: point(stick), in: screen)
        #expect(store.state(id: "stick") == BASICTouchControlState(x: 0, y: 0, held: true))
        store.touchMoved(1, to: point(stick, -0.6, 0), in: screen)
        #expect(abs(store.state(id: "stick").x + 0.6) < 0.001)
        // Back to 0.4 still holds it, under 0.3 lets go: no flicker at the edge.
        store.touchMoved(1, to: point(stick, -0.4, 0), in: screen)
        store.touchMoved(1, to: point(stick, -0.2, 0), in: screen)
        // Past the rim it stops at the rim.
        store.touchMoved(1, to: point(stick, 0, -3), in: screen)
        #expect(abs(store.state(id: "stick").y + 1) < 0.001)
        store.touchEnded(1)
        #expect(store.state(id: "stick") == BASICTouchControlState())
        #expect(recorder.events == [
            "BUTTON LEFT_STICK_LEFT 1", "BUTTON LEFT_STICK_LEFT 0",
            "BUTTON LEFT_STICK_UP 1", "BUTTON LEFT_STICK_UP 0",
        ])
        #expect(recorder.keys == ["[GP:LEFT_STICK_LEFT", "[GP:LEFT_STICK_UP"])
    }

    @Test("A joystick kept to one axis is a paddle")
    func paddle() {
        var paddle = stick
        paddle.directions = .horizontal
        let (store, recorder) = store(paddle)
        store.touchBegan(1, at: point(paddle, 0.7, -0.7), in: screen)
        #expect(store.state(id: "stick").y == 0)
        #expect(recorder.events == ["BUTTON LEFT_STICK_RIGHT 1"])
    }

    @Test("A d-pad takes diagonals unless kept to four ways, and its middle is no direction")
    func dpad() {
        let pad = BASICTouchControl(id: "pad", kind: .dpad, anchor: .left, offsetX: 20, offsetY: 0, size: 150)
        let (store, recorder) = store(pad)
        store.touchBegan(1, at: point(pad), in: screen)
        #expect(recorder.events.isEmpty)
        store.touchMoved(1, to: point(pad, 0.6, 0.6), in: screen)
        #expect(store.state(id: "pad") == BASICTouchControlState(x: 1, y: 1, held: true))
        store.touchEnded(1)
        #expect(recorder.events == ["BUTTON DPAD_DOWN 1", "BUTTON DPAD_RIGHT 1", "BUTTON DPAD_DOWN 0", "BUTTON DPAD_RIGHT 0"])

        var fourWay = pad
        fourWay.directions = .four
        store.place(fourWay)
        recorder.events = []
        store.touchBegan(2, at: point(pad, 0.6, 0.5), in: screen)
        store.touchMoved(2, to: point(pad, 0.4, 0.6), in: screen)
        store.touchEnded(2)
        #expect(recorder.events == ["BUTTON DPAD_RIGHT 1", "BUTTON DPAD_RIGHT 0", "BUTTON DPAD_DOWN 1", "BUTTON DPAD_DOWN 0"])
    }

    @Test("A wheel reports how far it turned, clockwise positive, across the half-turn too")
    func wheel() {
        let wheel = BASICTouchControl(id: "spin", kind: .wheel, anchor: .right, offsetX: 40, offsetY: 0, size: 180)
        let (store, recorder) = store(wheel)
        store.touchBegan(1, at: point(wheel, 0.8, 0), in: screen)       // 3 o'clock
        store.touchMoved(1, to: point(wheel, 0, 0.8), in: screen)       // 6 o'clock: +90
        store.touchMoved(1, to: point(wheel, -0.8, 0.01), in: screen)   // just past 9 o'clock
        store.touchMoved(1, to: point(wheel, -0.8, -0.01), in: screen)  // across ±180, still clockwise
        #expect(abs(store.takeTurn(id: "spin") - 180) < 1.5)
        #expect(store.takeTurn(id: "spin") == 0, "read once, then it starts again")
        store.touchMoved(1, to: point(wheel, 0, -0.8), in: screen)      // 12 o'clock: another +90
        store.touchEnded(1)
        #expect(abs(store.takeTurn(id: "spin") - 90) < 1.5)
        #expect(recorder.events.count == 4)
        #expect(recorder.events.allSatisfy { $0.hasPrefix("WHEEL WHEEL ") })
    }

    @Test("Two fingers on two controls are tracked apart")
    func twoFingers() {
        let (store, recorder) = store(stick, fire)
        store.touchBegan(1, at: point(stick), in: screen)
        store.touchBegan(2, at: point(fire), in: screen)
        store.touchMoved(1, to: point(stick, 0.9, 0), in: screen)
        store.touchEnded(2)
        #expect(store.state(id: "stick").held)
        #expect(!store.state(id: "fire").held)
        store.touchEnded(1)
        #expect(recorder.events == ["BUTTON A 1", "BUTTON LEFT_STICK_RIGHT 1", "BUTTON A 0", "BUTTON LEFT_STICK_RIGHT 0"])
    }

    @Test("Removing a control lets go of the finger on it")
    func removing() {
        let (store, recorder) = store(fire)
        store.touchBegan(1, at: point(fire), in: screen)
        store.remove(id: "fire")
        store.touchEnded(1)
        #expect(store.isEmpty)
        #expect(recorder.events == ["BUTTON A 1"])
    }
}

/// The controls as a running program meets them in Studio.
@MainActor
@Suite("Touch controls in a running program", .serialized)
struct StudioTouchControlsProgramTests {
    @Test("A program's button reports through ON GAMEPAD as controller -1, and goes when the program ends")
    func throughOnGamepad() async throws {
        let studio = StudioHarness(program: """
        GLOBAL presses AS INTEGER
        touch = TouchControls()
        PRINT "available "; touch.Available
        touch.Button("fire", "BOTTOMLEFT", 40, 40, 90, "FIRE", "#ff3b30")
        ON GAMEPAD CALL Pad
        PRINT "ready"
        WHILE presses < 2
            LOCAL slept = AWAIT SLEEP(5)
        WEND
        PRINT "done"

        FUNCTION Pad(event AS BASICGamepadEvent)
            PRINT "pad"; event.Controller; " "; event.Control; event.Value
            presses = presses + 1
        END FUNCTION
        """)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)
        studio.model.runEditorProgram()
        try await studio.waitUntil("the program to place its button") { studio.model.consoleText.contains("ready") }

        // The Mac has no touch screen, and says so; the button is kept all
        // the same, and a touch on it is reported.
        #expect(studio.model.consoleText.contains("available FALSE"))
        let placed = studio.model.touchControls.snapshot().map(\.control)
        #expect(placed.map(\.id) == ["fire"])
        let frame = StudioTouchControls.frame(of: placed[0], in: screen)
        #expect(studio.model.touchControls.touchBegan(1, at: CGPoint(x: frame.midX, y: frame.midY), in: screen))
        studio.model.touchControls.touchEnded(1)

        try await studio.waitUntilStopped()
        let output = studio.model.consoleText
        #expect(output.contains("pad-1 A1"), "\(output)")
        #expect(output.contains("pad-1 A0"), "\(output)")
        #expect(output.contains("done"), "\(output)")
        #expect(studio.model.touchControls.isEmpty)
    }
}
