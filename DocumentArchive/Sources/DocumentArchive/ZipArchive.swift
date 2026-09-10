//
//  ZipArchive.swift
//  DocumentArchive
//
//  Reading a zip file, in process, without unpacking it.
//

import Foundation
#if canImport(Compression)
import Compression
#endif

/// A zip file, opened for reading.
///
/// Enough of the format to read an archive somebody made — the central
/// directory, stored and deflated entries, and the CRC that says the bytes
/// arrived intact. Not enough to write one: an archive that ships inside an
/// application is built once by the build, and a reader that cannot write
/// cannot corrupt what it was given.
///
/// The whole file is held in memory. That is the right trade for what this is
/// for — a manual, a set of templates, a pack of samples, all of them small
/// and all of them read repeatedly — and the wrong one for a multi-gigabyte
/// archive, which should be unpacked to disk instead.
///
/// ```swift
/// let archive = try ZipArchive(url: url)
/// let page = try archive.text(at: "PRINT.md")
/// ```
public struct ZipArchive: Sendable {

    /// Something about the archive this reader cannot honor.
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    /// One file in the archive.
    public struct Entry: Sendable, Hashable {
        /// The path as it was stored, `/` separated.
        public let path: String
        /// The size once decompressed.
        public let size: Int
        /// The size as stored.
        public let compressedSize: Int
        /// True for a directory entry, which carries no content.
        public let isDirectory: Bool

        let method: UInt16
        let crc32: UInt32
        let headerOffset: Int
    }

    private let bytes: [UInt8]

    /// Every file in the archive, in the order the archive lists them.
    public let entries: [Entry]

    private let index: [String: Entry]

