//
//  BASICToneSynthesizer.swift
//  BASICSound
//
//  Square waves and MIDI songs on the speaker, where AVFoundation exists.
//

#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// The speaker, for `SOUND`, `PLAY`, `BEEP` and `PLAY MIDI`.
///
/// Notes are square waves, because the sounds these programs were written
/// for were square waves: the PC speaker and the BBC Micro's SN76489 both made
/// them. Channel 0's noise is a linear-feedback shift register, as the
/// SN76489's was. Songs are different: `PLAY MIDI` plays a Standard MIDI File
/// through `AVMIDIPlayer` and the system's General MIDI instruments.
///
/// ```text
///   play(tone, voice, at: t) ─► notes ─► AVAudioSourceNode ─► main mixer
///                                 ▲        renders frames; each voice keeps
///                          lock ──┘        its phase, so an envelope's steps
///                                          join without a click
///   play(song, voice, at: t) ─► AVMIDIPlayer, started at t
/// ```
///
/// Times are on `BASICSystemSoundClock`'s clock (system uptime). Frame 0 is
/// the moment the synthesizer started, so a note scheduled for now starts at
/// the next buffer.
///
/// There is one per process, started on first use. `shared` is nil where
/// there is no audio device, and a host then keeps timing without sound.
public final class BASICToneSynthesizer: BASICSoundOutput, @unchecked Sendable {
    /// The process's synthesizer, or nil when audio cannot start.
    public static let shared: BASICToneSynthesizer? = BASICToneSynthesizer()

    private struct Note {
        var voice: Int
        var start: Int64
        var end: Int64
        var frequency: Double
        var volume: Float
        var isNoise: Bool
    }

    /// A song and the voice it plays on, kept so it can be stopped.
    private struct Song {
        var voice: Int
        var player: AVMIDIPlayer
    }

    /// Loud enough to hear, quiet enough that three voices at full volume
    /// do not clip.
    private static let gain: Float = 0.2

    private let engine = AVAudioEngine()
    private let sampleRate: Double
    private let origin: TimeInterval
    private let lock = NSLock()
    private var notes: [Note] = []
    /// Where each voice's square wave is in its cycle, 0..<1.
    private var phases: [Int: Double] = [:]
    private var renderedFrames: Int64 = 0
    private var noiseRegister: UInt16 = 0x4000
    private var songs: [Int: Song] = [:]
    private var nextSongID = 0

    private init?() {
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        sampleRate = hardware.sampleRate > 0 ? hardware.sampleRate : 44_100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        origin = ProcessInfo.processInfo.systemUptime
        let source = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList -> OSStatus in
            self.render(frameCount: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(bufferList))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            return nil
        }
    }

    public func play(_ event: BASICSoundEvent, voice: Int, at time: TimeInterval) {
        let start = frame(at: time)
        // "Play indefinitely" lasts until the voice is silenced or cut.
        let end = event.duration.isFinite ? start + Int64((event.duration * sampleRate).rounded()) : Int64.max
        let note: Note
        switch event {
        case .tone(let frequency, _, let volume):
            note = Note(voice: voice, start: start, end: end, frequency: frequency, volume: Float(volume), isNoise: false)
        case .noise(_, let volume):
            note = Note(voice: voice, start: start, end: end, frequency: 0, volume: Float(volume), isNoise: true)
        case .rest:
            return
        case .song(let data, _, _):
            startSong(data, voice: voice, at: time)
            return
        }
        lock.lock()
        notes.append(note)
        lock.unlock()
    }

    public func silence(voice: Int) {
        lock.lock()
        notes.removeAll { $0.voice == voice }
        let stopping = songs.filter { $0.value.voice == voice }
        songs = songs.filter { $0.value.voice != voice }
        lock.unlock()
        stopping.values.forEach { $0.player.stop() }
    }

    public func stopAll() {
        lock.lock()
        notes.removeAll()
        let stopping = songs
        songs.removeAll()
        lock.unlock()
        stopping.values.forEach { $0.player.stop() }
    }

    public func cut(voice: Int, at time: TimeInterval) {
        let cutFrame = frame(at: time)
        lock.lock()
        notes.removeAll { $0.voice == voice && $0.start >= cutFrame }
        for index in notes.indices where notes[index].voice == voice && notes[index].end > cutFrame {
            notes[index].end = cutFrame
        }
        lock.unlock()
    }

    private func frame(at time: TimeInterval) -> Int64 {
        Int64(((time - origin) * sampleRate).rounded())
    }

    /// Loads a song now and starts it at `time`. A song silenced before it
    /// starts is dropped from `songs`, so its start finds nothing to play.
    private func startSong(_ data: Data, voice: Int, at time: TimeInterval) {
        guard let player = try? AVMIDIPlayer(data: data, soundBankURL: nil) else { return }
        player.prepareToPlay()
        lock.lock()
        let id = nextSongID
        nextSongID += 1
        songs[id] = Song(voice: voice, player: player)
        lock.unlock()
        let delay = max(0, time - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            lock.lock()
            let song = songs[id]
            lock.unlock()
            song?.player.play { [self] in
                lock.lock()
                songs[id] = nil
                lock.unlock()
            }
        }
    }

    /// Mixes whatever is sounding into the next `frameCount` frames.
    private func render(frameCount: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        lock.lock()
        defer { lock.unlock() }
        let first = renderedFrames
        guard let samples = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        for frame in 0..<frameCount {
            let position = first + Int64(frame)
            var sample: Float = 0
            for note in notes where note.start <= position && position < note.end {
                sample += note.volume * (note.isNoise ? nextNoise() : square(note))
            }
            samples[frame] = max(-1, min(1, sample * Self.gain))
        }
        for buffer in buffers.dropFirst() {
            buffer.mData?.copyMemory(from: samples, byteCount: Int(buffer.mDataByteSize))
        }
        renderedFrames = first + Int64(frameCount)
        notes.removeAll { $0.end <= renderedFrames }
    }

    /// The next sample of `note`'s square wave, advancing its voice's phase:
    /// one phase a voice, so consecutive steps of an envelope join smoothly.
    private func square(_ note: Note) -> Float {
        var phase = phases[note.voice, default: 0] + note.frequency / sampleRate
        phase -= phase.rounded(.down)
        phases[note.voice] = phase
        return phase < 0.5 ? 1 : -1
    }

    /// The SN76489's white noise: a 15-bit LFSR, tapped at bits 0 and 1.
    private func nextNoise() -> Float {
        let bit = (noiseRegister ^ (noiseRegister >> 1)) & 1
        noiseRegister = (noiseRegister >> 1) | (bit << 14)
        return noiseRegister & 1 == 0 ? 1 : -1
    }
}
#endif
