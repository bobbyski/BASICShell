//
//  BASICSoundTimeline.swift
//  BASICSound
//
//  Where a note's time falls among the frames the speaker plays.
//

import Foundation

/// Turns a time on the sound clock (system uptime) into a frame of the
/// synthesizer's output, and keeps the two together.
///
/// A frame is seconds since `origin` times the sample rate. But the output
/// plays only the frames it renders, and it renders nothing while the audio
/// engine is stopped: on iPhone and iPad, whenever the app is suspended or
/// its audio is interrupted. The clock does not stop. Left alone, every note
/// after that would wait out the gap, minutes after a trip to another app,
/// and a short program would end before any of it was heard (BASIC-26).
///
/// So when the clock and the rendered frames have drifted further apart than
/// `tolerance`, `catchUp` moves the timeline to where rendering really is,
/// and says how far the notes already scheduled must move with it.
struct BASICSoundTimeline {
    let sampleRate: Double
    /// The time frame 0 stands for.
    private(set) var origin: TimeInterval
    /// How far apart the clock and the rendered frames may drift: well over
    /// a buffer or two of output latency, well under a delay anyone would hear.
    let tolerance: TimeInterval

    init(sampleRate: Double, origin: TimeInterval, tolerance: TimeInterval = 0.25) {
        self.sampleRate = sampleRate
        self.origin = origin
        self.tolerance = tolerance
    }

    /// The frame `time` falls in.
    func frame(at time: TimeInterval) -> Int64 {
        Int64(((time - origin) * sampleRate).rounded())
    }

    /// Moves the timeline so that `now` is `rendered`, the frame about to be
    /// played, if they have drifted apart. Returns how many frames anything
    /// already scheduled must move by to keep its place: 0 when nothing moved.
    mutating func catchUp(now: TimeInterval, rendered: Int64) -> Int64 {
        let drift = frame(at: now) - rendered
        guard Double(abs(drift)) > tolerance * sampleRate else { return 0 }
        origin += Double(drift) / sampleRate
        return -drift
    }
}
