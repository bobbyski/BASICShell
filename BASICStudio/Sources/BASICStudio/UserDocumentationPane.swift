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

    private var selectedDocBinding: Binding<UserDoc.ID> {
        Binding(
            get: { selectedDocID ?? docs.first?.id ?? "" },
            set: { selectedDocID = $0 }
        )
    }

    private var selectedDoc: UserDoc? {
        let id = selectedDocID ?? docs.first?.id
        return docs.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Documentation")
                    .font(.headline)
                Spacer()
                if !docs.isEmpty {
                    Picker("Topic", selection: selectedDocBinding) {
                        ForEach(docs) { doc in
                            Text(doc.title).tag(doc.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260)
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

struct UserDoc: Identifiable, Hashable {
    let id: String
    let title: String
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
                    return UserDoc(
                        id: url.lastPathComponent,
                        title: title(from: content, fallback: url.deletingPathExtension().lastPathComponent),
                        content: content
                    )
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

    private static func title(from content: String, fallback: String) -> String {
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("# ") {
                return String(line.dropFirst(2))
            }
        }
        return fallback.replacingOccurrences(of: "_", with: " ")
    }
}
