import BASICCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import DocumentArchive
import CoreText
import GameController
import MarkdownUI
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import VectorTerminalSDK
import WebKit

#if os(macOS)
// The SwiftUI shell's Documentation pane, which is macOS-only. `UserDoc`
// below is shared with the ActiveUI shell's DocsPaneAUI.
struct UserDocumentationPane: View {
    @State private var docs = UserDoc.loadAll()
    @State private var selectedDocID: UserDoc.ID?

    var body: some View {
        // What is drawn comes from the projection, which the ActiveUI pane
        // reads too. The pages and the choice stay this view's state.
        let pane = DocsPaneModel(docs: docs, selectedID: selectedDocID)
        VStack(spacing: 0) {
            HStack {
                Text(DocsPaneModel.heading)
                    .font(.headline)
                Spacer()
                if pane.showsMenu {
                    Menu {
                        ForEach(pane.sections, id: \.title) { section in
                            Menu(section.title) {
                                ForEach(section.items, id: \.id) { item in
                                    Button {
                                        selectedDocID = item.id
                                    } label: {
                                        HStack {
                                            Text(item.title)
                                            if item.isChecked {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "book")
                            Text(pane.menuTitle)
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.button)
                    .frame(maxWidth: 280, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                if let selectedDoc = pane.selectedDoc {
                    Markdown(selectedDoc.content)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                } else {
                    Text(DocsPaneModel.emptyText)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            selectedDocID = selectedDocID ?? docs.first?.id
        }
    }
}
#endif

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

    static func loadAll() -> [UserDoc] {
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
