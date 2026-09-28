import Foundation
import Testing
@testable import BASICCore

/// Remembers the notes a program played.
private final class NoteRecorder: BASICSoundOutput {
    var played: [(event: BASICSoundEvent, voice: Int)] = []
    func play(_ event: BASICSoundEvent, voice: Int, at time: TimeInterval) { played.append((event, voice)) }
    func silence(voice: Int) {}
    func stopAll() {}
}

/// `SOUND`, `PLAY`, `PLAY(n)` and `BEEP` as statements (BBC_ADINS.md A8, A9).
/// The rules themselves are BASICSoundTests'; these hold the interpreter to
/// handing them the right arguments and reporting their errors.
@Suite("SOUND, PLAY and BEEP statements")
struct BASICSoundStatementTests {
    private func run(_ source: String, output: NoteRecorder? = nil) -> (lines: [String], clock: BASICVirtualSoundClock) {
        let host = TestHost()
        let clock = BASICVirtualSoundClock()
        host.soundOutput = output
        host.soundClock = clock
        let session = BASICSession(host: host)
        session.program.loadSource(source)
        session.submit("RUN")
        return (host.output, clock)
    }

    @Test("SOUND with two numbers is GW's, with four is BBC's")
    func soundArity() {
        let recorder = NoteRecorder()
        let result = run("SOUND 440, 18.2\nSOUND 2, -15, 89, 20", output: recorder)
        #expect(recorder.played.count == 2)
        #expect(recorder.played.map(\.voice) == [1, 2])
        // GW's note is waited for; BBC's is queued, and plays out at the end.
        #expect(result.clock.now == 2)
    }

    @Test("SOUND with three numbers is a syntax error")
    func soundWrongArity() {
        #expect(run("SOUND 1, 2, 3").lines.joined().contains("SOUND takes two numbers"))
    }

    @Test("PLAY reads =name; and X name; from the program's variables")
    func playReadsVariables() {
        let recorder = NoteRecorder()
        _ = run("O = 2: TUNE$ = \"A\"\nPLAY \"O=O; X TUNE$;\"", output: recorder)
        guard case .tone(let frequency, _, _)? = recorder.played.first?.event else {
            Issue.record("no note played")
            return
        }
        #expect(abs(frequency - 440) < 0.01)
    }

    @Test("PLAY(n) counts the background queue")
    func playCount() {
        #expect(run("PLAY \"MB CDE\"\nPRINT PLAY(0)", output: NoteRecorder()).lines == ["3"])
        #expect(run("PRINT PLAY(0)").lines == ["0"])
    }

    @Test("a refused note is Illegal function call, which ON ERROR traps as ERR 5")
    func refusedNotesAreTrappable() {
        let lines = run("""
        10 ON ERROR GOTO 100
        20 PLAY "E#"
        30 SOUND 20, 1
        40 END
        100 PRINT "ERR"; ERR; "ERL"; ERL
        110 RESUME NEXT
        """).lines
        #expect(lines == ["ERR5ERL20", "ERR5ERL30"])
    }

    @Test("BEEP rings the terminal bell when nothing can be heard, and plays when something can")
    func beepFallsBackToTheBell() {
        let silent = run("BEEP: PRINT \"after\"")
        #expect(silent.lines.joined().contains("\u{07}"))
        let recorder = NoteRecorder()
        let audible = run("BEEP: PRINT \"after\"", output: recorder)
        #expect(!audible.lines.joined().contains("\u{07}"))
        #expect(recorder.played.first?.event == .tone(frequency: 800, duration: 0.25, volume: 1))
    }

    @Test("ON PLAY and PLAY ON, OFF and STOP are refused by name")
    func eventFormsAreRefused() {
        #expect(run("ON PLAY(2) GOSUB 100").lines.joined().contains("ON PLAY is not supported yet"))
        #expect(run("PLAY ON").lines.joined().contains("PLAY ON, OFF and STOP are not supported yet"))
    }

    @Test("background music plays out when the program ends")
    func backgroundFinishes() {
        #expect(run("PLAY \"MB CDEF\"", output: NoteRecorder()).clock.now == 2)
    }
}
