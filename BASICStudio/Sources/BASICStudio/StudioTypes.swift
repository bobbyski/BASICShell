import BASICCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreText
import GameController
import MarkdownUI
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import VectorTerminalSDK
import WebKit

enum StudioPane {
    case editor
    case console
}

enum InspectorPane {
    case debug
    case docs
    case logs
}

enum LogIssuer: String, CaseIterable, Identifiable {
    case user = "U"
    case basic = "B"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .user: return "User"
        case .basic: return "BASIC"
        }
    }
}

struct StudioLogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let issuer: LogIssuer
    let level: String
    let module: String
    let text: String
}

struct BundledExample: Identifiable, Hashable {
    let path: String

    var id: String { path }

    private var parts: [String] { path.split(separator: "/").map(String.init) }

    /// Whether it is a program with a folder of its own, `apps/contacts/main`
    /// or `apps/POS/pos`: its file is the folder's `main` or its namesake.
    /// A category's own files never count, so `games/roids` is a file.
    var hasOwnFolder: Bool {
        let parts = parts
        guard parts.count >= 3, let name = parts.last?.lowercased() else { return false }
        return name == "main" || name == parts[parts.count - 2].lowercased()
    }

    /// Its name on the Examples menu: the file's, or for a program with a
    /// folder of its own, the folder's.
    var title: String {
        let parts = parts
        return Self.words(hasOwnFolder ? parts[parts.count - 2] : parts.last ?? path)
    }

    /// The folders it sits in on the Examples menu, outermost first:
    /// `["games"]` for `games/roids`, `["apps"]` for `apps/contacts/main`.
    var menuFolders: [String] { Array(parts.dropLast(hasOwnFolder ? 2 : 1)) }

    /// `aui-gallery` as `Aui Gallery`: hyphens become spaces, and each word
    /// starts in capitals.
    static func words(_ name: String) -> String {
        name.split(separator: "-")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    /// The whole path in words, `Games / Roids`, for a message about it.
    var menuTitle: String {
        path.split(separator: "/").map { Self.words(String($0)) }.joined(separator: " / ")
    }
}

/// The bundled examples as the Examples menus show them: a tree that mirrors
/// the folders of `basicPrograms/demos`, a submenu per folder at any depth.
struct BundledExampleFolder: Equatable {
    /// The folder's own name, `games`; empty for the demos folder itself.
    let name: String
    /// Its subfolders: categories in ``order``, deeper ones by title.
    let folders: [BundledExampleFolder]
    /// The programs directly in it, by title.
    let examples: [BundledExample]

    var title: String { Self.titles[name] ?? BundledExample.words(name) }

    /// Names the folder's own spelling cannot give.
    private static let titles = ["activeui": "ActiveUI", "tui": "TUI", "input-events": "Input and Events"]

    /// The categories: games first, as the ones people open first; then the
    /// others by what they show, the language last; folders not listed here
    /// follow, by name.
    static let order = ["games", "graphics", "sound", "input-events", "files", "data", "network", "apps", "activeui", "tui", "language"]

    /// Every program in the tree, in menu order: a folder's subfolders, then
    /// its own programs.
    var allExamples: [BundledExample] { folders.flatMap(\.allExamples) + examples }

    /// `examples` arranged by the folders they are in.
    static func tree(_ examples: [BundledExample]) -> BundledExampleFolder {
        folder("", isRoot: true, examples.map { ($0.menuFolders[...], $0) })
    }

    private static func folder(_ name: String, isRoot: Bool, _ contents: [(ArraySlice<String>, BundledExample)]) -> BundledExampleFolder {
        var here: [BundledExample] = []
        var below: [String: [(ArraySlice<String>, BundledExample)]] = [:]
        for (folders, example) in contents {
            if let next = folders.first {
                below[next, default: []].append((folders.dropFirst(), example))
            } else {
                here.append(example)
            }
        }
        let rank = { (folder: String) in isRoot ? order.firstIndex(of: folder) ?? order.count : 0 }
        let names = below.keys.sorted { left, right in
            rank(left) != rank(right) ? rank(left) < rank(right) : left.localizedStandardCompare(right) == .orderedAscending
        }
        return BundledExampleFolder(
            name: name,
            folders: names.map { folder($0, isRoot: false, below[$0] ?? []) },
            examples: here.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        )
    }
}

enum TerminalInputOperation {
    case append(String)
    case submit(String)
    case lineInputExit(String, String)
    case key(String)
}
