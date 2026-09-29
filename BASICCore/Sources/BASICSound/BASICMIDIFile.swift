//
//  BASICMIDIFile.swift
//  BASICSound
//
//  Just enough of a Standard MIDI File to know how long it plays.
//

import Foundation

/// A Standard MIDI File, read for its length and its notes.
///
/// `PLAY MIDI` hands the file itself to the synthesizer, which plays it
/// through the system's General MIDI instruments. This reader exists so both
/// engines know how long the song lasts without asking the audio system:
/// a foreground `PLAY MIDI` waits exactly that long, a machine with no audio
/// keeps the same time silently, and the parity trace records it.
///
/// ```text
///   MThd  format, tracks, ticks per quarter note
///   MTrk  delta-time events: notes, controllers, sysex, and meta events;
///         meta 0x51 sets the tempo (microseconds a quarter note), from
///         that tick on, for every track
/// ```
///
/// The length is the last event's tick, converted through the tempo map.
/// SMPTE time divisions give frames a second directly and ignore tempo.
public struct BASICMIDIFile: Equatable, Sendable {
    /// How long the song plays, in seconds.
    public let duration: TimeInterval
    /// How many notes it strikes.
    public let noteCount: Int

    /// Reads `data`, or refuses it as not a MIDI file.
    public init(data: Data) throws {
        var reader = Reader(bytes: [UInt8](data))
        guard reader.tag() == "MThd", reader.uint32() == 6 else { throw Self.notMIDI }
        _ = reader.uint16()
        let trackCount = Int(reader.uint16())
        let division = reader.uint16()
        guard !reader.failed else { throw Self.notMIDI }

        var tempoChanges: [(tick: Int, microsecondsPerQuarter: Int)] = []
        var lastTick = 0
        var notes = 0
        for _ in 0..<trackCount {
            guard reader.tag() == "MTrk" else { throw Self.notMIDI }
            let length = Int(reader.uint32())
            let end = reader.position + length
            var tick = 0
            var runningStatus: UInt8?
            while reader.position < end, !reader.failed {
                tick += reader.variableLength()
                let first = reader.byte()
                switch first {
                case 0xFF:
                    let type = reader.byte()
                    let size = reader.variableLength()
                    if type == 0x51, size == 3 {
                        tempoChanges.append((tick, reader.bytes(3).reduce(0) { $0 << 8 | Int($1) }))
                    } else {
                        reader.skip(size)
                    }
                case 0xF0, 0xF7:
                    reader.skip(reader.variableLength())
                default:
                    var status = first
                    if first < 0x80 {
                        // Running status: this byte is the first data byte.
                        guard let running = runningStatus else { throw Self.notMIDI }
                        status = running
                        reader.position -= 1
                    } else {
                        runningStatus = first
                    }
                    let kind = status & 0xF0
                    let data = reader.bytes(kind == 0xC0 || kind == 0xD0 ? 1 : 2)
                    if kind == 0x90, data.count == 2, data[1] > 0 { notes += 1 }
                }
            }
            guard !reader.failed, reader.position <= end else { throw Self.notMIDI }
            reader.position = end
            lastTick = max(lastTick, tick)
        }
        guard !reader.failed else { throw Self.notMIDI }
        noteCount = notes
        duration = Self.seconds(atTick: lastTick, division: division, tempoChanges: tempoChanges)
    }

    private static let notMIDI = BASICSoundError("Not a MIDI file")

    /// `tick` in seconds, through the tempo map; 120 BPM until told otherwise.
    private static func seconds(atTick tick: Int, division: UInt16, tempoChanges: [(tick: Int, microsecondsPerQuarter: Int)]) -> TimeInterval {
        if division & 0x8000 != 0 {
            // SMPTE: frames a second, then ticks a frame.
            let frames = Double(256 - Int(division >> 8))
            let ticksPerFrame = Double(division & 0xFF)
            return Double(tick) / (frames * max(1, ticksPerFrame))
        }
        let ticksPerQuarter = Double(max(1, division))
        var seconds: TimeInterval = 0
        var previousTick = 0
        var tempo = 500_000
        for change in tempoChanges.sorted(by: { $0.tick < $1.tick }) where change.tick < tick {
            seconds += Double(change.tick - previousTick) * Double(tempo) / ticksPerQuarter / 1_000_000
            previousTick = change.tick
            tempo = change.microsecondsPerQuarter
        }
        return seconds + Double(tick - previousTick) * Double(tempo) / ticksPerQuarter / 1_000_000
    }

    /// Big-endian reads that never trap: running off the end sets `failed`.
    private struct Reader {
        let bytes: [UInt8]
        var position = 0
        var failed = false

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func byte() -> UInt8 {
            guard position < bytes.count else { failed = true; return 0 }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func bytes(_ count: Int) -> [UInt8] {
            (0..<count).map { _ in byte() }
        }

        mutating func skip(_ count: Int) {
            position += count
            if position > bytes.count { failed = true }
        }

        mutating func tag() -> String {
            String(decoding: bytes(4), as: UTF8.self)
        }

        mutating func uint16() -> UInt16 {
            bytes(2).reduce(0) { $0 << 8 | UInt16($1) }
        }

        mutating func uint32() -> UInt32 {
            bytes(4).reduce(0) { $0 << 8 | UInt32($1) }
        }

        /// MIDI's variable-length quantity: seven bits a byte, high bit set
        /// on all but the last, at most four bytes.
        mutating func variableLength() -> Int {
            var value = 0
            for _ in 0..<4 {
                let next = byte()
                value = value << 7 | Int(next & 0x7F)
                if next & 0x80 == 0 { return value }
            }
            failed = true
            return value
        }
    }
}
