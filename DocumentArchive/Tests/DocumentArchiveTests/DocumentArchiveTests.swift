import Foundation
import Testing
@testable import DocumentArchive

/// The archives are built by `/usr/bin/zip` rather than by a fixture checked
/// into the repository: the thing worth testing is that this reads what the
/// world's zip writer produces, and a fixture only proves it reads what we
/// once wrote down.
private struct Workspace {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("documentarchive-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Zips `paths` (relative to the workspace) into `name`.
    @discardableResult
    func zip(_ name: String, _ paths: [String], extraArguments: [String] = []) throws -> URL {
        let archive = root.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q"] + extraArguments + [archive.path] + paths
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return archive
    }

    func discard() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Test func readsADeflatedEntry() throws {
    let workspace = try Workspace()
    defer { workspace.discard() }
    // Long and repetitive, so zip certainly deflates it rather than storing it.
    let text = String(repeating: "the quick brown fox jumps over the lazy dog\n", count: 200)
    _ = try workspace.write("PRINT.md", text)
    let archive = try workspace.zip("docs.zip", ["PRINT.md"])

    let zip = try ZipArchive(url: archive)
    #expect(zip.entries.count == 1)
    #expect(zip.entries[0].method == 8, "expected the entry to be deflated, not stored")
    #expect(try zip.text(at: "PRINT.md") == text)
}

@Test func readsAStoredEntry() throws {
    let workspace = try Workspace()
    defer { workspace.discard() }
    let text = "short"
    _ = try workspace.write("A.md", text)
    // -0 forces store, the other branch of the reader.
    let archive = try workspace.zip("stored.zip", ["A.md"], extraArguments: ["-0"])

    let zip = try ZipArchive(url: archive)
    #expect(zip.entries[0].method == 0)
    #expect(try zip.text(at: "A.md") == text)
}

@Test func readsEveryEntryOfAManyFileArchive() throws {
    let workspace = try Workspace()
    defer { workspace.discard() }
    var expected: [String: String] = [:]
    for index in 0..<60 {
        let name = "PAGE\(index).md"
        let text = "# Page \(index)\n\n" + String(repeating: "body \(index) ", count: index + 1)
        expected[name] = text
        _ = try workspace.write(name, text)
    }
    let archive = try workspace.zip("many.zip", expected.keys.sorted())

    let zip = try ZipArchive(url: archive)
    #expect(zip.entries.count == expected.count)
    for (name, text) in expected {
        #expect(try zip.text(at: name) == text, "\(name) did not read back")
    }
}

@Test func readsEntriesInsideFolders() throws {
    let workspace = try Workspace()
    defer { workspace.discard() }
    _ = try workspace.write("UserDocs/PRINT.md", "# PRINT")
    _ = try workspace.write("UserDocs/RUN.md", "# RUN")
    let archive = try workspace.zip("nested.zip", ["UserDocs"], extraArguments: ["-r"])

    let zip = try ZipArchive(url: archive)
    #expect(try zip.text(at: "UserDocs/PRINT.md") == "# PRINT")
    #expect(zip.entries.contains { $0.isDirectory })
}

@Test func refusesAMissingEntry() throws {
    let workspace = try Workspace()
    defer { workspace.discard() }
    _ = try workspace.write("A.md", "a")
    let archive = try workspace.zip("one.zip", ["A.md"])
    let zip = try ZipArchive(url: archive)
    #expect(!zip.contains("B.md"))
    #expect(throws: ZipArchive.Failure.self) { try zip.data(at: "B.md") }
}

@Test func refusesSomethingThatIsNotAZip() throws {
    let workspace = try Workspace()
    defer { workspace.discard() }
    let notAZip = try workspace.write("notes.txt", String(repeating: "x", count: 500))
    #expect(throws: ZipArchive.Failure.self) { try ZipArchive(url: notAZip) }
}

@Test func noticesACorruptedEntry() throws {
    let workspace = try Workspace()
    defer { workspace.discard() }
    let text = String(repeating: "alpha beta gamma\n", count: 100)
    _ = try workspace.write("A.md", text)
    // Stored rather than deflated, so the content sits in a known, wide run
    // of the file and a flipped byte lands in the data instead of in a
    // header — which is what makes this a test of the checksum rather than
    // of the central-directory parser.
    let archive = try workspace.zip("corrupt.zip", ["A.md"], extraArguments: ["-0"])

    var bytes = [UInt8](try Data(contentsOf: archive))
    bytes[100] ^= 0xFF
    try Data(bytes).write(to: archive)

    let zip = try ZipArchive(url: archive)
    #expect(zip.entries[0].method == 0)
    #expect(throws: ZipArchive.Failure.self) { try zip.data(at: "A.md") }
}

@Test func libraryPrefersTheFirstSourceThatHasDocuments() throws {
    let workspace = try Workspace()
    defer { workspace.discard() }
    _ = try workspace.write("pages/ONE.md", "# One")
    _ = try workspace.write("pages/TWO.md", "# Two")
    let archive = try workspace.zip("pages.zip", ["pages"], extraArguments: ["-r"])

    let missing = workspace.root.appendingPathComponent("nowhere.zip")
    let library = try DocumentLibrary(
        searching: [.archive(missing), .archive(archive, prefix: "pages/")],
        extension: "md"
    )
    #expect(library.documents.map(\.name) == ["ONE", "TWO"])
    #expect(library.document(named: "ONE")?.text == "# One")
}

@Test func libraryReadsADirectoryToo() throws {
    let workspace = try Workspace()
    defer { workspace.discard() }
    _ = try workspace.write("loose/A.md", "# A")
    _ = try workspace.write("loose/B.md", "# B")

    let library = try DocumentLibrary(
        searching: [.directory(workspace.root.appendingPathComponent("loose"))],
        extension: "md"
    )
    #expect(library.documents.map(\.name) == ["A", "B"])
}

@Test func libraryReportsWhenThereIsNothingAnywhere() throws {
    let workspace = try Workspace()
    defer { workspace.discard() }
    #expect(throws: (any Error).self) {
        try DocumentLibrary(
            searching: [.directory(workspace.root.appendingPathComponent("absent"))],
            extension: "md"
        )
    }
}
