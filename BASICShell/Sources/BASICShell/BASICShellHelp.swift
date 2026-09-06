//
//  BASICShellHelp.swift
//  BASICShell
//
//  The manual `HELP` opens.
//
//      ┌ File ───────────────────────────────────────────────────┐
//      │ ▾ TUTORIALS          │ # PRINT                          │
//      │   A First Program    │                                  │
//      │ ▾ REFERENCE          │ Writes to the console.           │
//      │ ▸ PRINT              │                                  │
//      │   READ               │ ## Syntax                        │
//      └ Reference · PRINT ─────────────── ↑↓ topic   Esc close ─┘
//
//  ## The same pages Studio shows
//
//  Studio's documentation pane reads a directory of markdown files and groups
//  them by filename: `TUTORIAL_*` are tutorials, everything else is reference.
//  This reads that same directory, applies the same two rules, and renders the
//  same text — so a page corrected for Studio is corrected here, and there is
//  no second copy of the manual to drift out of date.
//
//  Which directory that is depends on how the shell was started, and the list
//  in ``ShellHelpLibrary/directories()`` is that question answered. The one
//  case worth naming: an *installed* shell has no repository to look in, so
//  `buildtosystem.sh` copies the pages next to the demo programs it already
//  installs, and the second candidate is where they land.
//

import BASICCore
import DocumentArchive
import Foundation
import TUIKit

#if canImport(Darwin)
import Darwin
#endif

// MARK: - The pages

/// One page of the manual.
struct ShellHelpTopic {
    /// Studio's two groupings, in Studio's order.
    enum Group: String, CaseIterable {
        case tutorials
        case reference

        var title: String {
            switch self {
            case .tutorials: "Tutorials"
            case .reference: "Reference"
            }
        }
    }

    /// The file, without `.md` — what `HELP PRINT` matches against.
    let name: String
    /// The page's `# ` heading, or the file name when it has none.
    let title: String
    let group: Group
    let content: String
}

/// Finding and reading the manual's pages.
///
/// The pages ship as one zip — `UserDocs.zip`, built from the source
/// directory by `Scripts/pack-userdocs.sh` — and are read out of it in
/// process by ``DocumentArchive``. An archive is one file to install, one
/// file to sign, and cannot arrive half-copied the way a directory of a
/// hundred small files can.
///
/// The source directory is still searched, last, so that someone editing a
/// page sees the edit without repacking anything.
enum ShellHelpLibrary {

