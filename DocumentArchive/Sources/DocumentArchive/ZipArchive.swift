//
//  ZipArchive.swift
//  DocumentArchive
//
//  Reading a zip file, in process, without unpacking it.
//

import Foundation
import ZipItZIP

/// A zip file, opened for reading.
///
/// A thin reader over ZipIt's ZIP format (`ZipItZIP`, BASIC-72): the central
/// directory, every compression method ZIP files use in practice (stored,
/// deflated, Deflate64), and the CRC that says the bytes arrived intact,
/// checked as each entry streams out. It inflates the same way on macOS, iOS,
/// Linux and Windows, which Apple's Compression framework, used before, did
/// not. Not a writer: an archive that ships inside an application is built
/// once by the build, and a reader that cannot write cannot corrupt what it
/// was given.
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
        /// The path, `/` separated, as ZipIt reads it (a Windows tool's `\` is a
        /// separator too).
        public let path: String
        /// The size once decompressed.
        public let size: Int
        /// The size as stored.
        public let compressedSize: Int
        /// True for a directory entry, which carries no content.
        public let isDirectory: Bool

        /// Its index among the reader's entries.
        let id: Int
    }

    private let reader: any ArchiveReader

    /// Every file in the archive, in the order the archive lists them. Names that
    /// would climb out of a folder (`../x`, `/etc/x`) are left out.
    public let entries: [Entry]

    private let index: [String: Entry]

    /// Opens the archive in a file.
    public init(url: URL) throws {
        do {
            try self.init(reader: try ZipFormatHandler().openReader(at: url))
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure("\(url.lastPathComponent) can't be read as a zip: \(error)")
        }
    }

    /// Opens an archive already in memory.
    public init(data: Data) throws {
        do {
            try self.init(reader: try ZipFormatHandler().openReader(MemoryByteSource([UInt8](data)), options: ReadOptions()))
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure("the data can't be read as a zip: \(error)")
        }
    }

    private init(reader: any ArchiveReader) throws {
        self.reader = reader
        entries = reader.entries.compactMap { entry in
            guard entry.unsafeReason == nil else { return nil }
            return Entry(path: entry.path.description, size: Int(entry.size ?? 0), compressedSize: Int(entry.packedSize ?? 0),
                         isDirectory: entry.kind == .directory, id: entry.id)
        }
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

    /// The bytes of one file, decompressed and checked: ZipIt verifies the CRC as the
    /// entry streams, and refuses more bytes than the entry says it holds.
    public func data(for entry: Entry) throws -> Data {
        guard !entry.isDirectory else { return Data() }
        do {
            let stream = try reader.openEntry(reader.entries[entry.id], password: nil)
            return Data(try stream.readAll(limit: entry.size))
        } catch {
            throw Failure("\(entry.path) can't be read: \(error)")
        }
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
}
