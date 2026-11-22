import Foundation
import BASICProjects

/// Opening a project or a library, whichever shape it arrives in.
///
/// BASPROJ_AND_BASLIB.md §5 asks for one path that handles four things: a
/// zipped `.basproj`, a project directory, a zipped `.baslib`, and a loose
/// `.bas` file. A zip is opened with ProjectKit (BASIC-72), read-only, into a
/// copy of its own, and read from there: a directory is what every other
/// part of the compiler already understands. ProjectKit finds a project one
/// folder down (Finder's Compress), passes over `__MACOSX`, and refuses names
/// that would climb out, on every platform basicc runs on, the iPad included.
///
/// ```text
///   Game.basproj (zip) ──ProjectKit, read-only──▶ <tmp>/basicc-containers/…/files
///   Game.basproj/      ─────────────────────────▶ itself
/// ```
///
/// A zip stays open while the process runs, so its sources stay readable as
/// the compiler works; one that changes on disk is opened again. Each copy is
/// removed when the process ends.
public enum ProjectContainer {
    /// Something about the container the compiler cannot honor.
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// The extensions that are containers rather than sources.
    public static let containerExtensions: Set<String> = ["basproj", "baslib"]

    /// Whether `path` names a zipped container.
    public static func isZippedContainer(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return containerExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// The directory a container's contents live in: itself when it is a
    /// directory, the open zip's copy when it is a zip.
    public static func directory(of path: String) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw Failure(description: "\(path) does not exist")
        }
        if isDirectory.boolValue { return path }
        guard isZippedContainer(path) else { return path }
        return try OpenZips.shared.directory(of: URL(fileURLWithPath: path))
    }
}

/// The zips the process has open, by path: each a read-only ProjectKit project,
/// with the stamp it had when opened.
private final class OpenZips: @unchecked Sendable {
    static let shared = OpenZips()

    private struct Open {
        let project: Project
        let stamp: [String]
    }

    private let lock = NSLock()
    private var open: [String: Open] = [:]

    private init() {
        // Removes every copy when the process ends; atexit takes no captures.
        atexit { OpenZips.shared.closeAll() }
    }

    /// The open zip's directory, opening it, or opening it again when it changed.
    func directory(of zip: URL) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let key = zip.standardizedFileURL.path
        let stamp = Self.stamp(of: zip)
        if let already = open[key], already.stamp == stamp {
            return already.project.workingDirectory.path
        }
        try? open.removeValue(forKey: key)?.project.close()
        let project: Project
        do {
            project = try Project.open(at: zip, as: BASICProjects.types, options: Self.options)
        } catch {
            throw ProjectContainer.Failure(description: "\(zip.path) could not be opened: \(error)")
        }
        let root = project.workingDirectory
        guard ["project.json", "library.json"].contains(where: { (try? project.exists($0)) == true }) else {
            try? project.close()
            throw ProjectContainer.Failure(description: "\(zip.path) has no project.json or library.json")
        }
        open[key] = Open(project: project, stamp: stamp)
        return root.path
    }

    func closeAll() {
        lock.lock()
        defer { lock.unlock() }
        for zip in open.values { try? zip.project.close() }
        open.removeAll()
    }

    /// Read-only, in a copy of its own under the temporary folder, so a build never
    /// waits on an app editing the zip and leaves nothing in Application Support.
    private static let options = ProjectOptions(
        saving: .manual, readOnly: true,
        workingCopies: FileManager.default.temporaryDirectory.appendingPathComponent("basicc-containers", isDirectory: true))

    /// What changes when the zip is written: its size and time.
    private static func stamp(of url: URL) -> [String] {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        return ["\(attributes[.size] ?? "")", "\(attributes[.modificationDate] ?? "")"]
    }
}
