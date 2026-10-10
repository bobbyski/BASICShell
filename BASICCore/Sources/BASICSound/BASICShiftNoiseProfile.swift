import Foundation

/// A deterministic16-bit shift-register signal with a configurable output waveform bank.
/// Each note captures its profile, so scheduling a later note cannot change an earlier one.
public struct BASICShiftNoiseProfile: Equatable, Sendable {
    public let taps:UInt16
    public let seed:UInt16
    public let clockRate:Double
    public let waveforms:[BASICWaveform]
    public let phaseBits:Int
    public init(taps:UInt16,seed:UInt16=0,clockRate:Double=44100,waveforms:[BASICWaveform]=[.square],phaseBits:Int=16) {
        self.taps=taps;self.seed=seed
        self.clockRate=clockRate.isFinite && clockRate>0 ? min(192000,clockRate) : 44100
        self.waveforms=waveforms.isEmpty ? [.square] : waveforms
        self.phaseBits=min(16,max(1,phaseBits))
    }
    /// Shift once and insert a high bit when the selected taps agree.
    public func advance(_ register:UInt16)->UInt16 {
        let shifted=register>>1,selected=shifted&taps
        return shifted | (selected==0 || selected==taps ? 0x8000 : 0)
    }
    public func sample(register:UInt16)->Float {
        let size=1<<phaseBits,bank=(Int(register)>>phaseBits)%waveforms.count
        let phase=Double(Int(register)&(size-1))/Double(size)
        return waveforms[bank].sample(at:phase)
    }
}
