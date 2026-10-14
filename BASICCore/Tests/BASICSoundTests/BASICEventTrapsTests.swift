import Foundation
import Testing
@testable import BASICSound

/// The event-trap model both engines share (BBC_ADINS.md A14), on a clock
/// the test moves.
@Suite("Event traps")
struct BASICEventTrapsTests {
    final class Clock {
        var now: TimeInterval = 100
    }

    private func traps(_ clock: Clock) -> BASICEventTraps {
        BASICEventTraps(clock: { clock.now })
    }

    @Test("TIMER fires n seconds after TIMER ON, and every n after")
    func timerRepeats() throws {
        let clock = Clock()
        let traps = traps(clock)
        try traps.setTarget(.timer, argument: 2, target: 7)
        #expect(!traps.isWatching)
        try traps.setState(.timer, .on)
        #expect(traps.isWatching)
        clock.now = 101.9
        #expect(traps.poll(playCount: 0) == nil)
        clock.now = 102
        #expect(traps.poll(playCount: 0)?.target == 7)
        traps.release(.timer)
        clock.now = 103
        #expect(traps.poll(playCount: 0) == nil)
        clock.now = 104
        #expect(traps.poll(playCount: 0)?.event == .timer)
    }

    @Test("a trap that fires is held until its RETURN, so it never fires inside its own handler")
    func heldUntilRelease() throws {
        let clock = Clock()
        let traps = traps(clock)
        try traps.setTarget(.timer, argument: 1, target: 1)
        try traps.setState(.timer, .on)
        clock.now = 101
        #expect(traps.poll(playCount: 0) != nil)
        clock.now = 105
        #expect(traps.poll(playCount: 0) == nil, "still in the handler")
        traps.release(.timer)
        #expect(traps.poll(playCount: 0) != nil, "the event that came meanwhile fires at once")
    }

    @Test("STOP remembers an event for the next ON; OFF forgets it")
    func stopRemembersOffForgets() throws {
        let clock = Clock()
        let traps = traps(clock)
        try traps.setTarget(.key(11), argument: nil, target: 3)
        try traps.setState(.key(11), .stopped)
        #expect(traps.takeKey(named: "UP"))
        #expect(traps.poll(playCount: 0) == nil)
        try traps.setState(.key(11), .on)
        #expect(traps.poll(playCount: 0)?.event == .key(11))
        traps.release(.key(11))

        try traps.setState(.key(11), .stopped)
        #expect(traps.takeKey(named: "UP"))
        try traps.setState(.key(11), .off)
        try traps.setState(.key(11), .on)
        #expect(traps.poll(playCount: 0) == nil)
        try traps.setState(.key(11), .off)
        #expect(!traps.takeKey(named: "UP"), "a key no trap watches is left for INKEY$")
    }

    @Test("PLAY fires as the queue goes from n notes to fewer")
    func playCrossing() throws {
        let traps = traps(Clock())
        try traps.setTarget(.play, argument: 2, target: 9)
        try traps.setState(.play, .on)
        #expect(traps.poll(playCount: 3) == nil)
        #expect(traps.poll(playCount: 2) == nil)
        #expect(traps.poll(playCount: 1)?.event == .play)
        traps.release(.play)
        #expect(traps.poll(playCount: 0) == nil, "once per crossing")
        #expect(traps.poll(playCount: 5) == nil)
        #expect(traps.poll(playCount: 0)?.target == 9)
        #expect(throws: BASICSoundError.illegalFunctionCall) { try traps.setTarget(.play, argument: 33, target: 1) }
    }

    @Test("KEY 15–20 are defined by scan code; the arrows and function keys are fixed")
    func keyDefinitions() throws {
        let traps = traps(Clock())
        try traps.defineKey(15, as: "\u{0}\u{1E}")
        try traps.setTarget(.key(15), argument: nil, target: 1)
        try traps.setState(.key(15), .on)
        #expect(traps.takeKey(named: "A"))
        #expect(!traps.takeKey(named: "B"))
        #expect(BASICEventTraps.name(ofKey: 1, defined: [:]) == "F1")
        #expect(BASICEventTraps.name(ofKey: 14, defined: [:]) == "DOWN")
        #expect(BASICEventTraps.keyName(scanCode: 57) == "SPACE")
        #expect(BASICEventTraps.keyName(scanCode: 44) == "Z")
        #expect(throws: BASICSoundError.illegalFunctionCall) { try traps.defineKey(3, as: "\u{0}\u{1E}") }
        #expect(throws: BASICSoundError.illegalFunctionCall) { try traps.setState(.key(21), .on) }
    }

    @Test("GOSUB 0 turns a trap off, and STRIG, COM and PEN arm without ever firing")
    func gosubZeroAndHardware() throws {
        let clock = Clock()
        let traps = traps(clock)
        try traps.setTarget(.timer, argument: 1, target: 4)
        try traps.setState(.timer, .on)
        try traps.setTarget(.timer, argument: 1, target: nil)
        clock.now = 110
        #expect(traps.poll(playCount: 0) == nil)
        try traps.setTarget(.pen, argument: nil, target: 5)
        try traps.setState(.pen, .on)
        try traps.setState(.strig(0), .on)
        try traps.setState(.com(1), .on)
        #expect(traps.isWatching)
        #expect(traps.poll(playCount: 0) == nil)
        traps.reset()
        #expect(!traps.isWatching)
    }
}
