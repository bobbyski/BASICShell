//
//  BASICSoundSession.swift
//  BASICSound
//
//  One program's sound: its voices, their timing, and PLAY's state.
//

import Foundation

/// Where a program's notes are heard.
///
/// A host supplies one when it can make a sound: the tone synthesizer on
/// macOS, a recorder in a test. Without one, notes are still timed — a
/// program that uses `SOUND 32767, 18` as a one-second pause pauses for a
/// second either way (decision B7 in BBC_ADINS.md).
public protocol BASICSoundOutput: AnyObject {
    /// Plays `event` on `voice`, starting at `time` on the session's clock.
    func play(_ event: BASICSoundEvent, voice: Int, at time: TimeInterval)
    /// Silences `voice` and forgets anything queued on it.
    func silence(voice: Int)
    /// Silences everything.
    func stopAll()
    /// Cuts `voice` short at `time`, dropping whatever it had scheduled from
    /// then on: the next note on a channel ends the last one's release.
    func cut(voice: Int, at time: TimeInterval)
}

extension BASICSoundOutput {
    public func cut(voice: Int, at time: TimeInterval) {}
}

/// The time sound is measured against, and a way to wait on it.
public protocol BASICSoundClock: AnyObject {
    var now: TimeInterval { get }
    func wait(until time: TimeInterval)
}

/// The machine's clock: waiting really waits.
public final class BASICSystemSoundClock: BASICSoundClock {
    public init() {}

    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public func wait(until time: TimeInterval) {
        let remaining = time - now
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    }
}

/// A clock that jumps to whatever it is asked to wait for, so a test or a
/// trace gets exact, repeatable times without taking them.
public final class BASICVirtualSoundClock: BASICSoundClock {
    public private(set) var now: TimeInterval = 0

    public init() {}

    public func wait(until time: TimeInterval) {
        now = max(now, time)
    }
}

/// A program's sound, as both engines run it.
///
/// ```text
///   SOUND / PLAY / BEEP ─► events ─► voices ─► output (synthesizer, recorder,
///                                     │         trace, or none)
///                                     └─ clock: foreground waits here
/// ```
///
/// GW's statements play on voice 1, in the foreground unless a `PLAY` has
/// said `MB`, with up to 32 notes queued in the background. BBC's `SOUND`
/// plays on its own channel, always queued, four notes deep, as on a BBC
/// Micro, shaped by its `ENVELOPE` when it names one. `PLAY MIDI` has a voice
/// of its own, so a song plays alongside everything else. A program waits
/// only when a queue is full, or for a foreground note or song to finish, and
/// a break request interrupts the wait.
///
/// Set `BASIC_SOUND_TRACE` to a file path and every event is written there,
/// one line each, on a virtual clock. The interpreter and a compiled program
/// then write the same file, which is how their parity is tested.
public final class BASICSoundSession {
    /// GW's background queue: "as many as 32 notes (or rests)".
    public static let backgroundCapacity = 32
    /// A BBC Micro channel's queue.
    public static let channelCapacity = 4
    /// The voice `PLAY MIDI` songs play on, clear of GW's voice 1 and BBC's
    /// channels 0–3.
    public static let midiVoice = 16

    /// PLAY's octave, tempo and the rest, carried from string to string.
    public var music = BASICMusicState()

    /// Asked while waiting for sound: true stops the sound and ends the
    /// wait with `BASICSoundError.interrupted`. The interpreter answers
    /// with its break request.
    public var interrupted: () -> Bool = { false }

    private let output: BASICSoundOutput?
    private let clock: BASICSoundClock
    /// When each voice's queued notes end, oldest first. One entry a note,
    /// however many events the note takes.
    private var pending: [Int: [TimeInterval]] = [:]
    /// When the release still sounding on a voice ends, so the next note can
    /// cut it short.
    private var releaseEnds: [Int: TimeInterval] = [:]
    /// `ENVELOPE` 1–16, as defined; an undefined one is silent, as on a BBC.
    private var envelopes: [Int: BASICEnvelope] = [:]

