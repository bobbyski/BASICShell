//
//  main.swift
//  documentarchive-check
//
//  Reads every document in a zip as an app reads its manual, and prints a
//  summary that is the same wherever the zip reads the same (BASIC-72).
//

import DocumentArchive
import Foundation

// documentarchive-check <archive.zip> [extension]
//
//   UserDocs.zip: 122 documents, 266016 bytes of text, digest 1fec33ef1c964d02
//   first ALIAS, last YIELD
//
// The digest is FNV-1a over each document's path and text, in the library's
// order, so the same line on macOS, Linux and Windows means every document
// came out of the zip with the same bytes (ProjectKit PLAN 10.6).

let arguments = CommandLine.arguments.dropFirst()
guard let path = arguments.first else {
    FileHandle.standardError.write(Data("usage: documentarchive-check <archive.zip> [extension]\n".utf8))
    exit(2)
}
let fileExtension = arguments.dropFirst().first ?? "md"
let url = URL(fileURLWithPath: path)

do {
    let library = try DocumentLibrary(searching: [.archive(url)], extension: fileExtension)
    var digest: UInt64 = 0xcbf2_9ce4_8422_2325
    var bytes = 0
    for document in library.documents {
        for byte in Array(document.path.utf8) + [0] + Array(document.text.utf8) {
            digest = (digest ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        bytes += document.text.utf8.count
    }
    let hex = String(digest, radix: 16)
    print("\(url.lastPathComponent): \(library.documents.count) documents, \(bytes) bytes of text, digest \(String(repeating: "0", count: 16 - hex.count) + hex)")
    if let first = library.documents.first, let last = library.documents.last {
        print("first \(first.name), last \(last.name)")
    }
} catch {
    FileHandle.standardError.write(Data("documentarchive-check: \(error)\n".utf8))
    exit(1)
}
