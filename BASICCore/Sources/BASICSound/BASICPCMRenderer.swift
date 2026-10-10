import Foundation

/// A periodic waveform. The default preserves classic BASIC square-wave output;
/// harmonic weights let a host choose its own instrument without changing events.
public enum BASICWaveform: Equatable, Sendable {
    case square
    case harmonics([Double])

    /// Evaluate one cycle at a phase in0..<1. Harmonics are sine amplitudes.
    public func sample(at phase:Double) -> Float {
        switch self {
        case .square:return phase<0.5 ? 1 : -1
        case .harmonics(let weights):
            var value=0.0
            for (index,weight) in weights.enumerated() where weight != 0 {
                value += weight*sin(2*Double.pi*Double(index+1)*phase)
            }
            return Float(value)
        }
    }
}

/// A scheduled PCM note, in output frames. Hosts convert their own clock to frames.
public struct BASICPCMNote: Sendable {
    public var voice:Int
    public var start:Int64
    public var end:Int64
    public var frequency:Double
    public var volume:Float
    public var isNoise:Bool
    public var noiseProfile:BASICShiftNoiseProfile?
    /// Optional continuous signal, accessed serially by the renderer.
    public var modulation:(any BASICPCMModulation)?
    public init(voice:Int,start:Int64,end:Int64,frequency:Double,volume:Float,isNoise:Bool,noiseProfile:BASICShiftNoiseProfile?=nil,modulation:(any BASICPCMModulation)?=nil) {
        self.voice=voice;self.start=start;self.end=end;self.frequency=frequency;self.volume=volume;self.isNoise=isNoise;self.noiseProfile=noiseProfile;self.modulation=modulation
    }
}

/// Platform-independent signal generation. Access serially or under the host's
/// audio lock. Voice phases persist between consecutive envelope segments.
public final class BASICPCMRenderer {
    private struct Style { var waveform:BASICWaveform;var pan:Double }
    private var styles:[Int:Style]=[:]
    private var phases:[Int:Double]=[:]
    private var noiseRegister:UInt16=0x4000
    private struct NoiseState { var register:UInt16;var phase:Double }
    private var noiseStates:[Int:NoiseState]=[:]

    public init() {}
    /// Pan is−1 fully left,0 centre,+1 fully right. Centre preserves the original
    /// mono level on each channel; hosts choose their own overall mixing gain.
    public func configure(voice:Int,waveform:BASICWaveform,pan:Double) {
        styles[voice]=Style(waveform:waveform,pan:pan.isFinite ? min(1,max(-1,pan)) : 0)
    }
    /// Restore voice settings without discarding oscillator phase.
    public func resetStyles() { styles.removeAll() }
    /// Mix one frame. Inactive and ended notes do not advance their voice phase.
    public func sample(notes:[BASICPCMNote],frame:Int64,sampleRate:Double,gain:Float=0.2) -> (left:Float,right:Float) {
        var left:Float=0,right:Float=0
        for note in notes where note.start<=frame && frame<note.end {
            let value=note.modulation?.value(at:Double(frame-note.start)/sampleRate)
                ?? BASICPCMValue(frequency:note.frequency,volume:note.volume,isNoise:note.isNoise,noiseProfile:note.noiseProfile)
            let style=styles[note.voice] ?? Style(waveform:.square,pan:0)
            let signal:Float
            if value.isNoise {
                if let profile=value.noiseProfile {
                    var state=noiseStates[note.voice] ?? NoiseState(register:profile.seed,phase:0)
                    state.phase += profile.clockRate/max(1,sampleRate)
                    while state.phase>=1 { state.register=profile.advance(state.register);state.phase-=1 }
                    noiseStates[note.voice]=state;signal=profile.sample(register:state.register)
                } else {
                    let bit=(noiseRegister^(noiseRegister>>1))&1
                    noiseRegister=(noiseRegister>>1)|(bit<<14)
                    signal=noiseRegister&1==0 ? 1 : -1
                }
            } else {
                var phase=phases[note.voice,default:0]+value.frequency/sampleRate
                phase -= phase.rounded(.down);phases[note.voice]=phase
                signal=style.waveform.sample(at:phase)
            }
            let mixed=value.volume*signal*gain
            left += mixed*Float(1-style.pan);right += mixed*Float(1+style.pan)
        }
        return (min(1,max(-1,left)),min(1,max(-1,right)))
    }
}