    /// Every page, tutorials first and alphabetical within a group — the
    /// order Studio's menu lists them in.
    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> [ShellHelpTopic] {
        guard let library = try? DocumentLibrary(searching: sources(environment: environment), extension: "md") else {
            return []
        }
        return library.documents
            .map { document in
                ShellHelpTopic(
                    name: document.name,
                    title: title(of: document.text, fallback: document.name),
                    group: group(of: document.name),
                    content: document.text
                )
            }
            .sorted { left, right in
                if left.group != right.group {
                    return Group.allCases.firstIndex(of: left.group)!
                        < Group.allCases.firstIndex(of: right.group)!
                }
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
    }

    private typealias Group = ShellHelpTopic.Group

    /// Where the pages might be, best first.
    ///
    /// `BASIC_USERDOCS` comes first and takes either shape, so a person
    /// working on the manual can point the shell at a directory of drafts or
    /// at an archive they have just built.
    static func sources(environment: [String: String] = ProcessInfo.processInfo.environment) -> [DocumentLibrary.Source] {
        var sources: [DocumentLibrary.Source] = []

        if let override = environment["BASIC_USERDOCS"], !override.isEmpty {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: override, isDirectory: &isDirectory) {
                sources.append(isDirectory.boolValue
                    ? .directory(URL(fileURLWithPath: override))
                    : .archive(URL(fileURLWithPath: override)))
            }
        }

        // The archive this build shipped with. `Bundle.module` finds it
        // beside the executable, which is where the installer puts it.
        if let bundled = Bundle.module.url(forResource: "UserDocs", withExtension: "zip") {
            sources.append(.archive(bundled))
        }

        // An install that has the archive next to the demo bundle rather than
        // inside one.
        if let executable = Bundle.main.executablePath {
            let prefix = URL(fileURLWithPath: executable)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            sources.append(.archive(prefix.appendingPathComponent("lib/basicshell/UserDocs.zip")))
        }

        // The source directory, for someone editing a page right now. This
        // file is `Code/BASICShell/Sources/BASICShell/…`; four levels up is
        // `Code`, and the pages are Studio's.
        let code = URL(fileURLWithPath: String(#filePath))
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        sources.append(.directory(code.appendingPathComponent("BASICStudio/UserDocs")))

        let working = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        sources.append(.directory(working.appendingPathComponent("Code/BASICStudio/UserDocs")))
        sources.append(.directory(working.appendingPathComponent("UserDocs")))

        return sources
    }

    /// `TUTORIAL_*` is a tutorial; everything else is reference. Studio's rule.
    private static func group(of fileName: String) -> Group {
        fileName.uppercased().hasPrefix("TUTORIAL_") ? .tutorials : .reference
    }

    /// The first `# ` heading, or the file name with its underscores opened
    /// out — again Studio's rule, so the two lists read the same.
    private static func title(of content: String, fallback: String) -> String {
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) where line.hasPrefix("# ") {
            return String(line.dropFirst(2))
        }
        return fallback.replacingOccurrences(of: "_", with: " ")
    }
}

// MARK: - The window

/// Esc closes the manual from anywhere, as it closes a program's window.
@MainActor
private final class HelpWindow: Window {
    var onQuit: () -> Void = {}
    weak var menuBar: MenuBar?

    override func handleHotKey(_ key: KeyInput) -> Bool {
        if key.key == .escape, key.modifiers.isEmpty {
            // An open dropdown owns Esc — it is closing the menu, not the
            // manual.
            if menuBar?.isMenuOpen == true { return false }
            onQuit()
            return true
        }
        return super.handleHotKey(key)
    }
}

/// The `HELP` browser: topics on the left, the page on the right.
enum BASICShellHelp {

    /// Opens the manual, returning false when it could not be shown — no
    /// terminal to draw on, or no pages to draw. The caller falls back to the
    /// one-line command list, which is what `HELP` did before this existed.
    ///
    /// - Parameter wanted: what `HELP PRINT` asked for, matched against a
    ///   page's file name and title.
    static func browse(topic wanted: String? = nil) -> Bool {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { return false }
        let topics = ShellHelpLibrary.load()
        guard !topics.isEmpty else { return false }

        return MainActorBridge.lendingTerminal {
            MainActorBridge.runBlocking {
                await present(topics: topics, wanted: wanted, on: ANSIDriver())
            } ?? false
        }
    }

