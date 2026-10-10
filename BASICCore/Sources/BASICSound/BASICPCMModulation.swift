import Foundation

/// An immutable signal value supplied to one PCM frame.
public struct BASICPCMValue: Sendable {
    /// Current tone frequency in hertz.
    public let frequency: Double
    /// Current loudness from zero to one.
    public let volume: Float
    /// Whether the frame uses the noise generator.
    public let isNoise: Bool
    /// Optional host-selected shift-register parameters.
    public let noiseProfile: BASICShiftNoiseProfile?
    /// Construct a signal value with bounded volume and finite frequency.
    public init(frequency: Double, volume: Float, isNoise: Bool, noiseProfile: BASICShiftNoiseProfile? = nil) {
        self.frequency = frequency.isFinite ? max(0, frequency) : 0
        self.volume = volume.isFinite ? min(1, max(0, volume)) : 0
        self.isNoise = isNoise
        self.noiseProfile = noiseProfile
    }
}

/// A host's continuous numeric signal; no source instructions are accepted.
/// Stateful implementations are accessed serially under their owning renderer's lock.
public protocol BASICPCMModulation: Sendable {
    /// Signal at seconds since the scheduled note began, including indefinite playback.
    func value(at elapsed: TimeInterval) -> BASICPCMValue
}
