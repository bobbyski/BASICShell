//
//  DocumentLibrary.swift
//  DocumentArchive
//
//  A set of documents, whether they arrive as a zip or as a directory.
//

import Foundation

/// A collection of text documents that came either from a zip archive or from
/// a directory of files.
///
/// Which of the two it is matters to whoever built the application and to
/// nobody else, so it is not in the API: shipping code reads the archive in
/// the bundle, a developer editing the documents points at the directory, and
/// the code that displays them cannot tell and does not ask.
///
/// ```swift
/// let library = try DocumentLibrary(searching: [
///     .archive(bundledZip),
///     .directory(sourceFolder),
/// ], extension: "md")
///
/// for document in library.documents {
///     print(document.name, document.text.count)
/// }
/// ```
public struct DocumentLibrary: Sendable {

    /// Somewhere documents might be.
    public enum Source: Sendable {
        /// A zip archive. An optional `prefix` reads only one folder inside it.
        case archive(URL, prefix: String = "")
        /// A directory of files.
        case directory(URL)

        public static func archive(_ url: URL) -> Source { .archive(url, prefix: "") }
    }

    /// One document.
    public struct Document: Sendable, Hashable {
        /// The file's name without its extension — `PRINT` for `PRINT.md`.
        public let name: String
        /// The path it was stored under, relative to the archive or directory.
        public let path: String
        /// Its text.
        public let text: String
    }

    /// The documents, sorted by name.
    public let documents: [Document]

    /// Where they came from — for a diagnostic, or a status line.
    public let source: Source

    private let byName: [String: Document]

    /// Opens the first source that has anything in it.
    ///
    /// Sources are tried in order and the first that yields a document wins;
    /// a source that is missing, unreadable or empty is passed over rather
    /// than being an error. That is what lets an application list the archive
    /// it ships with *and* the folder it was built from, and get the right
    /// one on both machines without being told which it is on.
    ///
    /// - Throws: only when no source yielded anything.
    public init(searching sources: [Source], extension fileExtension: String) throws {
        var failures: [String] = []
        for source in sources {
            do {
                let found = try Self.documents(in: source, extension: fileExtension)
                if !found.isEmpty {
                    self.documents = found
                    self.source = source
                    self.byName = Dictionary(found.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
                    return
                }
            } catch {
                failures.append("\(source.describedPath): \(error)")
            }
        }
        throw ZipArchive.Failure(
            failures.isEmpty
                ? "no documents found in any of the places searched"
                : "no documents found. " + failures.joined(separator: "; ")
        )
    }

    /// One document by name, without its extension.
    public func document(named name: String) -> Document? {
        byName[name]
    }

    private static func documents(in source: Source, extension fileExtension: String) throws -> [Document] {
        let suffix = "." + fileExtension.lowercased()
        switch source {
        case .archive(let url, let prefix):
            let archive = try ZipArchive(url: url)
            return try archive.entries
                .filter { entry in
                    !entry.isDirectory
                        && entry.path.lowercased().hasSuffix(suffix)
                        && entry.path.hasPrefix(prefix)
                        // Skip the metadata folder the Finder's Compress adds,
                        // whose entries otherwise arrive as duplicate pages
                        // with unreadable contents.
                        && !entry.path.contains("__MACOSX/")
                        && !(entry.path as NSString).lastPathComponent.hasPrefix("._")
                }
                .map { entry in
                    let relative = String(entry.path.dropFirst(prefix.count))
                    return Document(
                        name: (relative as NSString).deletingPathExtension,
                        path: relative,
                        text: try archive.text(at: entry.path)
                    )
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        case .directory(let url):
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            return files
                .filter { $0.lastPathComponent.lowercased().hasSuffix(suffix) }
                .compactMap { file in
                    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                    return Document(
                        name: file.deletingPathExtension().lastPathComponent,
                        path: file.lastPathComponent,
                        text: text
                    )
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}

extension DocumentLibrary.Source {
    /// The path this source names, for a message.
    public var describedPath: String {
        switch self {
        case .archive(let url, let prefix): prefix.isEmpty ? url.path : "\(url.path)#\(prefix)"
        case .directory(let url): url.path
        }
    }
}
