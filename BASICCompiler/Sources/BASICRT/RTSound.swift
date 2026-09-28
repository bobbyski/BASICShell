import BASICSound
import Foundation

// BASICRT sound — SOUND, PLAY, PLAY(n) and BEEP.
//
// Not a copy of the interpreter's rules: both engines drive BASICSound's
// `BASICSoundSession`, so the notes, their timing and the music macro
// language are one implementation. Set BASIC_SOUND_TRACE to a file and both
// write the same trace, which is how their parity is tested.
//
// PLAY's `=name;` and `X name;` read variables by name, and a compiled
// program has no names at run time. So basicc binds the variables before
// each PLAY: the ones a literal string names, or every scalar in scope when
// the string is computed (see BIRBuilder's `.play`).

enum RTSound {
    /// The program's session, made on first use.
    nonisolated(unsafe) private static var current: BASICSoundSession?
    /// Variables bound for the next PLAY, by uppercased name.
    nonisolated(unsafe) static var numbers: [String: Double] = [:]
    nonisolated(unsafe) static var texts: [String: String] = [:]

    static var session: BASICSoundSession {
        if let current { return current }
        #if canImport(AVFoundation)
        let session = BASICSoundSession.forProgram(output: BASICToneSynthesizer.shared)
        #else
        let session = BASICSoundSession.forProgram(output: nil)
        #endif
        current = session
        return session
    }

    /// Lets background notes play out before the program exits, as the
    /// interpreter does when a program ends.
    static func finish() {
        current?.finish()
    }

    /// Runs `body`, failing the program with a refused note's BASIC error.
    static func checked(_ body: () throws -> Void) {
        do {
            try body()
        } catch let error as BASICSoundError {
            basic_rt_fail(error.message)
        } catch {
            basic_rt_fail("\(error)")
        }
    }

    /// The bound variables, read the way the interpreter reads an unset one:
    /// a name ending in `$` is an empty string, any other is 0.
    static var variables: BASICMusicMacro.Variables {
        BASICMusicMacro.Variables(
            number: { name in
                if let value = numbers[name] { return value }
                return texts[name] == nil && !name.hasSuffix("$") ? 0 : nil
            },
            text: { name in
                if let value = texts[name] { return value }
                return numbers[name] == nil && name.hasSuffix("$") ? "" : nil
            }
        )
    }
}

@_cdecl("basic_rt_beep")
public func basic_rt_beep() {
    let session = RTSound.session
    RTSound.checked { try session.beep() }
    if !session.isAudible {
        RTConsole.write("\u{07}")
    }
}

/// GW's `SOUND freq, ticks`.
@_cdecl("basic_rt_sound")
public func basic_rt_sound(_ frequency: Double, _ ticks: Double) {
    RTSound.checked { try RTSound.session.sound(frequency: frequency, ticks: ticks) }
}

/// BBC's `SOUND channel, amplitude, pitch, duration`.
@_cdecl("basic_rt_sound_bbc")
public func basic_rt_sound_bbc(_ channel: Double, _ amplitude: Double, _ pitch: Double, _ duration: Double) {
    RTSound.checked {
        try RTSound.session.sound(channel: channel, amplitude: amplitude, pitch: pitch, duration: duration)
    }
}

/// Binds a numeric variable for the next PLAY's `=name;`.
@_cdecl("basic_rt_play_bind_number")
public func basic_rt_play_bind_number(_ name: UnsafeMutableRawPointer?, _ value: Double) {
    RTSound.numbers[rtText(name).uppercased()] = value
}

/// Binds a string variable for the next PLAY's `X name;`.
@_cdecl("basic_rt_play_bind_text")
public func basic_rt_play_bind_text(_ name: UnsafeMutableRawPointer?, _ value: UnsafeMutableRawPointer?) {
    RTSound.texts[rtText(name).uppercased()] = rtText(value)
}

/// `PLAY macro$`, with the variables bound just before it.
@_cdecl("basic_rt_play")
public func basic_rt_play(_ macro: UnsafeMutableRawPointer?) {
    defer {
        RTSound.numbers.removeAll()
        RTSound.texts.removeAll()
    }
    let text = rtText(macro)
    RTSound.checked { try RTSound.session.play(text, variables: RTSound.variables) }
}

/// `PLAY(n)`: notes left in the background queue.
@_cdecl("basic_rt_play_count")
public func basic_rt_play_count(_ dummy: Double) -> Double {
    Double(RTSound.session.queuedNotes())
}
