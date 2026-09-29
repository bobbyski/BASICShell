//
//  BASICEnvelope.swift
//  BASICSound
//
//  BBC BASIC's ENVELOPE: how a note's loudness and pitch move over time.
//

import Foundation

/// One of BBC BASIC's sixteen envelopes, as `ENVELOPE` defines it.
///
/// ```text
///   ENVELOPE N, T, PI1, PI2, PI3, PN1, PN2, PN3, AA, AD, AS, AR, ALA, ALD
///
///   level  126 ┤    ALA
///              │   ╱╲___ALD
///              │  ╱     ╲______ sustain (AS a step)
///              │ ╱ AA  AD      ╲ release (AR a step, after the duration)
///            0 ┼╱───────────────╲──────►  one step every T hundredths of a second
///
///   pitch      PN1 steps of PI1, then PN2 of PI2, then PN3 of PI3,
///              then round again — unless T has bit 7 set
/// ```
///
/// The rules are the BBC BASIC for Windows manual's. Loudness runs from 0 to
/// 126. Attack climbs from 0 by `AA` a step until it reaches `ALA`, decay moves
/// by `AD` to `ALD`, and sustain moves by `AS` (never upward) until the note's
/// duration ends. Release then falls by `AR` a step until it reaches zero, or
/// until the next note queued on the channel cuts it short. Pitch is in
/// quarter semitones and wraps within 0–255, as the BBC's 8-bit pitch did; it
/// carries on from where it is when the sections repeat, which is why a
/// vibrato's sections are written to sum to zero.
///
/// Not modeled: the `SOUND` hold digit, which lengthens a release.
public struct BASICEnvelope: Equatable, Sendable {
    public let stepLength: TimeInterval
    public let repeatsPitch: Bool
    public let pitchSections: [(change: Int, steps: Int)]
    public let attack: Int, decay: Int, sustain: Int, release: Int
    public let attackTarget: Int, decayTarget: Int

    /// The loudest level, which a fixed amplitude of -15 matches.
    public static let loudest = 126.0

    /// How long an endless note's pitch keeps moving before it holds, so a
    /// vibrato on a note played "indefinitely" is still a finite list.
    static let endlessPitchLimit: TimeInterval = 60

    /// An envelope from `ENVELOPE`'s parameters after `N`, in order.
    public init(parameters p: [Double]) throws {
        guard p.count == 13 else { throw BASICSoundError.illegalFunctionCall }
        let v = p.map { Int($0.rounded()) }
        let ranges: [ClosedRange<Int>] = [
            0...255, -128...127, -128...127, -128...127, 0...255, 0...255, 0...255,
            -127...127, -127...127, -127...0, -127...0, 0...126, 0...126,
        ]
        guard zip(v, ranges).allSatisfy({ $1.contains($0) }) else { throw BASICSoundError.illegalFunctionCall }
        // T's low seven bits are the step; 0 is taken as the shortest step.
        stepLength = Double(max(1, v[0] & 0x7F)) / 100
        repeatsPitch = v[0] & 0x80 == 0
        pitchSections = [(v[1], v[4]), (v[2], v[5]), (v[3], v[6])]
        (attack, decay, sustain, release) = (v[7], v[8], v[9], v[10])
        (attackTarget, decayTarget) = (v[11], v[12])
    }

    public static func == (a: BASICEnvelope, b: BASICEnvelope) -> Bool {
        a.stepLength == b.stepLength && a.repeatsPitch == b.repeatsPitch
            && a.pitchSections.map(\.change) == b.pitchSections.map(\.change)
            && a.pitchSections.map(\.steps) == b.pitchSections.map(\.steps)
            && [a.attack, a.decay, a.sustain, a.release, a.attackTarget, a.decayTarget]
            == [b.attack, b.decay, b.sustain, b.release, b.attackTarget, b.decayTarget]
    }

    /// A note shaped by this envelope: the events that fill its `duration`,
    /// and the release that follows it.
    ///
    /// Consecutive steps with the same pitch and loudness are merged, so a
    /// long steady sustain is one event rather than hundreds.
    public func shape(pitch: Double, duration: TimeInterval, isNoise: Bool) -> (body: [BASICSoundEvent], release: [BASICSoundEvent]) {
        var shaper = Shaper(envelope: self, pitch: pitch, isNoise: isNoise)
        let body = shaper.body(lasting: duration)
        return (body, duration.isFinite ? shaper.release() : [])
    }

    /// Walks the envelope one step at a time.
    private struct Shaper {
        let envelope: BASICEnvelope
        let isNoise: Bool
        var pitch: Double
        var level = 0
        var phase = Phase.attack
        var section = 0
        var stepInSection = 0
        var pitchHeld = false
        var events: [BASICSoundEvent] = []

