//
//  BASICMusicMacro.swift
//  BASICSound
//
//  PLAY's music macro language, turned into events.
//

import Foundation

/// What `PLAY` remembers from one string to the next.
///
/// GW-BASIC keeps these for the whole run: a program sets the tempo once and
/// every later `PLAY` uses it. `SOUND` reads `isBackground` too.
public struct BASICMusicState: Equatable, Sendable {
    /// `O n`, 0–6. Default 4.
    public var octave = 4
    /// `L n`: a note is 1/n of a whole note. Default 4, a quarter note.
    public var length = 4
    /// `T n`: quarter notes a minute, 32–255. Default 120.
    public var tempo = 120
    /// How much of its time a note sounds: `MN` 7/8, `ML` 1, `MS` 3/4.
    public var fill = 7.0 / 8.0
    /// `MB` (true) queues notes while the program carries on; `MF`, the
    /// default, waits for each.
    public var isBackground = false

    public init() {}
}

/// GW-BASIC's music macro language (User's Guide, PLAY; QuickBASIC shares it).
///
/// ```text
///   A–G [#|+|-] [n] [.…]   a note, optionally sharp or flat, with its own
///                          length and dots (each dot adds half again)
///   O n  > <               octave 0–6, up one, down one
///   N n                    note 0–84 by number; 0 is a rest
///   L n  T n  P n          default length 1–64, tempo 32–255, pause 1–64
///   MN ML MS               normal (7/8), legato (all), staccato (3/4)
///   MF MB                  foreground, background
///   X name;                play the string in a variable
///   =name;                 any number above, from a variable
/// ```
///
/// Pitch follows PC-BASIC, which reproduces what GW-BASIC plays:
/// `440 × 2^((octave × 12 + semitone − 33) / 12)`, so A440 is `O2 A` and
/// middle C is `O2 C`. GW's manual says middle C begins octave 3. That is
/// one octave off what GW plays, and would put `O0 C` at 32.7 Hz, below the
/// 37 Hz a PC could make at all.
///
/// A sharp or flat must name a black key, as GW requires: `E#` and `C-` are
/// Illegal function call, as is anything out of range.
public enum BASICMusicMacro {
    /// Lookups for `=name;` and `X name;`, answered by the engine that owns
    /// the program's variables: nil means there is no such variable.
    public struct Variables {
        public var number: (String) -> Double?
        public var text: (String) -> String?

        public init(number: @escaping (String) -> Double?, text: @escaping (String) -> String?) {
            self.number = number
            self.text = text
        }

        /// No variables, for a string that names none.
        public static var none: Variables { Variables(number: { _ in nil }, text: { _ in nil }) }
    }

    /// The notes `macro` plays, each as its events — a tone and the gap its
    /// articulation leaves, or a pause — updating `state` as it goes.
    ///
    /// A note stays one note however many events it takes: `PLAY(n)` and the
    /// 32-note queue count notes, and a staccato note is still one.
    public static func notes(
        for macro: String,
        state: inout BASICMusicState,
        variables: Variables = .none
    ) throws -> [[BASICSoundEvent]] {
        var reader = Reader(text: macro, variables: variables)
        var notes: [[BASICSoundEvent]] = []
        try play(&reader, state: &state, into: &notes, depth: 0)
        return notes
    }

    /// The semitone each letter names within its octave.
    private static let semitones: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

    /// The letters a sharp may follow, and a flat — the black keys.
    private static let sharpable: Set<Character> = ["C", "D", "F", "G", "A"]
    private static let flattable: Set<Character> = ["D", "E", "G", "A", "B"]

    /// `X` strings may name one another; GW has no loop check, so this caps
    /// the nesting rather than recursing until the stack runs out.
    private static let maximumDepth = 16

    /// The frequency of semitone `index` counted from `O0 C`, PC-BASIC's table.
    static func frequency(ofNoteIndex index: Int) -> Double {
        440 * pow(2, (Double(index) - 33) / 12)
    }

