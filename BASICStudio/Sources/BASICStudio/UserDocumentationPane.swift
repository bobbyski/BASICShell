import BASICCore
import AppKit
import DocumentArchive
import CoreText
import GameController
import MarkdownUI
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import VectorTerminalSDK
import WebKit

struct UserDocumentationPane: View {
    @State private var docs = UserDoc.loadAll()
    @State private var selectedDocID: UserDoc.ID?

    private var selectedDoc: UserDoc? {
        let id = selectedDocID ?? docs.first?.id
        return docs.first { $0.id == id }
    }

    private func docs(in category: UserDocCategory) -> [UserDoc] {
        docs.filter { $0.category == category }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Documentation")
                    .font(.headline)
                Spacer()
                if !docs.isEmpty {
                    Menu {
                        ForEach(UserDocCategory.allCases) { category in
                            let sectionDocs = docs(in: category)
                            if !sectionDocs.isEmpty {
                                Menu(category.title) {
                                    ForEach(sectionDocs) { doc in
                                        Button {
                                            selectedDocID = doc.id
                                        } label: {
                                            HStack {
                                                Text(doc.title)
                                                if selectedDocID == doc.id || (selectedDocID == nil && docs.first?.id == doc.id) {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "book")
                            Text(selectedDoc?.title ?? "Documentation Menu")
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
                if let selectedDoc {
                    Markdown(selectedDoc.content)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                } else {
                    Text("No documentation found.")
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
        if let bundled = Bundle.module.url(forResource: "UserDocs", withExtension: "zip") {
            sources.append(.archive(bundled))
        }

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