    /// A session for a program's run, playing through `output` on `clock`
    /// (the system clock when nil) — or, when `BASIC_SOUND_TRACE` names a
    /// file, tracing there on a virtual clock instead.
    public static func forProgram(output: BASICSoundOutput?, clock: BASICSoundClock? = nil) -> BASICSoundSession {
        if let path = ProcessInfo.processInfo.environment["BASIC_SOUND_TRACE"], !path.isEmpty {
            return BASICSoundSession(output: BASICSoundTrace(path: path), clock: BASICVirtualSoundClock())
        }
        return BASICSoundSession(output: output, clock: clock ?? BASICSystemSoundClock())
    }

    public init(output: BASICSoundOutput?, clock: BASICSoundClock) {
        self.output = output
        self.clock = clock
    }

    /// Whether anything can be heard. Without an output, `BEEP` falls back to
    /// the terminal bell.
    public var isAudible: Bool { output != nil }

    /// GW's `SOUND freq, ticks`.
    public func sound(frequency: Double, ticks: Double) throws {
        guard let events = try BASICSoundCommand.gw(frequency: frequency, ticks: ticks) else {
            silence(voice: 1)
            return
        }
        try playGW([events])
    }

    /// BBC's `SOUND channel, amplitude, pitch, duration`.
    public func sound(channel: Double, amplitude: Double, pitch: Double, duration: Double) throws {
        let note = try BASICSoundCommand.bbc(channel: channel, amplitude: amplitude, pitch: pitch, duration: duration)
        if note.flushes { silence(voice: note.channel) }
        if let event = note.event {
            try enqueue([[event]], voice: note.channel, capacity: Self.channelCapacity, waits: false)
            return
        }
        guard case .envelope(let number) = note.loudness else { return }
        let shaped = envelopes[number].map {
            $0.shape(pitch: note.pitch, duration: note.duration, isNoise: note.channel == 0)
        } ?? (body: [.rest(duration: note.duration)], release: [])
        try enqueue([shaped.body], voice: note.channel, capacity: Self.channelCapacity, waits: false, release: shaped.release)
    }

    /// BBC's `ENVELOPE N, T, PI1, PI2, PI3, PN1, PN2, PN3, AA, AD, AS, AR, ALA, ALD`.
    public func defineEnvelope(_ parameters: [Double]) throws {
        guard parameters.count == 14, (1...16).contains(parameters[0].rounded()) else {
            throw BASICSoundError.illegalFunctionCall
        }
        envelopes[Int(parameters[0].rounded())] = try BASICEnvelope(parameters: Array(parameters.dropFirst()))
    }

    /// `PLAY MIDI`: a Standard MIDI File on its own voice, in the foreground
    /// or background as the last `MF`/`MB` said.
    public func playMIDI(data: Data, name: String) throws {
        let song = try BASICMIDIFile(data: data)
        let event = BASICSoundEvent.song(data: data, name: name, duration: song.duration)
        try enqueue([[event]], voice: Self.midiVoice, capacity: Self.backgroundCapacity, waits: !music.isBackground)
    }

    /// `PLAY MIDI STOP`: stops the song, and any queued behind it.
    public func stopMIDI() {
        silence(voice: Self.midiVoice)
    }

    /// `BEEP`, timed like any other GW note.
    public func beep() throws {
        try playGW([BASICSoundCommand.beep])
    }

    /// `PLAY macro$`.
    public func play(_ macro: String, variables: BASICMusicMacro.Variables = .none) throws {
        let notes = try BASICMusicMacro.notes(for: macro, state: &music, variables: variables)
        try playGW(notes)
    }

    /// `PLAY(n)`: notes still queued in the background; 0 in the foreground,
    /// as GW's manual says.
    public func queuedNotes() -> Int {
        guard music.isBackground else { return 0 }
        return unfinished(voice: 1)
    }

    /// Lets queued background notes play out, when a program ends.
    ///
    /// GW-BASIC keeps playing at its prompt after `END`. A program run as a
    /// command has no prompt to go back to, only an exit that would cut the
    /// music short, so both engines wait here instead.
    public func finish() {
        let ends = (pending.values.flatMap { $0 } + releaseEnds.values).filter(\.isFinite)
        if let last = ends.max() {
            do {
                try wait(until: last)
            } catch {
                return
            }
        }
        // A note played "indefinitely" stops with the program.
        let endless = Set(pending.filter { $0.value.contains { !$0.isFinite } }.keys)
            .union(releaseEnds.filter { !$0.value.isFinite }.keys)
        for voice in endless.sorted() {
            output?.silence(voice: voice)
        }
        pending.removeAll()
        releaseEnds.removeAll()
    }