    private static func play(
        _ reader: inout Reader,
        state: inout BASICMusicState,
        into events: inout [[BASICSoundEvent]],
        depth: Int
    ) throws {
        while let command = reader.next() {
            switch command {
            case " ", ";":
                continue
            case "A"..."G":
                var semitone = semitones[command]!
                if reader.match("#") || reader.match("+") {
                    guard sharpable.contains(command) else { throw BASICSoundError.illegalFunctionCall }
                    semitone += 1
                } else if reader.match("-") {
                    guard flattable.contains(command) else { throw BASICSoundError.illegalFunctionCall }
                    semitone -= 1
                }
                let length = try reader.optionalNumber(in: 1...64) ?? state.length
                let duration = noteDuration(length: length, tempo: state.tempo, dots: reader.dots())
                appendNote(frequency(ofNoteIndex: state.octave * 12 + semitone), duration, state: state, to: &events)
            case "N":
                let note = try reader.number(in: 0...84)
                let duration = noteDuration(length: state.length, tempo: state.tempo, dots: reader.dots())
                if note == 0 {
                    events.append([.rest(duration: duration)])
                } else {
                    appendNote(frequency(ofNoteIndex: note - 1), duration, state: state, to: &events)
                }
            case "O":
                state.octave = try reader.number(in: 0...6)
            case ">":
                state.octave = min(6, state.octave + 1)
            case "<":
                state.octave = max(0, state.octave - 1)
            case "L":
                state.length = try reader.number(in: 1...64)
            case "T":
                state.tempo = try reader.number(in: 32...255)
            case "P":
                let length = try reader.number(in: 1...64)
                events.append([.rest(duration: noteDuration(length: length, tempo: state.tempo, dots: reader.dots()))])
            case "M":
                switch reader.next() {
                case "N": state.fill = 7.0 / 8.0
                case "L": state.fill = 1
                case "S": state.fill = 3.0 / 4.0
                case "F": state.isBackground = false
                case "B": state.isBackground = true
                default: throw BASICSoundError.illegalFunctionCall
                }
            case "X":
                guard depth < maximumDepth else { throw BASICSoundError.illegalFunctionCall }
                let name = try reader.variableName()
                guard let text = reader.variables.text(name) else { throw BASICSoundError.illegalFunctionCall }
                var inner = Reader(text: text, variables: reader.variables)
                try play(&inner, state: &state, into: &events, depth: depth + 1)
            default:
                throw BASICSoundError.illegalFunctionCall
            }
        }
    }

    /// A whole note is four beats; `length` divides it; each dot adds half
    /// again of what came before (`A.` is 3/2, `A..` is 9/4).
    private static func noteDuration(length: Int, tempo: Int, dots: Int) -> TimeInterval {
        let whole = 4 * 60 / Double(tempo)
        return whole / Double(length) * pow(1.5, Double(dots))
    }

    /// A note sounds for its fill and rests for the remainder.
    private static func appendNote(_ frequency: Double, _ duration: TimeInterval, state: BASICMusicState, to notes: inout [[BASICSoundEvent]]) {
        var note: [BASICSoundEvent] = [.tone(frequency: frequency, duration: duration * state.fill, volume: 1)]
        if state.fill < 1 {
            note.append(.rest(duration: duration * (1 - state.fill)))
        }
        notes.append(note)
    }

    /// Characters of a macro, uppercased, with numbers and variable names.
    private struct Reader {
        private let characters: [Character]
        private var position = 0
        let variables: Variables

        init(text: String, variables: Variables) {
            self.characters = Array(text.uppercased())
            self.variables = variables
        }

        mutating func next() -> Character? {
            guard position < characters.count else { return nil }
            defer { position += 1 }
            return characters[position]
        }

        mutating func match(_ character: Character) -> Bool {
            guard position < characters.count, characters[position] == character else { return false }
            position += 1
            return true
        }

        /// How many dots follow.
        mutating func dots() -> Int {
            var count = 0
            while match(".") { count += 1 }
            return count
        }

        /// A number that must be there, in `range`.
        mutating func number(in range: ClosedRange<Int>) throws -> Int {
            guard let value = try optionalNumber(in: range) else { throw BASICSoundError.illegalFunctionCall }
            return value
        }

        /// Digits, or `=name;`, or nil when neither follows.
        mutating func optionalNumber(in range: ClosedRange<Int>) throws -> Int? {
            let value: Double
            if match("=") {
                let name = try variableName()
                guard let number = variables.number(name) else { throw BASICSoundError.illegalFunctionCall }
                value = number.rounded()
            } else {
                var digits = ""
                while position < characters.count, characters[position].isASCII, characters[position].isNumber {
                    digits.append(characters[position])
                    position += 1
                }
                guard let number = Double(digits) else { return nil }
                value = number
            }
            guard value >= Double(range.lowerBound), value <= Double(range.upperBound) else {
                throw BASICSoundError.illegalFunctionCall
            }
            return Int(value)
        }

        /// A variable name, up to the `;` GW requires after it.
        mutating func variableName() throws -> String {
            var name = ""
            while let character = next() {
                if character == ";" { return name.trimmingCharacters(in: .whitespaces) }
                name.append(character)
            }
            throw BASICSoundError.illegalFunctionCall
        }
    }
}
