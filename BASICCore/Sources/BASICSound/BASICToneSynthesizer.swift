//
//  BASICToneSynthesizer.swift
//  BASICSound
//
//  Square waves on the speaker, where AVFoundation exists.
//

#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// A square-wave synthesizer for `SOUND`, `PLAY` and `BEEP`.
///
/// Square waves, because the sounds these programs were written for were
/// square waves: the PC speaker and the BBC Micro's SN76489 both made them.
/// Channel 0's noise is a linear-feedback shift register, as the SN76489's
/// was.
///
/// ```text
///   play(event, voice, at: t) ─► notes ─► AVAudioSourceNode ─► main mixer
///                                  ▲           renders frames,
///                           lock ──┘           mixing what is sounding
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

    /// Loud enough to hear, quiet enough that three voices at full volume
    /// do not clip.
    private static let gain: Float = 0.2

    private let engine = AVAudioEngine()
    private let sampleRate: Double
    private let origin: TimeInterval
    private let lock = NSLock()
    private var notes: [Note] = []
    private var renderedFrames: Int64 = 0
    private var noiseRegister: UInt16 = 0x4000

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
        let start = Int64(((time - origin) * sampleRate).rounded())
        let end = start + Int64((event.duration * sampleRate).rounded())
        let note: Note
        switch event {
        case .tone(let frequency, _, let volume):
            note = Note(voice: voice, start: start, end: end, frequency: frequency, volume: Float(volume), isNoise: false)
        case .noise(_, let volume):
            note = Note(voice: voice, start: start, end: end, frequency: 0, volume: Float(volume), isNoise: true)
        case .rest:
            return
        }
        lock.lock()
        notes.append(note)
        lock.unlock()
    }

    public func silence(voice: Int) {
        lock.lock()
        notes.removeAll { $0.voice == voice }
        lock.unlock()
    }

    public func stopAll() {
        lock.lock()
        notes.removeAll()
        lock.unlock()
    }

    /// Mixes whatever is sounding into the next `frameCount` frames.
    private func render(frameCount: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        lock.lock()
        defer { lock.unlock() }
        let first = renderedFrames
        for buffer in buffers {
            guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<frameCount {
                let position = first + Int64(frame)
                var sample: Float = 0
                for note in notes where note.start <= position && position < note.end {
                    sample += note.volume * (note.isNoise ? nextNoise() : square(note, at: position))
                }
                samples[frame] = max(-1, min(1, sample * Self.gain))
            }
        }
        renderedFrames = first + Int64(frameCount)
        notes.removeAll { $0.end <= renderedFrames }
    }

    private func square(_ note: Note, at position: Int64) -> Float {
        let phase = Double(position - note.start) * note.frequency / sampleRate
        return phase - phase.rounded(.down) < 0.5 ? 1 : -1
    }

    /// The SN76489's white noise: a 15-bit LFSR, tapped at bits 0 and 1.
    private func nextNoise() -> Float {
        let bit = (noiseRegister ^ (noiseRegister >> 1)) & 1
        noiseRegister = (noiseRegister >> 1) | (bit << 14)
        return noiseRegister & 1 == 0 ? 1 : -1
    }
}
#endif
