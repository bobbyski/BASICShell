//
//  UserDocs.swift
//  BASICStudio
//
//  The documentation pages Studio ships: their categories, and each page
//  loaded from the bundle. The Documentation inspector (DocsPaneAUI) and its
//  projection (DocsPaneModel) show them.
//

import DocumentArchive
import Foundation

enum UserDocCategory: String, CaseIterable, Identifiable {
    case tutorials
    case reference

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tutorials:
            "Tutorials"
        case .reference:
            "Reference"
        }
    }
}

struct UserDoc: Identifiable, Hashable {
    let id: String
    let title: String
    let category: UserDocCategory
    let content: String

    /// The page the Documentation inspector opens on, first in the menu:
    /// what a newcomer should read before anything else.
    static let startPageID = "TUTORIAL_BEGINNERS.md"

    /// Pages about the shell (BASICShell and its startup file), which mean
    /// nothing where there is no shell: iPhone and iPad today, Android when
    /// Studio runs there. Add a page here to keep it to the desktop.
    static let shellOnlyPageIDs: Set<String> = ["TUTORIAL_BASICRC.md"]

    /// Whether this platform has a shell for the shell's pages to describe.
    static var platformHasShell: Bool {
        #if os(iOS) || os(Android)
        return false
        #else
        return true
        #endif
    }

    /// The pages this platform shows: without a shell, the shell's pages are
    /// left out, and so is any list item that only links to one of them (the
    /// Beginner's Guide's "Where to Go Next"), so no link leads nowhere.
    static func available(_ docs: [UserDoc], hasShell: Bool) -> [UserDoc] {
        guard !hasShell else { return docs }
        return docs
            .filter { !shellOnlyPageIDs.contains($0.id) }
            .map { doc in
                let lines = doc.content.split(separator: "\n", omittingEmptySubsequences: false)
                let kept = lines.filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return true }
                    return !shellOnlyPageIDs.contains { trimmed.contains("](\($0))") }
                }
                guard kept.count != lines.count else { return doc }
                return UserDoc(id: doc.id, title: doc.title, category: doc.category, content: kept.joined(separator: "\n"))
            }
    }

    static func loadAll(hasShell: Bool = platformHasShell) -> [UserDoc] {
        available(loadEverything(), hasShell: hasShell)
    }

    /// Every page the manual has, whatever the platform.
    private static func loadEverything() -> [UserDoc] {
        guard let library = try? DocumentLibrary(searching: sources(), extension: "md") else {
            return []
        }
        return library.documents
            .map { document in
                UserDoc(
                    id: document.path,
                    title: title(from: document.text, fallback: document.name),
                    category: category(from: document.name),
                    content: document.text
                )
            }
            .sorted { left, right in
                if left.category != right.category {
                    return UserDocCategory.allCases.firstIndex(of: left.category)!
                        < UserDocCategory.allCases.firstIndex(of: right.category)!
                }
                if (left.id == startPageID) != (right.id == startPageID) {
                    return left.id == startPageID
                }
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
    }

    /// Where the pages might be, best first.
    ///
    /// The archive the app ships with comes first; the source directory is
    /// searched after it so that editing a page shows up without repacking.
    /// `BASIC_USERDOCS` overrides both and takes either shape.
    private static func sources() -> [DocumentLibrary.Source] {
        var sources: [DocumentLibrary.Source] = []

        if let override = ProcessInfo.processInfo.environment["BASIC_USERDOCS"], !override.isEmpty {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: override, isDirectory: &isDirectory) {
                sources.append(isDirectory.boolValue
                    ? .directory(URL(fileURLWithPath: override))
                    : .archive(URL(fileURLWithPath: override)))
            }
        }
        if let bundled = Bundle.main.url(forResource: "UserDocs", withExtension: "zip") {
            sources.append(.archive(bundled))
        }
        // Only a SwiftPM build has a module bundle; the Xcode app target
        // (project.yml) ships the zip in Bundle.main, found above.
        #if SWIFT_PACKAGE
        if let bundled = Bundle.module.url(forResource: "UserDocs", withExtension: "zip") {
            sources.append(.archive(bundled))
        }
        #endif

        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        sources.append(.directory(currentDirectory.appendingPathComponent("UserDocs")))
        sources.append(.directory(currentDirectory.appendingPathComponent("Code/BASICStudio/UserDocs")))
        sources.append(.directory(
            URL(fileURLWithPath: String(#filePath))
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("UserDocs")
        ))
        return sources
    }

    private static func category(from fileName: String) -> UserDocCategory {
        if fileName.uppercased().hasPrefix("TUTORIAL_") {
            return .tutorials
        }
        return .reference
    }

    private static func title(from content: String, fallback: String) -> String {
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("# ") {
                return String(line.dropFirst(2))
            }
        }
        return fallback.replacingOccurrences(of: "_", with: " ")
    }
}
