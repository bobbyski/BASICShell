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
/// the next buffer; `BASICSoundTimeline` keeps that so after the engine has
/// been stopped.
///
/// iPhone and iPad stop the engine when the app is suspended or its audio is
/// interrupted, and a change of output (headphones, a Bluetooth speaker)
/// stops it anywhere. It is started again before the next note, and as soon
/// as the system says the interruption or the change is over (BASIC-26).
///
/// There is one per process, started on first use. `shared` is nil where
/// there is no audio device, where `SOUND` and `PLAY` are Device unavailable.
public final class BASICToneSynthesizer: BASICSoundOutput, @unchecked Sendable {
    /// The process's synthesizer, or nil when audio cannot start.
    public static let shared: BASICToneSynthesizer? = BASICToneSynthesizer()

    private typealias Note = BASICPCMNote

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
    private var timeline: BASICSoundTimeline
    private var observers: [NSObjectProtocol] = []
    private let lock = NSLock()
    private var notes: [Note] = []
    /// Where each voice's square wave is in its cycle, 0..<1.
    private let renderer=BASICPCMRenderer()
    private var renderedFrames: Int64 = 0
    private var songs: [Int: Song] = [:]
    private var nextSongID = 0

    private init?() {
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        sampleRate = hardware.sampleRate > 0 ? hardware.sampleRate : 44_100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return nil }
        timeline = BASICSoundTimeline(sampleRate: sampleRate, origin: ProcessInfo.processInfo.systemUptime)
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
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.restartIfStopped()
        })
        #if os(iOS) || os(tvOS) || os(visionOS)
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.restartIfStopped()
        })
        #endif
    }

    /// Starts the engine again if the system has stopped it. Nothing else
    /// does, and a stopped engine plays nothing until the app is relaunched.
    private func restartIfStopped() {
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    /// Why `PLAY MIDI` cannot play `data` here, or nil when it can, so the
    /// program is told rather than left in silence. iPhone and iPad have no
    /// General MIDI instruments of their own to play a song with.
    public func reasonSongCannotPlay(_ data: Data) -> String? {
        do {
            _ = try AVMIDIPlayer(data: data, soundBankURL: nil)
            return nil
        } catch {
            #if os(macOS)
            return "PLAY MIDI could not play the song: \(error.localizedDescription)"
            #else
            return "PLAY MIDI needs General MIDI instruments, which this device does not have"
            #endif
        }
    }

    public func play(_ event: BASICSoundEvent, voice: Int, at time: TimeInterval) {
        play(event,voice:voice,at:time,noiseProfile:nil)
    }
    /// Capture a shift-register profile with a scheduled noise note; ordinary output stays unchanged.
    public func play(_ event:BASICSoundEvent,voice:Int,at time:TimeInterval,noiseProfile:BASICShiftNoiseProfile?) {
        restartIfStopped()
        let start = frame(at: time)
        // "Play indefinitely" lasts until the voice is silenced or cut.
        let end = event.duration.isFinite ? start + Int64((event.duration * sampleRate).rounded()) : Int64.max
        let note: Note
        switch event {
        case .tone(let frequency, _, let volume):
            note = Note(voice: voice, start: start, end: end, frequency: frequency, volume: Float(volume), isNoise: false)
        case .noise(_, let volume):
            note = Note(voice: voice, start: start, end: end, frequency: 0, volume: Float(volume), isNoise: true,noiseProfile:noiseProfile)
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

    /// Schedule a continuously varying signal, including during blocked host calls.
    /// The audio render lock owns access to a stateful modulation object.
    public func play(modulation:any BASICPCMModulation,voice:Int,at time:TimeInterval,duration:TimeInterval) {
        restartIfStopped()
        let start=frame(at:time)
        let end=duration.isFinite ? start+Int64((max(0,duration)*sampleRate).rounded()) : Int64.max
        let note=Note(voice:voice,start:start,end:end,frequency:0,volume:0,isNoise:false,modulation:modulation)
        lock.lock();notes.append(note);lock.unlock()
    }

    /// Select a waveform and stereo position for current and future notes.
    public func configure(voice:Int,waveform:BASICWaveform,pan:Double) {
        lock.lock();renderer.configure(voice:voice,waveform:waveform,pan:pan);lock.unlock()
    }
    /// Restore the default square wave and centre position for every voice.
    public func resetVoiceStyles() {
        lock.lock();renderer.resetStyles();lock.unlock()
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

    /// The frame `time` falls in, catching the timeline up first when the
    /// engine has rendered less than the clock says it should have: the notes
    /// already scheduled move with it, keeping their places.
    private func frame(at time: TimeInterval) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let shift = timeline.catchUp(now: ProcessInfo.processInfo.systemUptime, rendered: renderedFrames)
        if shift != 0 {
            for index in notes.indices {
                notes[index].start += shift
                if notes[index].end != Int64.max {
                    notes[index].end += shift
                }
            }
        }
        return timeline.frame(at: time)
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
        let right=buffers.count>1 ? buffers[1].mData?.assumingMemoryBound(to:Float.self) : nil
        for frame in 0..<frameCount {
            let value=renderer.sample(notes:notes,frame:first+Int64(frame),sampleRate:sampleRate,gain:Self.gain)
            samples[frame]=value.left
            right?[frame]=value.right
        }
        renderedFrames = first + Int64(frameCount)
        notes.removeAll { $0.end <= renderedFrames }
    }

}
#endif