    /// Opens the archive in a file.
    public init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    /// Opens an archive already in memory.
    public init(data: Data) throws {
        bytes = [UInt8](data)
        entries = try Self.readCentralDirectory(bytes)
        index = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Reading

    /// Whether the archive holds something at that path.
    public func contains(_ path: String) -> Bool {
        index[path] != nil
    }

    /// The entry at that path, or nil.
    public func entry(at path: String) -> Entry? {
        index[path]
    }

    /// The bytes of one file, decompressed and checked.
    public func data(at path: String) throws -> Data {
        guard let entry = index[path] else {
            throw Failure("\(path) is not in the archive")
        }
        return try data(for: entry)
    }

    /// The bytes of one file, decompressed and checked.
    public func data(for entry: Entry) throws -> Data {
        guard !entry.isDirectory else { return Data() }
        let start = try contentStart(of: entry)
        guard start + entry.compressedSize <= bytes.count else {
            throw Failure("\(entry.path) runs past the end of the archive")
        }
        let stored = Data(bytes[start..<(start + entry.compressedSize)])

        let result: Data
        switch entry.method {
        case 0:
            result = stored
        case 8:
            result = try inflate(stored, to: entry.size, path: entry.path)
        default:
            throw Failure("\(entry.path) uses compression method \(entry.method), which this reader does not know")
        }

        guard result.count == entry.size else {
            throw Failure("\(entry.path) unpacked to \(result.count) bytes, not the \(entry.size) it claims")
        }
        // The archive says what the bytes should add up to. Checking costs a
        // pass over data already in cache and turns a corrupt archive into a
        // clear error instead of a puzzling one somewhere later.
        let checksum = CRC32.of(result)
        guard checksum == entry.crc32 else {
            throw Failure("\(entry.path) is corrupt: checksum \(checksum) where \(entry.crc32) was expected")
        }
        return result
    }

    /// One file as text.
    ///
    /// - Parameter encoding: how to read the bytes. UTF-8 by default.
    public func text(at path: String, encoding: String.Encoding = .utf8) throws -> String {
        let data = try data(at: path)
        guard let text = String(data: data, encoding: encoding) else {
            throw Failure("\(path) is not \(encoding) text")
        }
        return text
    }

    // MARK: The format

    /// Where an entry's bytes begin: past its local header, whose name and
    /// extra fields may be sized differently from the central directory's.
    private func contentStart(of entry: Entry) throws -> Int {
        let offset = entry.headerOffset
        guard offset + 30 <= bytes.count, readUInt32(bytes, offset) == 0x04034b50 else {
            throw Failure("\(entry.path) has no local header where the archive says it does")
        }
        let nameLength = Int(readUInt16(bytes, offset + 26))
        let extraLength = Int(readUInt16(bytes, offset + 28))
        return offset + 30 + nameLength + extraLength
    }

    private static func readCentralDirectory(_ bytes: [UInt8]) throws -> [Entry] {
        guard bytes.count >= 22 else { throw Failure("too short to be a zip") }

        // The end-of-central-directory record is last, but a zip may carry a
        // comment after it, so it is found by scanning back for its signature
        // rather than by arithmetic. The comment is capped at 65535, which
        // bounds the scan.
        let earliest = max(0, bytes.count - 22 - 65535)
        var end = -1
        var scan = bytes.count - 22
        while scan >= earliest {
            if readUInt32(bytes, scan) == 0x06054b50 { end = scan; break }
            scan -= 1
        }
        guard end >= 0 else { throw Failure("no end-of-central-directory record: not a zip file") }

        let count = Int(readUInt16(bytes, end + 10))
        let rawOffset = readUInt32(bytes, end + 16)
        let rawDeclaredSize = readUInt32(bytes, end + 12)

        // Zip64 puts 0xFFFFFFFF in the 32-bit fields and the real numbers in
        // its own record. Rather than half-support it, say so plainly.
        //
        // **Checked before narrowing to `Int`, not after.** `Int` is 32 bits
        // wide on wasm32, where `Int(0xFFFF_FFFF)` is not a comparison that
        // comes out false — it is a trap, and the literal does not even
        // compile. Reading the sentinel in the width the format defines it in
        // is both correct and portable.
        if rawOffset == UInt32.max || rawDeclaredSize == UInt32.max
            || readUInt16(bytes, end + 10) == 0xFFFF {
            throw Failure("this is a zip64 archive, which this reader does not read")
        }

        var offset = Int(rawOffset)
        let declaredSize = Int(rawDeclaredSize)

        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, readUInt32(bytes, offset) == 0x02014b50 else {
                throw Failure("the central directory is damaged")
            }
            let method = readUInt16(bytes, offset + 10)
            let crc = readUInt32(bytes, offset + 16)
            let compressedSize = Int(readUInt32(bytes, offset + 20))
            let size = Int(readUInt32(bytes, offset + 24))
            let nameLength = Int(readUInt16(bytes, offset + 28))
            let extraLength = Int(readUInt16(bytes, offset + 30))
            let commentLength = Int(readUInt16(bytes, offset + 32))
            let headerOffset = Int(readUInt32(bytes, offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLength <= bytes.count else {
                throw Failure("the central directory is damaged")
            }
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)

            entries.append(Entry(
                path: name,
                size: size,
                compressedSize: compressedSize,
                isDirectory: name.hasSuffix("/"),
                method: method,
                crc32: crc,
                headerOffset: headerOffset
            ))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    private func inflate(_ stored: Data, to size: Int, path: String) throws -> Data {
        guard size > 0 else { return Data() }
        #if canImport(Compression)
        // Zip holds raw DEFLATE with no zlib wrapper, which is exactly what
        // COMPRESSION_ZLIB means here.
        var output = Data(count: size)
        let written: Int = output.withUnsafeMutableBytes { destination in
            stored.withUnsafeBytes { source in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase, size,
                    sourceBase, stored.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else {
            throw Failure("\(path) could not be decompressed")
        }
        return output
        #else
        throw Failure("\(path) is deflated, and no decompressor is available on this platform")
        #endif
    }
}

// MARK: - Little-endian reads

private func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    guard offset + 2 <= bytes.count else { return 0 }
    return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

private func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    guard offset + 4 <= bytes.count else { return 0 }
    return UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

// MARK: - CRC32

/// The checksum zip stores for every entry.
enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func of(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in data {
            value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        return value ^ 0xFFFF_FFFF
    }
}
