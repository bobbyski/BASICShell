import BASICCompilerKit
import CryptoKit
import Foundation

/// What basicc keeps of an imported Swift package once its build folder is gone.
///
/// ```text
///   swift build in <package>/.build-basicc ──▶ gather into the entry ──▶ remove .build-basicc
///
///   ~/Library/Caches/basicc/imports/
///     ActiveUI/   entry.json  ActiveUI.symbols.json  exported.txt
///                 objects/  Modules/  ModuleMaps/  shims/
///     ActiveUI.lock
/// ```
///
/// The build folder of one import ran to gigabytes, and a retry loop grew ActiveUI's to
/// 45 GB (2026-11-08). Bobby's fix: build as before, keep only what the rest of the
/// compile reads (the symbol graph, the objects, the exported symbols, the modules and
/// module maps, the async shim), and remove the folder at once. One entry per module,
/// reused while the compiler and the package's files are as they were; `entry.json`
/// records what it holds and how big it is (`Documents/BASICC_IMPORTS_WITHOUT_BUILDS.md`).
public struct SwiftImportCache: Sendable {
    /// The folder the entries are in.
    public let root: String

    /// `BASICC_IMPORT_CACHE` wins; otherwise the user's caches folder
    /// (`~/Library/Caches/basicc/imports` on the Mac, `~/.cache/basicc/imports` on Linux).
    public init(root: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let root {
            self.root = root
        } else if let override = environment["BASICC_IMPORT_CACHE"], !override.isEmpty {
            self.root = override
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache")
            self.root = caches.appendingPathComponent("basicc/imports").path
        }
    }

    /// How big an entry is, part by part, and how big the build folder it replaced was.
    public struct Sizes: Codable, Equatable, Sendable {
        public var objects: Int64 = 0
        public var modules: Int64 = 0
        public var graph: Int64 = 0
        /// The exported symbols, module maps, shims and `entry.json`.
        public var other: Int64 = 0
        /// Everything kept.
        public var total: Int64 = 0
        /// `.build-basicc` just before it was removed.
        public var buildFolder: Int64 = 0
    }

    /// One module's entry.
    public struct Entry: Sendable {
        public let module: String
        public let directory: String
        /// The objects to link, the module's first, then its in-package targets'.
        public let objects: [String]
        public let moduleMaps: [String]
        public let sizes: Sizes

        public var symbolGraph: String { (directory as NSString).appendingPathComponent("\(module).symbols.json") }
        public var modulesDirectory: String { (directory as NSString).appendingPathComponent("Modules") }
        public var shimsDirectory: String { (directory as NSString).appendingPathComponent("shims") }

        /// The symbols the module's objects define.
        public func exported() -> Set<String> {
            let file = (directory as NSString).appendingPathComponent("exported.txt")
            let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            return Set(text.split(separator: "\n").map(String.init))
        }
    }

    /// `entry.json`.
    struct Record: Codable {
        var module: String
        var package: String
        var stamp: String
        var made: String
        /// Relative to the entry.
        var objects: [String]
        var moduleMaps: [String]
        var sizes: Sizes
    }

    /// The entry for `module`, if one was made from exactly this `stamp` and is whole.
    public func entry(for module: String, stamp: String) -> Entry? {
        let directory = (root as NSString).appendingPathComponent(module)
        guard let data = FileManager.default.contents(atPath: (directory as NSString).appendingPathComponent("entry.json")),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.module == module, record.stamp == stamp else { return nil }
        let entry = Entry(module: module, directory: directory,
                          objects: record.objects.map { (directory as NSString).appendingPathComponent($0) },
                          moduleMaps: record.moduleMaps.map { (directory as NSString).appendingPathComponent($0) },
                          sizes: record.sizes)
        let needed = [entry.symbolGraph] + entry.objects + entry.moduleMaps
        guard needed.allSatisfy(FileManager.default.fileExists(atPath:)) else { return nil }
        return entry
    }

