import Foundation

/// The libraries a project can import, and the order they are searched in.
///
/// BASPROJ_AND_BASLIB.md §6: a `.baslib` is resolved to a directory of `.bas`
/// files and handed to the same import machinery a folder of sources uses.
/// The order is an *order*, not a search, so that adding a library cannot
/// silently shadow a project's own file:
///
///   1. the project's own `Sources/` (the loader's root-relative resolution)
///   2. the project's `Libraries/`
///   3. libraries named in the manifest, in the order listed
///
/// Two libraries offering the same module is the case that cannot be
/// resolved by order, so it is refused at load time, naming both.
public struct LibraryIndex: Sendable {
    /// Where each library's sources are, by its normalized name.
    public let directories: [String: String]
    /// The name each library is spelled with, for messages.
    public let displayNames: [String: String]

    public init(directories: [String: String] = [:], displayNames: [String: String] = [:]) {
        self.directories = directories
        self.displayNames = displayNames
    }

    /// Whether the index has anything in it.
    public var isEmpty: Bool { directories.isEmpty }

    /// A library's source directory, by the name an `IMPORT` spells.
    public func sources(forLibraryNamed name: String) -> String? {
        directories[Self.normalized(name)]
    }

    static func normalized(_ name: String) -> String {
        ((name as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
    }

    /// Reads a project's libraries: everything in `Libraries/`, then the
    /// manifest's list. A library is a directory or a zipped `.baslib`.
    public static func build(root: String, declared: [ProjectManifest.Library]) throws -> LibraryIndex {
        var directories: [String: String] = [:]
        var displayNames: [String: String] = [:]
        var exporters: [String: String] = [:]

        func add(path: String, declaredName: String?) throws {
            let directory = try ProjectContainer.directory(of: path)
            let manifest = LibraryManifest.load(at: directory)
            let name = declaredName ?? manifest?.name ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let key = normalized(name)
            let sources = (directory as NSString).appendingPathComponent("Sources")
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sources, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ProjectContainer.Failure(description: "library \(name) has no Sources directory")
            }
            // Declaration order decides which library a name reaches, but a
            // module offered by two of them cannot be decided that way.
            for export in manifest?.exports ?? [] {
                let exportKey = normalized(export)
                if let already = exporters[exportKey], already != name {
                    throw ProjectContainer.Failure(
                        description: "libraries \(already) and \(name) both export \(export); rename one or drop it"
                    )
                }
                exporters[exportKey] = name
            }
            guard directories[key] == nil else { return }
            directories[key] = sources
            displayNames[key] = name
        }

        let vendored = (root as NSString).appendingPathComponent("Libraries")
        for entry in ((try? FileManager.default.contentsOfDirectory(atPath: vendored)) ?? []).sorted() {
            let path = (vendored as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue || (path as NSString).pathExtension.lowercased() == "baslib" else { continue }
            try add(path: path, declaredName: nil)
        }
        for library in declared {
            let path = (library.path as NSString).isAbsolutePath
                ? library.path
                : (root as NSString).appendingPathComponent(library.path)
            try add(path: path, declaredName: library.name)
        }
        return LibraryIndex(directories: directories, displayNames: displayNames)
    }
}

/// A `.baslib`'s manifest: the project manifest with `kind: "library"`, no
/// entry point, and the modules it offers.
struct LibraryManifest: Decodable {
    let schemaVersion: Int
    let kind: String
    let name: String
    let exports: [String]?

    static func load(at directory: String) -> LibraryManifest? {
        let path = (directory as NSString).appendingPathComponent("library.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(LibraryManifest.self, from: data)
    }
}
