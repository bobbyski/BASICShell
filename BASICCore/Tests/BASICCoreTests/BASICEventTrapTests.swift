import Foundation
import Testing
@testable import BASICCore

/// GW-BASIC's event traps in the interpreter (BBC_ADINS.md A14): `ON TIMER`,
/// `ON KEY`, `ON PLAY`, and the hardware ones that never fire. The model's
/// own rules are `BASICEventTrapsTests`'; these hold the interpreter to
/// polling it where GW does and to GOSUB-ing as it says.
@Suite("Event trapping", .serialized)
struct BASICEventTrapTests {
    private func run(_ source: String, keys: [String] = [], sound: BASICSoundOutput? = nil,
                     clock: BASICSoundClock? = nil) -> [String] {
        let host = TestHost()
        host.keys = keys
        host.soundOutput = sound
        host.soundClock = clock
        let session = BASICSession(host: host)
        session.program.loadSource(source)
        session.submit("RUN")
        return host.output
    }

    @Test("ON TIMER(n) GOSUB fires every n seconds after TIMER ON, returning to the line it interrupted")
    func timerTicks() {
        let output = run("""
        10 ON TIMER(0.01) GOSUB 100
        20 TIMER ON: S = TIMER()
        30 IF N < 3 AND TIMER() - S < 2 THEN 30
        40 PRINT "done"; N
        50 END
        100 N = N + 1: PRINT "tick"; N
        110 RETURN
        """)
        #expect(output == ["tick1", "tick2", "tick3", "done3"])
    }

    @Test("a handler is never entered again while it runs; OFF inside it stays off")
    func noRecursionAndOffSticks() {
        let output = run("""
        10 ON TIMER(0.01) GOSUB 100
        20 TIMER ON: T0 = TIMER()
        30 IF N < 1 AND TIMER() < 2 + T0 THEN 30
        40 T = TIMER()
        50 IF TIMER() - T < 0.05 THEN 50
        60 PRINT "deepest"; MAXDEPTH; "times"; N
        70 END
        100 DEPTH = DEPTH + 1: N = N + 1
        110 IF DEPTH > MAXDEPTH THEN MAXDEPTH = DEPTH
        120 S = TIMER()
        130 IF TIMER() - S < 0.03 THEN 130
        140 TIMER OFF
        150 DEPTH = DEPTH - 1
        160 RETURN
        """)
        #expect(output == ["deepest1times1"])
    }

    @Test("TIMER STOP remembers a tick, which fires as soon as TIMER ON")
    func stopRemembers() {
        let output = run("""
        10 ON TIMER(0.01) GOSUB 100
        20 TIMER STOP
        30 T = TIMER()
        40 IF TIMER() - T < 0.03 THEN 40
        50 PRINT "before"; N
        60 TIMER ON
        70 PRINT "after"; N
        80 END
        100 N = N + 1: TIMER OFF: RETURN
        """)
        #expect(output == ["before0", "after1"])
    }

    @Test("ON TIMER(n) GOSUB label is GW's trap; with a FUNCTION it stays a SecondsTimer's handler")
    func timerLabelForm() {
        let output = run("""
        ON TIMER(0.01) GOSUB Tick
        TIMER ON
        S = TIMER()
        WHILE N < 2 AND TIMER() - S < 2
        WEND
        PRINT "ticks"; N
        END
        Tick:
        N = N + 1
        RETURN
        """)
        #expect(output == ["ticks2"])
    }

    @Test("ON KEY(n) takes the key before INKEY$ does, and leaves the rest")
    func keyTrap() {
        let output = run("""
        10 ON KEY(11) GOSUB 100
        20 KEY(11) ON
        25 S = TIMER()
        30 A$ = INKEY$: IF A$ = "" AND TIMER() - S < 2 THEN 30
        40 B$ = INKEY$: IF B$ = "" AND TIMER() - S < 2 THEN 40
        50 PRINT A$; B$; HITS
        60 END
        100 HITS = HITS + 1: RETURN
        """, keys: ["x", "\u{1B}[A", "y"])
        #expect(output == ["xy1"])
    }

