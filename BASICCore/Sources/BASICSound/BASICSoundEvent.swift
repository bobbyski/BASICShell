//
//  BASICSoundEvent.swift
//  BASICSound
//
//  What a voice does for a while, and the conversions from BASIC's SOUND
//  statements into it.
//

import Foundation

/// One thing a voice does for a while: sound a tone, sound noise, or rest.
///
/// Everything `SOUND`, `PLAY` and `BEEP` mean reduces to a list of these, so
/// the rules live in one place and a host only has to make a tone of a
/// frequency for a time. A note played staccato is a tone followed by a rest.
public enum BASICSoundEvent: Equatable, Sendable {
    /// A square-wave tone. `volume` runs from 0 (silent) to 1.
    case tone(frequency: Double, duration: TimeInterval, volume: Double)
    /// Noise — the BBC Micro's channel 0.
    case noise(duration: TimeInterval, volume: Double)
    /// Silence that still takes its time.
    case rest(duration: TimeInterval)

    /// How long the event lasts, in seconds.
    public var duration: TimeInterval {
        switch self {
        case .tone(_, let duration, _), .noise(let duration, _), .rest(let duration):
            return duration
        }
    }
}

/// A sound statement BASIC refuses, with the words the engines print.
///
/// Both engines turn it into their own runtime error. The message is
/// GW-BASIC's for every case here, so it is also its `ERR`, 5.
public struct BASICSoundError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    /// GW-BASIC's answer to an argument out of range.
    public static let illegalFunctionCall = BASICSoundError("Illegal function call")
}

/// The two `SOUND` statements and `BEEP`, as events.
///
/// ```text
///   SOUND freq, ticks                       GW-BASIC, QuickBASIC
///     freq 37–32767 Hz (32767 is a rest), ticks 0–65535 at 18.2 a second,
///     0 stops what is playing
///
///   SOUND channel, amplitude, pitch, duration     BBC BASIC
///     channel 0 noise, 1–3 tone; +16 (&10) flushes that channel first
///     amplitude -15 (loud) … 0 (silent); 1–16 names an ENVELOPE
///     pitch in quarter semitones, 53 = middle C; duration in 1/20 s
///
///   BEEP                                    800 Hz for a quarter second
/// ```
///
/// The statement with two arguments is GW's and the one with four is BBC's,
/// so one `SOUND` accepts both.
public enum BASICSoundCommand {
    /// Clock ticks a second on the IBM PC, the unit of GW's durations.
    public static let ticksPerSecond = 18.2

    /// GW's `SOUND freq, ticks`, or nil for `SOUND freq, 0`, which stops the
    /// sound playing rather than making one.
    public static func gw(frequency: Double, ticks: Double) throws -> [BASICSoundEvent]? {
        guard (37...32767).contains(frequency), (0...65535).contains(ticks) else {
            throw BASICSoundError.illegalFunctionCall
        }
        guard ticks > 0 else { return nil }
        let seconds = ticks / ticksPerSecond
        // GW's manual: "To produce periods of silence, use SOUND 32767, duration".
        if frequency == 32767 { return [.rest(duration: seconds)] }
        return [.tone(frequency: frequency, duration: seconds, volume: 1)]
    }

    /// BBC's `SOUND channel, amplitude, pitch, duration`: the channel it
    /// plays on, whether it flushes that channel first, and its event.
    ///
    /// Not modeled: the sync and hold flags in the channel's upper digits, and
    /// envelopes. `ENVELOPE` itself does not parse, and an envelope number
    /// plays at full volume. Duration 255, "until flushed" on a BBC Micro,
    /// plays for 12.75 s.
    public static func bbc(channel: Double, amplitude: Double, pitch: Double, duration: Double) throws
        -> (channel: Int, flushes: Bool, event: BASICSoundEvent) {
        guard channel == channel.rounded(), (0...0xFFFF).contains(channel),
              (-15...16).contains(amplitude), (0...255).contains(pitch), (0...255).contains(duration) else {
            throw BASICSoundError.illegalFunctionCall
        }
        let code = Int(channel)
        let voice = code & 0xF
        guard voice <= 3 else { throw BASICSoundError.illegalFunctionCall }
        let flushes = (code >> 4) & 0xF != 0
        let volume = amplitude <= 0 ? -amplitude / 15 : 1
        let seconds = duration / 20
        if voice == 0 {
            return (voice, flushes, .noise(duration: seconds, volume: volume))
        }
        let frequency = 261.6255653005986 * pow(2, (pitch - 53) / 48)
        return (voice, flushes, .tone(frequency: frequency, duration: seconds, volume: volume))
    }

    /// `BEEP`: GW's 800 Hz for a quarter of a second.
    public static let beep: [BASICSoundEvent] = [.tone(frequency: 800, duration: 0.25, volume: 1)]
}