        enum Phase { case attack, decay, sustain }

        init(envelope: BASICEnvelope, pitch: Double, isNoise: Bool) {
            self.envelope = envelope
            self.pitch = pitch
            self.isNoise = isNoise
        }

        mutating func body(lasting duration: TimeInterval) -> [BASICSoundEvent] {
            events = []
            let end = duration.isFinite ? duration : BASICEnvelope.endlessPitchLimit
            // Counted rather than accumulated: ten steps of 0.01 s summed in
            // floating point fall just short of 0.1 s and invent an eleventh.
            let steps = Int((end / envelope.stepLength - 1e-9).rounded(.up))
            for index in 0..<steps {
                let step = index == steps - 1 ? end - Double(steps - 1) * envelope.stepLength : envelope.stepLength
                // Loudness moves at the start of each step, so a fast attack
                // is heard at once; pitch starts where the note asked for.
                advanceLoudness()
                emit(step)
                advancePitch()
                // An endless note that has settled holds its last step for ever.
                if !duration.isFinite, isSettled { break }
            }
            if !duration.isFinite { emit(.infinity) }
            return events
        }

        mutating func release() -> [BASICSoundEvent] {
            events = []
            guard level > 0 else { return [] }
            // AR 0 never gets quieter: the note lasts until something cuts it.
            guard envelope.release < 0 else {
                emit(.infinity)
                return events
            }
            while true {
                level = max(0, level + envelope.release)
                guard level > 0 else { break }
                emit(envelope.stepLength)
                advancePitch()
            }
            return events
        }

        private var isSettled: Bool {
            phase == .sustain && envelope.sustain == 0 && (pitchHeld || envelope.pitchSections.allSatisfy { $0.steps == 0 })
        }

        /// One step at the current pitch and loudness, merged into the last
        /// event when neither has changed.
        private mutating func emit(_ length: TimeInterval) {
            let volume = Double(level) / BASICEnvelope.loudest
            let frequency = BASICSoundCommand.frequency(ofPitch: pitch)
            let event: BASICSoundEvent
            if volume == 0 {
                event = .rest(duration: length)
            } else if isNoise {
                event = .noise(duration: length, volume: volume)
            } else {
                event = .tone(frequency: frequency, duration: length, volume: volume)
            }
            if let last = events.last, let merged = last.extended(by: event) {
                events[events.count - 1] = merged
            } else {
                events.append(event)
            }
        }

        private mutating func advanceLoudness() {
            switch phase {
            case .attack:
                level = move(level, by: envelope.attack, toward: envelope.attackTarget)
                if level == envelope.attackTarget { phase = .decay }
            case .decay:
                level = move(level, by: envelope.decay, toward: envelope.decayTarget)
                if level == envelope.decayTarget { phase = .sustain }
            case .sustain:
                level = max(0, level + envelope.sustain)
            }
        }

        /// `level` moved by `step` without passing `target`; a step that
        /// points away from the target never arrives, as on the BBC.
        private func move(_ level: Int, by step: Int, toward target: Int) -> Int {
            let next = level + step
            if step > 0, next >= target, level <= target { return target }
            if step < 0, next <= target, level >= target { return target }
            return min(126, max(0, next))
        }

        private mutating func advancePitch() {
            guard !pitchHeld else { return }
            let sections = envelope.pitchSections
            guard sections.contains(where: { $0.steps > 0 }) else { return }
            while stepInSection >= sections[section].steps {
                stepInSection = 0
                section += 1
                if section == sections.count {
                    guard envelope.repeatsPitch else { pitchHeld = true; return }
                    section = 0
                }
            }
            pitch = (pitch + Double(sections[section].change)).truncatingRemainder(dividingBy: 256)
            if pitch < 0 { pitch += 256 }
            stepInSection += 1
        }
    }
}

extension BASICSoundEvent {
    /// This event lengthened to include `next`, when the two sound the same.
    func extended(by next: BASICSoundEvent) -> BASICSoundEvent? {
        switch (self, next) {
        case (.tone(let f, let d, let v), .tone(let f2, let d2, let v2)) where f == f2 && v == v2:
            return .tone(frequency: f, duration: d + d2, volume: v)
        case (.noise(let d, let v), .noise(let d2, let v2)) where v == v2:
            return .noise(duration: d + d2, volume: v)
        case (.rest(let d), .rest(let d2)):
            return .rest(duration: d + d2)
        default:
            return nil
        }
    }
}
