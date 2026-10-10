import BASICRecipes
import BASICCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreText
import GameController
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

    /// Where its project folder is among ``parts``, when it is the program
    /// of a project: `apps/contacts.basproj/main`.
    private var projectIndex: Int? {
        parts.firstIndex { $0.lowercased().hasSuffix("." + BASICProjectFolder.fileExtension) }
    }

    /// The project it is the program of, `apps/contacts.basproj`, or nil.
    /// Opened from Examples, a project opens as a project (BASIC-24).
    var projectFolder: String? {
        projectIndex.map { parts[...$0].joined(separator: "/") }
    }

    /// Whether it is a program with a folder of its own: a project's, or a
    /// folder's whose file is its `main` or its namesake (`apps/POS/pos`).
    /// A category's own files never count, so `games/roids` is a file.
    var hasOwnFolder: Bool {
        if projectIndex != nil { return true }
        let parts = parts
        guard parts.count >= 3, let name = parts.last?.lowercased() else { return false }
        return name == "main" || name == parts[parts.count - 2].lowercased()
    }

    /// Its name on the Examples menu: the file's, or for a program with a
    /// folder of its own, the folder's, without `.basproj`.
    var title: String {
        let parts = parts
        if let index = projectIndex {
            return Self.words(BASICProjectFolder.displayName(ofFolder: parts[index]))
        }
        return Self.words(hasOwnFolder ? parts[parts.count - 2] : parts.last ?? path)
    }

    /// The folders it sits in on the Examples menu, outermost first:
    /// `["games"]` for `games/roids`, `["apps"]` for `apps/contacts.basproj/main`.
    var menuFolders: [String] {
        if let index = projectIndex { return Array(parts[..<index]) }
        return Array(parts.dropLast(hasOwnFolder ? 2 : 1))
    }

    /// `aui-gallery` as `Aui Gallery`, `GradeBook` as `Grade Book`: hyphens
    /// become spaces, a name written in camel case comes apart into its
    /// words, and each word starts in capitals.
    static func words(_ name: String) -> String {
        name.split(separator: "-")
            .flatMap { camelWords(String($0)) }
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    /// `ActiveUICounterDemo` as `Active`, `UI`, `Counter`, `Demo`: a word
    /// starts at a capital after a small letter or a digit, or at the last
    /// capital of a run that a small letter follows. A name in capitals
    /// alone, `POS`, stays one word.
    private static func camelWords(_ part: String) -> [String] {
        let letters = Array(part)
        var words: [String] = []
        var current = ""
        for (index, letter) in letters.enumerated() {
            if index > 0, letter.isUppercase {
                let before = letters[index - 1]
                let after = index + 1 < letters.count ? letters[index + 1] : nil
                if before.isLowercase || before.isNumber || (before.isUppercase && after?.isLowercase == true) {
                    words.append(current)
                    current = ""
                }
            }
            current.append(letter)
        }
        words.append(current)
        return words
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
    private static let titles = ["activeui": "ActiveUI", "tui": "TUI", "input-events": "Input and Events",
                                 desktopOnly: "Desktop Only"]

    /// Programs that cannot run on an iPad or iPhone (`longWait`, shell job
    /// control): listed on the Mac, last, and left out on iOS.
    static let desktopOnly = "desktopOnly"

    /// Whether the example at `path` (`desktopOnly/longWait`) is offered on
    /// this kind of device.
    static func isOffered(_ path: String, onMobile: Bool) -> Bool {
        !(onMobile && path.split(separator: "/").first.map(String.init) == desktopOnly)
    }

    /// The categories: games first, as the ones people open first; then the
    /// others by what they show, the language, then what only a desktop
    /// runs; folders not listed here follow, by name.
    static let order = ["games", "graphics", "sound", "input-events", "files", "data", "network", "apps", "activeui", "tui", "language",
                        desktopOnly]

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
