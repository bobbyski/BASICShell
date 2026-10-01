//
//  StudioCloudStorage.swift
//  BASICStudio
//
//  Programs in iCloud Drive, on iPad, iPhone and the Mac.
//

import Foundation

/// Where programs live when they are kept in iCloud Drive: the app's own
/// iCloud folder, which Files and Finder show as "BASICStudio". A program
/// saved there on the iPad is in the same folder on the Mac and the iPhone.
///
/// - **iPad and iPhone** reach it through the app's iCloud container
///   (the entitlements and `NSUbiquitousContainers` in `project.yml`).
/// - **The Mac** runs outside the sandbox, so it can use the same folder
///   where macOS keeps it, `~/Library/Mobile Documents`, without the iCloud
///   entitlement and the provisioning that comes with it. If the Mac app is
///   ever given the entitlement, the container is used directly instead.
/// - **Windows and Linux** have no iCloud; Documents/ICLOUD_API.md is the
///   plan for a cloud store there.
enum StudioCloudStorage {
    /// The app's iCloud container.
    static let containerIdentifier = "iCloud.com.aibasic.BASICStudio"

    /// What iCloud Drive is doing for Studio, as Settings reports it.
    enum Status: Equatable {
        /// Programs are kept in this folder.
        case on(URL)
        /// The setting is off; programs stay where the working folder is.
        case off
        /// The setting is on, but iCloud Drive is off or not signed in.
        case unavailable
        /// Still finding the folder.
        case checking
    }

    /// The folder programs go in, created if it is not there yet, or nil
    /// when iCloud Drive is off or no one is signed in.
    ///
    /// The first lookup of a container can take a while, so call this off
    /// the main thread, as Apple asks.
    static func documentsFolder() -> URL? {
        let fileManager = FileManager.default
        var container: URL?
        if fileManager.ubiquityIdentityToken != nil {
            container = fileManager.url(forUbiquityContainerIdentifier: containerIdentifier)
        }
        #if os(macOS)
        if container == nil {
            container = macContainerOnDisk()
        }
        #endif
        guard let container else { return nil }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        do {
            try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return documents
    }

    #if os(macOS)
    /// The container where macOS keeps it on disk, when iCloud Drive is on:
    /// its own folder, `com~apple~CloudDocs`, is the sign.
    static func macContainerOnDisk(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let mobileDocuments = home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
        let iCloudDrive = mobileDocuments.appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: iCloudDrive.path) else { return nil }
        return mobileDocuments.appendingPathComponent(onDiskName(of: containerIdentifier), isDirectory: true)
    }
    #endif

    /// A container's folder name on disk: `iCloud.com.x.y` is
    /// `iCloud~com~x~y`.
    static func onDiskName(of identifier: String) -> String {
        identifier.replacingOccurrences(of: ".", with: "~")
    }

    /// Asks iCloud for everything in `folder` that is not on this device
    /// yet. A program saved on another device arrives as a placeholder,
    /// `.name.bas.icloud`, until it is downloaded, and LOAD would not find it.
    static func downloadMissing(in folder: URL) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names {
            guard let real = realName(ofPlaceholder: name) else { continue }
            try? fileManager.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(real))
        }
    }

    /// The file a placeholder stands for: `.hello.bas.icloud` is
    /// `hello.bas`. Nil for anything that is not a placeholder.
    static func realName(ofPlaceholder name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    /// Writes `text` to `url`. A file in iCloud is written through a file
    /// coordinator, so the sync sees one change rather than racing the write.
    static func write(_ text: String, to url: URL) throws {
        guard isInCloud(url) else {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                try text.write(to: target, atomically: true, encoding: .utf8)
            } catch {
                writeError = error
            }
        }
        if let error = coordinationError ?? writeError {
            throw error
        }
    }

    /// Whether `url` is in an iCloud container, by where it is rather than
    /// by asking iCloud, which a Mac without the entitlement cannot.
    static func isInCloud(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains("/Mobile Documents/") || FileManager.default.isUbiquitousItem(at: url)
    }
}