    /// Runs the browser on a given driver.
    ///
    /// The driver is a parameter for the same reason the editor's is: a test
    /// can hand in TUIKit's `HeadlessDriver` and press real keys.
    @MainActor
    static func present(
        topics: [ShellHelpTopic],
        wanted: String? = nil,
        on driver: any TerminalDriver
    ) async -> Bool {
        let app = App(driver: driver)
        app.applyTheme(.modernTurbo)
        // `^C` is a copy key in TUIKit's controls, and a manual that closed on
        // it would close under a reader trying to copy a line of a program.
        app.stopsOnControlC = false

        let window = HelpWindow()
        window.fillsScreen = true

        // A tree, not a list with headings drawn on it.
        //
        // The first version of this was a flat `SidebarList` whose group rows
        // carried a `▾` glyph, which is a picture of a disclosure control
        // rather than one: the triangle was there, nothing was under it, and
        // choosing a group could not collapse anything because the pages were
        // siblings of their heading rather than children of it. `TreeView`
        // has the parent/child relationship, and with it collapsing, the
        // arrow keys, and a scrollbar — none of which a flat list can have.
        var roots: [TreeNode] = []
        var topicForNode: [ObjectIdentifier: Int] = [:]
        var nodeForTopic: [Int: TreeNode] = [:]
        for group in ShellHelpTopic.Group.allCases {
            let indexes = topics.indices.filter { topics[$0].group == group }
            guard !indexes.isEmpty else { continue }
            let root = TreeNode(group.title.uppercased())
            root.isExpanded = true
            for index in indexes {
                let child = TreeNode(topics[index].title)
                topicForNode[ObjectIdentifier(child)] = index
                nodeForTopic[index] = child
                root.addChild(child)
            }
            roots.append(root)
        }

        let tree = TreeView(roots: roots)
        tree.anchors = .fill()

        let document = Panel("Help")
        document.themeContext = ThemeContext.contentWindow
        document.anchors = AnchorSet(leading: 0, trailing: 0, top: 1, bottom: 1)

        let status = StatusBar()
        let heading = Label("")
        status.addSegment(heading, percentage: 100)
        status.addSegment(Label("↑↓ topic   ←→ group   Esc close"), minimumWidth: 30)
        status.anchors = AnchorSet(leading: 0, trailing: 0, bottom: 0, height: 1)

        let treeHost = TUIView()
        treeHost.addSubview(tree)
        let detailHost = TUIView()
        let split = SplitView(axis: .horizontal, first: treeHost, second: detailHost, dividerPosition: 30)
        split.minimumFirstLength = 16
        split.minimumSecondLength = 20
        split.anchors = .fill()
        document.content.addSubview(split)

        var page: MarkdownView?

        /// Shows a node: a page for a topic, a contents list for a group.
        func show(_ node: TreeNode?) {
            guard let node else { return }
            let markdown: String
            let caption: String
            if let index = topicForNode[ObjectIdentifier(node)] {
                markdown = topics[index].content
                caption = "\(topics[index].group.title) · \(topics[index].title)"
            } else {
                // A group shows what is in it. A heading that selected to a
                // blank page would read as broken.
                let listed = node.children.map { "- \($0.title)" }.joined(separator: "\n")
                markdown = "# \(node.title.capitalized)\n\n\(listed)"
                caption = node.title.capitalized
            }
            page?.removeFromSuperview()
            let view = MarkdownView(markdown: markdown)
            view.anchors = .fill()
            detailHost.addSubview(view)
            page = view
            document.title = caption
            heading.text = caption
        }

        tree.onSelectionChanged = { node in show(node) }
        // Return on a group opens or closes it, which is what Return means
        // everywhere else in TUIKit.
        tree.onActivate = { node in
            if node.isExpandable { tree.toggle(node) }
        }

        // `HELP PRINT` opens on PRINT. A name that matches nothing opens at
        // the top rather than complaining: the list is right there to look in.
        var start = roots.first
        if let wanted = wanted?.uppercased(), !wanted.isEmpty {
            let match = topics.indices.first { index in
                topics[index].name.uppercased() == wanted || topics[index].title.uppercased() == wanted
            }
            if let match, let node = nodeForTopic[match] { start = node }
        }
        tree.select(start, notify: true)
        // Named here as well as from the callback: selecting the node that is
        // already selected is not a change, so the callback does not fire and
        // the window would open wearing its placeholder title.
        show(start)

        let fileMenu = Menu("&File")
        fileMenu.addItem("&Close", keyEquivalent: KeyInput(key: .character("x"), modifiers: .control)) {
            app.stop()
        }

        let bar = MenuBar()
        bar.addMenu(fileMenu)
        bar.anchors = AnchorSet(leading: 0, trailing: 0, top: 0, height: 1)
        window.menuBar = bar
        window.onQuit = { app.stop() }

        window.addSubview(bar)
        window.addSubview(status)
        window.addSubview(document)
        _ = window.makeFirstResponder(tree)

        do {
            try await app.run(window)
        } catch {
            return false
        }
        return true
    }
}
