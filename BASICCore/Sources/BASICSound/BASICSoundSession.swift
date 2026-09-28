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
/// Micro. A program waits only when a queue is full, or for a foreground
/// note to finish.
///
/// Set `BASIC_SOUND_TRACE` to a file path and every event is written there,
/// one line each, on a virtual clock. The interpreter and a compiled program
/// then write the same file, which is how their parity is tested.
public final class BASICSoundSession {
    /// GW's background queue: "as many as 32 notes (or rests)".
    public static let backgroundCapacity = 32
    /// A BBC Micro channel's queue.
    public static let channelCapacity = 4

    /// PLAY's octave, tempo and the rest, carried from string to string.
    public var music = BASICMusicState()

    private let output: BASICSoundOutput?
    private let clock: BASICSoundClock
    /// When each voice's queued notes end, oldest first. One entry a note,
    /// however many events the note takes.
    private var pending: [Int: [TimeInterval]] = [:]

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
        playGW([events])
    }

    /// BBC's `SOUND channel, amplitude, pitch, duration`.
    public func sound(channel: Double, amplitude: Double, pitch: Double, duration: Double) throws {
        let note = try BASICSoundCommand.bbc(channel: channel, amplitude: amplitude, pitch: pitch, duration: duration)
        if note.flushes { silence(voice: note.channel) }
        enqueue([[note.event]], voice: note.channel, capacity: Self.channelCapacity, waits: false)
    }

    /// `BEEP`, timed like any other GW note.
    public func beep() {
        playGW([BASICSoundCommand.beep])
    }

    /// `PLAY macro$`.
    public func play(_ macro: String, variables: BASICMusicMacro.Variables = .none) throws {
        let notes = try BASICMusicMacro.notes(for: macro, state: &music, variables: variables)
        playGW(notes)
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
        let ends = pending.values.compactMap(\.last)
        if let last = ends.max() { clock.wait(until: last) }
        pending.removeAll()
    }

    /// Stops everything, as a fresh `RUN` does.
    public func stop() {
        pending.removeAll()
        output?.stopAll()
    }

    /// Plays GW notes on voice 1, in the foreground or background as the
    /// last `MF`/`MB` said.
    private func playGW(_ notes: [[BASICSoundEvent]]) {
        enqueue(notes, voice: 1, capacity: Self.backgroundCapacity, waits: !music.isBackground)
    }

    private func enqueue(_ notes: [[BASICSoundEvent]], voice: Int, capacity: Int, waits: Bool) {
        for note in notes {
            // A full queue makes the program wait for its oldest note.
            if unfinished(voice: voice) >= capacity, let oldest = pending[voice]?.first {
                clock.wait(until: oldest)
            }
            var time = max(clock.now, pending[voice]?.last ?? 0)
            for event in note {
                output?.play(event, voice: voice, at: time)
                time += event.duration
            }
            pending[voice, default: []].append(time)
        }
        if waits, let end = pending[voice]?.last {
            clock.wait(until: end)
        }
    }

    private func silence(voice: Int) {
        pending[voice] = nil
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
        }
        write(text)
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
