import BASICCore
import AppKit
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
        for directory in documentationDirectories() {
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                continue
            }

            let docs = files
                .filter { $0.pathExtension.lowercased() == "md" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { url -> UserDoc? in
                    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                    let fileName = url.deletingPathExtension().lastPathComponent
                    return UserDoc(
                        id: url.lastPathComponent,
                        title: title(from: content, fallback: fileName),
                        category: category(from: fileName),
                        content: content
                    )
                }
                .sorted { left, right in
                    if left.category != right.category {
                        return UserDocCategory.allCases.firstIndex(of: left.category)! < UserDocCategory.allCases.firstIndex(of: right.category)!
                    }
                    return left.title.localizedStandardCompare(right.title) == .orderedAscending
                }

            if !docs.isEmpty {
                return docs
            }
        }

        return []
    }

    private static func documentationDirectories() -> [URL] {
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = URL(fileURLWithPath: String(#filePath))
        return [
            currentDirectory.appendingPathComponent("UserDocs"),
            currentDirectory.appendingPathComponent("Code/BASICStudio/UserDocs"),
            sourceURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("UserDocs")
        ]
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
