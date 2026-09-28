import Foundation
import Testing
@testable import BASICSound

/// Remembers what it was asked to play, and when.
final class RecordingOutput: BASICSoundOutput {
    var played: [(event: BASICSoundEvent, voice: Int, time: TimeInterval)] = []
    var silenced: [Int] = []

    func play(_ event: BASICSoundEvent, voice: Int, at time: TimeInterval) {
        played.append((event, voice, time))
    }

    func silence(voice: Int) { silenced.append(voice) }

    func stopAll() {}

    var tones: [Double] {
        played.compactMap { if case .tone(let frequency, _, _) = $0.event { return frequency } else { return nil } }
    }
}

/// Frequencies are compared to the cent, not the bit.
private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.01 }

@Suite("SOUND and BEEP")
struct BASICSoundCommandTests {
    @Test("GW's SOUND is Hz and ticks at 18.2 a second, with 32767 a rest and 0 a stop")
    func gwSound() throws {
        #expect(try BASICSoundCommand.gw(frequency: 440, ticks: 18.2) == [.tone(frequency: 440, duration: 1, volume: 1)])
        #expect(try BASICSoundCommand.gw(frequency: 32767, ticks: 9.1) == [.rest(duration: 0.5)])
        #expect(try BASICSoundCommand.gw(frequency: 440, ticks: 0) == nil)
        #expect(throws: BASICSoundError.illegalFunctionCall) { try BASICSoundCommand.gw(frequency: 36, ticks: 1) }
        #expect(throws: BASICSoundError.illegalFunctionCall) { try BASICSoundCommand.gw(frequency: 440, ticks: 65536) }
    }

    @Test("BBC's pitch is quarter semitones from 53, middle C; amplitude -15 is loudest")
    func bbcSound() throws {
        let middleC = try BASICSoundCommand.bbc(channel: 1, amplitude: -15, pitch: 53, duration: 20)
        #expect(middleC.channel == 1 && !middleC.flushes)
        guard case .tone(let c, let seconds, let loud) = middleC.event else { Issue.record("not a tone"); return }
        #expect(close(c, 261.63) && seconds == 1 && loud == 1)
        let a440 = try BASICSoundCommand.bbc(channel: 17, amplitude: -3, pitch: 89, duration: 10)
        #expect(a440.channel == 1 && a440.flushes)
        guard case .tone(let a, _, let quiet) = a440.event else { Issue.record("not a tone"); return }
        #expect(close(a, 440) && close(quiet, 0.2))
        #expect(try BASICSoundCommand.bbc(channel: 0, amplitude: -15, pitch: 4, duration: 5).event == .noise(duration: 0.25, volume: 1))
        #expect(throws: BASICSoundError.illegalFunctionCall) { try BASICSoundCommand.bbc(channel: 4, amplitude: 0, pitch: 0, duration: 1) }
        #expect(throws: BASICSoundError.illegalFunctionCall) { try BASICSoundCommand.bbc(channel: 1, amplitude: -16, pitch: 0, duration: 1) }
        #expect(throws: BASICSoundError.illegalFunctionCall) { try BASICSoundCommand.bbc(channel: 1, amplitude: 0, pitch: 0, duration: 255) }
        #expect(try BASICSoundCommand.bbc(channel: 1, amplitude: 0, pitch: 53, duration: -1).event.duration == .infinity)
    }

    @Test("BEEP is 800 Hz for a quarter second")
    func beep() {
        #expect(BASICSoundCommand.beep == [.tone(frequency: 800, duration: 0.25, volume: 1)])
    }
}

@Suite("PLAY's music macro language")
struct BASICMusicMacroTests {
    private func notes(_ macro: String, _ state: inout BASICMusicState) throws -> [[BASICSoundEvent]] {
        try BASICMusicMacro.notes(for: macro, state: &state)
    }

    private func frequencies(_ macro: String) throws -> [Double] {
        var state = BASICMusicState()
        return try notes(macro, &state).flatMap { $0 }.compactMap {
            if case .tone(let frequency, _, _) = $0 { return frequency } else { return nil }
        }
    }

    @Test("PC-BASIC's pitch: A440 is O2 A, and the default octave is 4")
    func pitch() throws {
        let tones = try frequencies("O2 A C > C < < C")
        #expect(close(tones[0], 440) && close(tones[1], 261.63) && close(tones[2], 523.25) && close(tones[3], 130.81))
        let defaultOctave = try frequencies("C")[0]
        let byNumber = try frequencies("N34 N25")
        #expect(close(defaultOctave, 1046.50))
        #expect(close(byNumber[0], 440) && close(byNumber[1], 261.63))
    }

    @Test("sharps and flats name black keys only")
    func accidentals() throws {
        let tones = try frequencies("O2 C# D- D+ E- B-")
        #expect(close(tones[0], tones[1]) && close(tones[2], 311.13) && close(tones[3], 311.13) && close(tones[4], 466.16))
        for bad in ["E#", "C-", "B+", "F-"] {
            #expect(throws: BASICSoundError.illegalFunctionCall, "\(bad)") { try frequencies(bad) }
        }
    }

