//
//  StudioNativeTerminal.swift
//  BASICStudio
//
//  The terminal a native ⚡ run is given: a pseudo-terminal whose far end is
//  Studio's console.
//

import Foundation

/// A compiled program's output, split as Studio's console takes it: the VTG
/// commands (APC sequences, `ESC _ … ESC \`) for the graphics view, and
/// everything else, text and ANSI, for the console.
///
/// A sequence or a character cut off at the end of one read is held until
/// the next, so neither stream ever gets half of one.
struct StudioTerminalStreamSplitter {
    enum Segment: Equatable {
        case text(String)
        case vtg(Data)
    }

    private var pending: [UInt8] = []

    /// Splits the next bytes read, in order.
    mutating func split(_ bytes: [UInt8]) -> [Segment] {
        let input = pending + bytes
        pending = []
        var segments: [Segment] = []
        var text: [UInt8] = []
        func flushText() {
            guard !text.isEmpty else { return }
            segments.append(.text(Self.consoleText(text)))
            text = []
        }
        var index = 0
        while index < input.count {
            let byte = input[index]
            guard byte == 0x1B else {
                text.append(byte)
                index += 1
                continue
            }
            guard index + 1 < input.count else {
                // An escape at the very end: what it starts comes next time.
                pending = Array(input[index...])
                break
            }
            guard input[index + 1] == UInt8(ascii: "_") else {
                text.append(byte)
                index += 1
                continue
            }
            // An APC: up to ESC \ (or BEL), whole, or held for the next read.
            var end: Int?
            var scan = index + 2
            while scan < input.count {
                if input[scan] == 0x07 { end = scan + 1; break }
                if input[scan] == 0x1B, scan + 1 < input.count, input[scan + 1] == UInt8(ascii: "\\") { end = scan + 2; break }
                scan += 1
            }
            guard let end else {
                pending = Array(input[index...])
                break
            }
            flushText()
            segments.append(.vtg(Data(input[index..<end])))
            index = end
        }
        // A UTF-8 character cut off at the end waits for its last bytes.
        let complete = Self.completeUTF8Prefix(text)
        if complete < text.count {
            pending = Array(text[complete...]) + pending
            text = Array(text[..<complete])
        }
        flushText()
        return segments
    }

    /// Text for the console, which adds its own carriage returns: the
    /// terminal's `\r\n` for each newline becomes `\n`.
    static func consoleText(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// How many leading bytes of `bytes` end on a whole UTF-8 character.
    static func completeUTF8Prefix(_ bytes: [UInt8]) -> Int {
        var start = bytes.count
        // Back over at most three continuation bytes to a lead byte.
        while start > 0, bytes.count - start < 4 {
            start -= 1
            let byte = bytes[start]
            if byte & 0xC0 != 0x80 {
                let length = byte < 0x80 ? 1 : byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                return start + length <= bytes.count ? bytes.count : start
            }
        }
        return bytes.count
    }
}

#if os(macOS)
/// A pseudo-terminal for a native ⚡ run.
///
/// The compiled runtime draws only on a terminal that answers VTG's
/// `capabilities?`, as VGTerm does for BASICShell; a pipe answers nothing.
/// So the program runs on this terminal's slave side, and Studio is the
/// terminal: its console view parses what arrives on the master side, answers
/// the queries, and what the view sends back (keys, query answers, mouse and
/// resize reports) is written to the master.
final class StudioPseudoTerminal: @unchecked Sendable {
    /// Studio's end.
    let master: FileHandle
    /// The program's end: its standard input, output and error.
    let slave: FileHandle

    init(columns: Int, rows: Int) throws {
        var masterDescriptor: Int32 = -1
        var slaveDescriptor: Int32 = -1
        var size = winsize(ws_row: UInt16(max(1, rows)), ws_col: UInt16(max(1, columns)), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterDescriptor, &slaveDescriptor, nil, nil, &size) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        master = FileHandle(fileDescriptor: masterDescriptor, closeOnDealloc: true)
        slave = FileHandle(fileDescriptor: slaveDescriptor, closeOnDealloc: true)
    }

    /// The console's new size, for the program's next `TIOCGWINSZ`.
    func resize(columns: Int, rows: Int) {
        var size = winsize(ws_row: UInt16(max(1, rows)), ws_col: UInt16(max(1, columns)), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master.fileDescriptor, TIOCSWINSZ, &size)
    }

    /// Bytes for the program, as typed or answered.
    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        try? master.write(contentsOf: Data(bytes))
    }
}
#endif
