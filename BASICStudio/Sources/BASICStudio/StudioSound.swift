import BASICCore

/// `SOUND`, `PLAY` and `BEEP` play on the Mac's speaker (BBC_ADINS.md A8).
///
/// On a Mac without audio, `SOUND` and `PLAY` are the runtime error Device
/// unavailable, as on any host without an output.
extension StudioModel: BASICSoundHost {
    nonisolated var soundOutput: BASICSoundOutput? {
        BASICToneSynthesizer.shared
    }
}
