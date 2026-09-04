import Foundation

/// Opening a project or a library, whichever shape it arrives in.
///
/// BASPROJ_AND_BASLIB.md §5 asks for one path that handles four things: a
/// zipped `.basproj`, a project directory, a zipped `.baslib`, and a loose
/// `.bas` file. A zip is unpacked to a temporary directory and read from
/// there — deliberately unclever, because editing a zip in place turns a
/// crash into a corrupted project rather than a lost edit, and because a
/// directory is what every other part of the compiler already understands.
public enum ProjectContainer {
    /// Something about the container the compiler cannot honor.
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Where an unpacked container was put, kept for the process's life so
    /// the sources stay readable while the compiler works on them.
    nonisolated(unsafe) private static var unpacked: [String: String] = [:]

    /// The extensions that are containers rather than sources.
    public static let containerExtensions: Set<String> = ["basproj", "baslib"]

    /// Whether `path` names a zipped container.
    public static func isZippedContainer(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return containerExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// The directory a container's contents live in: itself when it is a
    /// directory, an unpacked copy when it is a zip.
    ///
    /// A container may be zipped with its files at the top level or inside
    /// one folder — both are what a person gets from Finder's Compress — so
    /// the manifest is found either way.
    public static func directory(of path: String) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw Failure(description: "\(path) does not exist")
        }
        if isDirectory.boolValue { return path }
        guard isZippedContainer(path) else { return path }
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        if let already = unpacked[key], FileManager.default.fileExists(atPath: already) { return already }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("basicc-container-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        let result = try ProcessRunner.run("/usr/bin/unzip", ["-q", "-o", path, "-d", destination])
        guard result.exitCode == 0 else {
            throw Failure(description: "\(path) could not be unpacked: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let root = try manifestRoot(under: destination, container: path)
        unpacked[key] = root
        return root
    }

    /// The directory inside an unpacked container that holds its manifest.
    private static func manifestRoot(under destination: String, container: String) throws -> String {
        if hasManifest(destination) { return destination }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: destination)) ?? []
        for entry in entries where !entry.hasPrefix("__MACOSX") {
            let candidate = (destination as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if hasManifest(candidate) { return candidate }
        }
        throw Failure(description: "\(container) has no project.json or library.json")
    }

    private static func hasManifest(_ directory: String) -> Bool {
        ["project.json", "library.json"].contains { FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent($0)) }
    }
}