    @Test("length, tempo, dots and articulation set the time")
    func timing() throws {
        var state = BASICMusicState()
        // T120: a quarter note is half a second, and MN sounds 7/8 of it.
        #expect(try notes("A", &state) == [[.tone(frequency: 1760, duration: 0.4375, volume: 1), .rest(duration: 0.0625)]])
        #expect(try notes("ML L8 A.", &state).first?.first?.duration == 0.375)
        #expect(try notes("MS T60 A2", &state).first == [.tone(frequency: 1760, duration: 1.5, volume: 1), .rest(duration: 0.5)])
        #expect(try notes("P4 N0", &state) == [[.rest(duration: 1)], [.rest(duration: 0.5)]])
        #expect(state.tempo == 60 && state.length == 8 && state.fill == 0.75)
    }

    @Test("MB and MF switch background, and a note stays one note")
    func backgroundFlag() throws {
        var state = BASICMusicState()
        #expect(try notes("MB C D", &state).count == 2)
        #expect(state.isBackground)
        _ = try notes("MF", &state)
        #expect(!state.isBackground)
    }

    @Test("=name; and X name; read the program's variables")
    func variables() throws {
        var state = BASICMusicState()
        let variables = BASICMusicMacro.Variables(
            number: { $0 == "O" ? 2 : nil },
            text: { $0 == "TUNE$" ? "A" : nil }
        )
        let played = try BASICMusicMacro.notes(for: "O=O; X tune$;", state: &state, variables: variables)
        guard case .tone(let frequency, _, _)? = played.first?.first else { Issue.record("no note"); return }
        #expect(close(frequency, 440))
        #expect(throws: BASICSoundError.illegalFunctionCall) { try BASICMusicMacro.notes(for: "O=MISSING;", state: &state, variables: variables) }
    }

    @Test("an X that names itself stops rather than recursing forever")
    func selfReferenceIsBounded() {
        var state = BASICMusicState()
        let loop = BASICMusicMacro.Variables(number: { _ in nil }, text: { _ in "X L$;" })
        #expect(throws: BASICSoundError.illegalFunctionCall) { try BASICMusicMacro.notes(for: "X L$;", state: &state, variables: loop) }
    }

    @Test("anything out of range, or not a command, is Illegal function call")
    func ranges() {
        for bad in ["O7", "L0", "L65", "T31", "T256", "P0", "N85", "MQ", "Z", "A65"] {
            #expect(throws: BASICSoundError.illegalFunctionCall, "\(bad)") { try frequencies(bad) }
        }
    }
}

@Suite("Sound timing")
struct BASICSoundSessionTests {
    private func session() -> (BASICSoundSession, RecordingOutput, BASICVirtualSoundClock) {
        let output = RecordingOutput()
        let clock = BASICVirtualSoundClock()
        return (BASICSoundSession(output: output, clock: clock), output, clock)
    }

    @Test("a foreground note is waited for, one after another")
    func foregroundWaits() throws {
        let (sound, output, clock) = session()
        try sound.sound(frequency: 440, ticks: 18.2)
        try sound.sound(frequency: 880, ticks: 9.1)
        #expect(clock.now == 1.5)
        #expect(output.played.map(\.time) == [0, 1])
    }

    @Test("MB queues notes and PLAY(n) counts them, 0 in the foreground")
    func backgroundCounts() throws {
        let (sound, _, clock) = session()
        try sound.play("MB CDE")
        #expect(clock.now == 0)
        #expect(sound.queuedNotes() == 3)
        clock.wait(until: 0.6)
        #expect(sound.queuedNotes() == 2)
        try sound.play("MF")
        #expect(sound.queuedNotes() == 0)
    }

    @Test("a full background queue waits for its oldest note")
    func backgroundCapacity() throws {
        let (sound, _, clock) = session()
        try sound.play("MB " + String(repeating: "C", count: 33))
        #expect(clock.now == 0.5)
    }

    @Test("BBC channels queue four deep and play side by side")
    func bbcChannels() throws {
        let (sound, output, clock) = session()
        for _ in 0..<5 { try sound.sound(channel: 1, amplitude: -15, pitch: 53, duration: 20) }
        try sound.sound(channel: 2, amplitude: -15, pitch: 89, duration: 20)
        #expect(clock.now == 1)
        #expect(output.played.last?.voice == 2 && output.played.last?.time == 1)
        try sound.sound(channel: 17, amplitude: -15, pitch: 53, duration: 20)
        #expect(output.silenced == [1])
    }

    @Test("a note played indefinitely holds its channel until it is flushed, and stops at the end")
    func indefiniteNotes() throws {
        let (sound, output, clock) = session()
        try sound.sound(channel: 1, amplitude: -15, pitch: 53, duration: -1)
        for _ in 0..<3 { try sound.sound(channel: 1, amplitude: -15, pitch: 53, duration: 20) }
        #expect(throws: BASICSoundError.self) { try sound.sound(channel: 1, amplitude: -15, pitch: 53, duration: 20) }
        try sound.sound(channel: 17, amplitude: -15, pitch: 53, duration: -1)
        sound.finish()
        #expect(clock.now == 0)
        #expect(output.silenced == [1, 1])
    }

    @Test("finish lets background notes play out")
    func finishWaits() throws {
        let (sound, _, clock) = session()
        try sound.play("MB CDEF")
        sound.finish()
        #expect(clock.now == 2)
    }

    @Test("with no output the timing is kept anyway")
    func silentButTimed() throws {
        let clock = BASICVirtualSoundClock()
        let sound = BASICSoundSession(output: nil, clock: clock)
        try sound.sound(frequency: 32767, ticks: 18.2)
        #expect(clock.now == 1)
        #expect(!sound.isAudible)
    }
}