    /// Every entry, for `basicc import-cache`.
    public func entries() -> [(module: String, sizes: Sizes, made: String)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.sorted().compactMap { name in
            let file = ((root as NSString).appendingPathComponent(name) as NSString).appendingPathComponent("entry.json")
            guard let data = FileManager.default.contents(atPath: file),
                  let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
            return (record.module, record.sizes, record.made)
        }
    }

    // MARK: - Making an entry

    /// Copies what the compile needs out of `scratch`, records it, and swaps it in for
    /// any older entry of `module`. `objects` are by target, the module's own first.
    public func store(module: String, package: String, stamp: String, symbolGraph: String,
                      objects: [(target: String, files: [String])], exported: Set<String>,
                      scratch: String) throws -> Entry {
        let manager = FileManager.default
        try manager.createDirectory(atPath: root, withIntermediateDirectories: true)
        // A staging folder from a run that died halfway is only in the way.
        for name in (try? manager.contentsOfDirectory(atPath: root)) ?? [] where name.hasPrefix(".\(module)-") {
            try? manager.removeItem(atPath: (root as NSString).appendingPathComponent(name))
        }
        let staging = (root as NSString).appendingPathComponent(".\(module)-\(UUID().uuidString)")
        try manager.createDirectory(atPath: staging, withIntermediateDirectories: true)
        var record = Record(module: module, package: package, stamp: stamp,
                            made: ISO8601DateFormatter().string(from: Date()),
                            objects: [], moduleMaps: [], sizes: Sizes())
        do {
            try manager.copyItem(atPath: symbolGraph, toPath: (staging as NSString).appendingPathComponent("\(module).symbols.json"))
            for (target, files) in objects {
                let folder = "objects/\(target)"
                try manager.createDirectory(atPath: (staging as NSString).appendingPathComponent(folder), withIntermediateDirectories: true)
                for file in files {
                    let kept = "\(folder)/\((file as NSString).lastPathComponent)"
                    try manager.copyItem(atPath: file, toPath: (staging as NSString).appendingPathComponent(kept))
                    record.objects.append(kept)
                }
            }
            try exported.sorted().joined(separator: "\n")
                .write(toFile: (staging as NSString).appendingPathComponent("exported.txt"), atomically: true, encoding: .utf8)
            try Self.copyModules(from: scratch, to: (staging as NSString).appendingPathComponent("Modules"))
            let maps = (scratch as NSString).appendingPathComponent("out/Intermediates.noindex/GeneratedModuleMaps")
            for name in ((try? manager.contentsOfDirectory(atPath: maps)) ?? []).sorted() where name.hasSuffix(".modulemap") {
                try manager.createDirectory(atPath: (staging as NSString).appendingPathComponent("ModuleMaps"), withIntermediateDirectories: true)
                let kept = "ModuleMaps/\(name)"
                try manager.copyItem(atPath: (maps as NSString).appendingPathComponent(name),
                                     toPath: (staging as NSString).appendingPathComponent(kept))
                record.moduleMaps.append(kept)
            }
            try manager.createDirectory(atPath: (staging as NSString).appendingPathComponent("shims"), withIntermediateDirectories: true)

            record.sizes.objects = Self.size(of: (staging as NSString).appendingPathComponent("objects"))
            record.sizes.modules = Self.size(of: (staging as NSString).appendingPathComponent("Modules"))
            record.sizes.graph = Self.size(of: (staging as NSString).appendingPathComponent("\(module).symbols.json"))
            record.sizes.buildFolder = Self.size(of: scratch)
            let all = Self.size(of: staging)
            record.sizes.other = all - record.sizes.objects - record.sizes.modules - record.sizes.graph
            record.sizes.total = all
            try Self.write(record, in: staging)

            let final = (root as NSString).appendingPathComponent(module)
            if manager.fileExists(atPath: final) { try manager.removeItem(atPath: final) }
            try manager.moveItem(atPath: staging, toPath: final)
        } catch {
            try? manager.removeItem(atPath: staging)
            throw error
        }
        guard let entry = entry(for: module, stamp: stamp) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: (root as NSString).appendingPathComponent(module)])
        }
        return entry
    }

    /// Records the size of the entry at `directory` again, after a shim was compiled into it.
    public static func recordSize(ofEntryAt directory: String) {
        let file = (directory as NSString).appendingPathComponent("entry.json")
        guard let data = FileManager.default.contents(atPath: file),
              var record = try? JSONDecoder().decode(Record.self, from: data) else { return }
        let all = size(of: directory)
        record.sizes.other = all - record.sizes.objects - record.sizes.modules - record.sizes.graph
        record.sizes.total = all
        try? write(record, in: directory)
    }

    static func write(_ record: Record, in directory: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: URL(fileURLWithPath: (directory as NSString).appendingPathComponent("entry.json")))
    }

    /// The `.swiftmodule`s the build left beside its products, without their
    /// documentation and source information: a compile needs only the module.
    ///
    /// ```text
    ///   swiftbuild  <scratch>/release → out/Products/Release/ActiveUI.swiftmodule/arm64-apple-macos.swiftmodule
    ///   native      <scratch>/release/Modules/ActiveUI.swiftmodule
    /// ```
    static func copyModules(from scratch: String, to destination: String) throws {
        let manager = FileManager.default
        let products = URL(fileURLWithPath: (scratch as NSString).appendingPathComponent("release")).resolvingSymlinksInPath().path
        try manager.createDirectory(atPath: destination, withIntermediateDirectories: true)
        for folder in [products, (products as NSString).appendingPathComponent("Modules")] {
            for name in (try? manager.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".swiftmodule") {
                let source = (folder as NSString).appendingPathComponent(name)
                let target = (destination as NSString).appendingPathComponent(name)
                guard !manager.fileExists(atPath: target) else { continue }
                var isDirectory: ObjCBool = false
                manager.fileExists(atPath: source, isDirectory: &isDirectory)
                guard isDirectory.boolValue else {
                    try manager.copyItem(atPath: source, toPath: target)
                    continue
                }
                try manager.createDirectory(atPath: target, withIntermediateDirectories: true)
                for file in (try? manager.contentsOfDirectory(atPath: source)) ?? [] where file.hasSuffix(".swiftmodule") {
                    try manager.copyItem(atPath: (source as NSString).appendingPathComponent(file),
                                         toPath: (target as NSString).appendingPathComponent(file))
                }
            }
        }
    }

    // MARK: - The stamp

    /// What an entry is valid for: this reader, the Swift compiler, the module, and
    /// the size and date of every file of the package and of its path dependencies,
    /// outside their build folders. Any change makes a new stamp, and a new entry.
    public static func stamp(module: String, package: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("basicc import cache 2\n\(module)\n\(package)\n".utf8))
        hasher.update(data: Data(compilerVersion.utf8))
        for folder in [package] + pathDependencies(of: package) {
            hasher.update(data: Data(listing(of: folder).utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `swiftc -version`, asked once.
    static let compilerVersion: String = {
        (try? ProcessRunner.run("/usr/bin/xcrun", ["swiftc", "-version"]).stdout) ?? ""
    }()

    /// The folders of the package's own path dependencies (TUIKit's RichSwift); a
    /// versioned one is pinned in `Package.resolved`, which the listing covers.
    static func pathDependencies(of package: String) -> [String] {
        guard let described = try? ProcessRunner.run("/usr/bin/xcrun", ["swift", "package", "describe", "--type", "json"],
                                                     workingDirectory: package),
              described.exitCode == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(described.stdout.utf8)) as? [String: Any],
              let dependencies = json["dependencies"] as? [[String: Any]] else { return [] }
        return dependencies.compactMap { $0["path"] as? String }.sorted()
    }

    /// Every file under `folder`, with its size and date, one per line, sorted;
    /// build folders, `.git` and `.swiftpm` left out.
    static func listing(of folder: String) -> String {
        let root = URL(fileURLWithPath: folder)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return "" }
        var lines: [String] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if name.hasPrefix(".build") || ["Build", ".git", ".swiftpm", "DerivedData"].contains(name) {
                    walker.skipDescendants()
                }
                continue
            }
            let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            lines.append("\(url.path.dropFirst(root.path.count))\t\(values?.fileSize ?? 0)\t\(Int64(date * 1000))")
        }
        return "\(folder)\n" + lines.sorted().joined(separator: "\n")
    }

    // MARK: - One build at a time

    /// Runs `body` holding `module`'s lock, so two basicc runs never build the same
    /// package at once and neither removes the folder the other is using. `waiting`
    /// is called once, when another run holds it.
    public func withLock<T>(_ module: String, waiting: () -> Void, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let path = (root as NSString).appendingPathComponent("\(module).lock")
        let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return try body() }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            waiting()
            flock(descriptor, LOCK_EX)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    // MARK: - Sizes

    /// What one module's entry may take before basicc warns (D2 in
    /// `Documents/BASICC_IMPORTS_WITHOUT_BUILDS.md`, to revisit once ActiveUI and TUIKit are measured).
    public static let budget: Int64 = 100_000_000

    /// The warning for an entry over `budget`, naming its biggest part; nil within it.
    public static func budgetWarning(module: String, sizes: Sizes, budget: Int64 = budget) -> String? {
        guard sizes.total > budget else { return nil }
        let parts: [(name: String, bytes: Int64)] = [("objects", sizes.objects), ("modules", sizes.modules),
                                                     ("graph", sizes.graph), ("other", sizes.other)]
        let biggest = parts.max { $0.bytes < $1.bytes } ?? ("objects", sizes.objects)
        return "basicc: warning: \(module)'s import cache entry is \(describe(sizes.total)), over its \(describe(budget)) budget; "
            + "the biggest part is \(biggest.name) (\(describe(biggest.bytes)))"
    }

    /// The bytes `path` takes on disk: a file, or everything under a folder.
    public static func size(of path: String) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { return 0 }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        func bytes(_ url: URL) -> Int64 {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        let url = URL(fileURLWithPath: path)
        guard isDirectory.boolValue else { return bytes(url) }
        var total: Int64 = 0
        if let walker = manager.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
            for case let item as URL in walker { total += bytes(item) }
        }
        return total
    }

    /// `41.2 MB`, `2.3 GB`, `880 KB`.
    public static func describe(_ bytes: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return unit == 0 ? "\(bytes) bytes" : String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }
}