    @Test("KEY 15–20 are defined by scan code, as GW's KEY n, CHR$(shift) + CHR$(code)")
    func definedKey() {
        let output = run("""
        10 KEY 15, CHR$(0) + CHR$(30)
        20 ON KEY(15) GOSUB 100
        30 KEY(15) ON
        35 S = TIMER()
        40 IF HITS = 0 AND TIMER() - S < 2 THEN 40
        50 PRINT "A pressed"; HITS; INKEY$
        60 END
        100 HITS = HITS + 1: RETURN
        """, keys: ["a"])
        #expect(output == ["A pressed1"])
    }

    @Test("ON PLAY(n) fires as the background queue drains below n")
    func playTrap() {
        let output = run("""
        10 ON PLAY(2) GOSUB 100
        20 PLAY ON
        30 PLAY "MB L16 CDE"
        40 PRINT "queued"
        50 PLAY "MF L64 P64"
        60 PRINT "after"; FIRED
        70 END
        100 FIRED = FIRED + 1: RETURN
        """, sound: SilentRecorder(), clock: BASICVirtualSoundClock())
        #expect(output == ["queued", "after1"])
    }

    @Test("an ON ERROR handler holds every trap until RESUME, and a FUNCTION holds them until it returns")
    func errorAndFunctionHold() {
        let output = run("""
        10 ON ERROR GOTO 900
        20 ON TIMER(0.01) GOSUB 800
        30 TIMER ON
        40 ERROR 5
        50 PRINT "in handler"; INHANDLER
        60 X = Busy()
        70 PRINT "in function"; INFUNCTION
        75 S = TIMER()
        80 IF N = 0 AND TIMER() - S < 2 THEN 80
        90 END
        800 N = N + 1: RETURN
        900 T = TIMER(): H0 = N
        910 IF TIMER() - T < 0.03 THEN 910
        920 INHANDLER = N - H0
        930 RESUME NEXT
        FUNCTION Busy() AS DOUBLE
          LOCAL S = TIMER()
          LOCAL N0 = N
          WHILE TIMER() - S < 0.03
          WEND
          INFUNCTION = N - N0
          RETURN 0
        END FUNCTION
        """)
        #expect(output == ["in handler0", "in function0"])
    }

    @Test("STRIG, COM and PEN arm and never fire; KEY ON/OFF and STRIG ON/OFF do nothing; GOSUB 0 turns a trap off")
    func hardwareAndNoOps() {
        let output = run("""
        10 KEY OFF: STRIG ON
        20 ON PEN GOSUB 100: PEN ON
        30 ON STRIG(0) GOSUB 100: STRIG(0) ON
        40 ON COM(1) GOSUB 100: COM(1) ON
        50 ON TIMER(0.01) GOSUB 100: TIMER ON
        60 ON TIMER(0.01) GOSUB 0
        70 T = TIMER()
        80 IF TIMER() - T < 0.03 THEN 80
        90 PRINT "fired"; N: END
        100 N = N + 1: RETURN
        """)
        #expect(output == ["fired0"])
        #expect(run("KEY LIST").joined().contains("KEY LIST is not supported"))
        #expect(run("COM ON").joined().contains("Expected (n) after COM"))
        #expect(run("ON KEY(21) GOSUB 10\n10 END").joined().contains("Illegal function call"))
    }

    @Test("a variable or array named KEY, PEN or COM is still one")
    func namesStayNames() {
        #expect(run("KEY = 3: PEN = 4: DIM COM(2): COM(1) = 5: PRINT KEY; PEN; COM(1)") == ["345"])
    }
}

/// Plays nothing, so `PLAY` has somewhere to go.
private final class SilentRecorder: BASICSoundOutput {
    func play(_ event: BASICSoundEvent, voice: Int, at time: TimeInterval) {}
    func silence(voice: Int) {}
    func stopAll() {}
}