    /// Stops everything, as a fresh `RUN` does.
    public func stop() {
        pending.removeAll()
        releaseEnds.removeAll()
        output?.stopAll()
    }

    /// Plays GW notes on voice 1, in the foreground or background as the
    /// last `MF`/`MB` said.
    private func playGW(_ notes: [[BASICSoundEvent]]) throws {
        try enqueue(notes, voice: 1, capacity: Self.backgroundCapacity, waits: !music.isBackground)
    }

    /// Queues `notes` on `voice`. A note's `release`, when it has one, sounds
    /// after it without holding up the queue: the next note starts when the
    /// duration ends, and cuts the release short.
    private func enqueue(
        _ notes: [[BASICSoundEvent]],
        voice: Int,
        capacity: Int,
        waits: Bool,
        release: [BASICSoundEvent] = []
    ) throws {
        for note in notes {
            // A full queue makes the program wait for its oldest note — unless
            // that note never ends, when a BBC Micro would wait forever.
            if unfinished(voice: voice) >= capacity, let oldest = pending[voice]?.first {
                guard oldest.isFinite else {
                    throw BASICSoundError("SOUND's queue is full behind a note that never ends")
                }
                try wait(until: oldest)
            }
            var time = max(clock.now, pending[voice]?.last ?? 0)
            if let releaseEnd = releaseEnds.removeValue(forKey: voice), time < releaseEnd {
                output?.cut(voice: voice, at: time)
            }
            for event in note {
                output?.play(event, voice: voice, at: time)
                time += event.duration
            }
            pending[voice, default: []].append(time)
        }
        if !release.isEmpty, var time = pending[voice]?.last, time.isFinite {
            for event in release {
                output?.play(event, voice: voice, at: time)
                time += event.duration
            }
            releaseEnds[voice] = time
        }
        if waits, let end = pending[voice]?.last, end.isFinite {
            try wait(until: end)
        }
    }

    /// Waits for the clock to reach `time`, a slice at a time on a real clock
    /// so a break request is noticed; a virtual clock simply jumps.
    private func wait(until time: TimeInterval) throws {
        guard !(clock is BASICVirtualSoundClock) else {
            clock.wait(until: time)
            return
        }
        while clock.now < time {
            if interrupted() {
                stop()
                throw BASICSoundError.interrupted
            }
            clock.wait(until: min(time, clock.now + 0.05))
        }
    }

    private func silence(voice: Int) {
        pending[voice] = nil
        releaseEnds[voice] = nil
        output?.silence(voice: voice)
    }

    /// Notes on `voice` that have not finished, dropping those that have.
    private func unfinished(voice: Int) -> Int {
        let now = clock.now
        pending[voice]?.removeAll { $0 <= now }
        return pending[voice]?.count ?? 0
    }
}

/// Writes each event to a file, one line apiece, so two runs can be compared
/// byte for byte (see `BASICSoundSession`).
final class BASICSoundTrace: BASICSoundOutput {
    private let handle: FileHandle?

    init(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    deinit {
        try? handle?.close()
    }

    func play(_ event: BASICSoundEvent, voice: Int, at time: TimeInterval) {
        let text: String
        switch event {
        case .tone(let frequency, let duration, let volume):
            text = String(format: "voice %d at %.4f: tone %.4f Hz for %.4f s, volume %.4f", voice, time, frequency, duration, volume)
        case .noise(let duration, let volume):
            text = String(format: "voice %d at %.4f: noise for %.4f s, volume %.4f", voice, time, duration, volume)
        case .rest(let duration):
            text = String(format: "voice %d at %.4f: rest for %.4f s", voice, time, duration)
        case .song(let data, let name, let duration):
            text = String(format: "voice %d at %.4f: MIDI %@ (%d bytes) for %.4f s", voice, time, name, data.count, duration)
        }
        write(text)
    }

    func cut(voice: Int, at time: TimeInterval) {
        write(String(format: "voice %d: cut at %.4f", voice, time))
    }

    func silence(voice: Int) {
        write("voice \(voice): silenced")
    }

    func stopAll() {
        write("stop")
    }

    private func write(_ line: String) {
        handle?.write(Data((line + "\n").utf8))
    }
}