/// The build folders basicc is using right now, removed if it is interrupted.
///
/// `timeout` and Control-C stop `basicc`, not the `swift build` it started. Without this,
/// the build ran on, the folder stayed, and the next try started another build beside
/// it (2026-11-08).
public enum SwiftBuildFolders {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var folders: Set<String> = []
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    /// `folder` is being built in; remove it if basicc is interrupted.
    public static func begin(_ folder: String) {
        lock.lock(); defer { lock.unlock() }
        folders.insert(folder)
    }

    /// `folder` is gone, or no longer basicc's to remove.
    public static func end(_ folder: String) {
        lock.lock(); defer { lock.unlock() }
        folders.remove(folder)
    }

    /// On SIGINT, SIGTERM and SIGHUP: stop the tools basicc started, remove the build
    /// folders it is using, and exit as the signal would have. Called once, by `basicc`.
    public static func removeOnInterrupt() {
        lock.lock(); defer { lock.unlock() }
        guard sources.isEmpty else { return }
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { interrupted(by: number) }
            source.resume()
            sources.append(source)
        }
    }

    private static func interrupted(by number: Int32) -> Never {
        ProcessRunner.interruptAll(waitingUpTo: 10)
        lock.lock()
        let remaining = folders
        lock.unlock()
        for folder in remaining {
            try? FileManager.default.removeItem(atPath: folder)
            FileHandle.standardError.write(Data("basicc: interrupted; removed \(folder)\n".utf8))
        }
        exit(128 + number)
    }
}
