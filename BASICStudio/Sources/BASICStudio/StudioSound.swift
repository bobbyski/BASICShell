import BASICCore

/// `SOUND`, `PLAY` and `BEEP` play on the Mac's speaker (BBC_ADINS.md A8).
///
/// Studio has no terminal bell to fall back on, so a Mac without audio keeps
/// the notes' timing silently, as any host without an output does.
extension StudioModel: BASICSoundHost {
    nonisolated var soundOutput: BASICSoundOutput? {
        BASICToneSynthesizer.shared
    }
}
