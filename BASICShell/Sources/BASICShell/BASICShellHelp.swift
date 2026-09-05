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

/// Finding and reading Studio's `UserDocs`.
enum ShellHelpLibrary {

    /// Every page, tutorials first and alphabetical within a group — the
    /// order Studio's menu lists them in.
    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> [ShellHelpTopic] {
        for directory in directories(environment: environment) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ) else { continue }

            let topics = files
                .filter { $0.pathExtension.lowercased() == "md" }
                .compactMap { url -> ShellHelpTopic? in
                    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                    let name = url.deletingPathExtension().lastPathComponent
                    return ShellHelpTopic(
                        name: name,
                        title: title(of: content, fallback: name),
                        group: group(of: name),
                        content: content
                    )
                }
                .sorted { left, right in
                    if left.group != right.group {
                        return Group.allCases.firstIndex(of: left.group)!
                            < Group.allCases.firstIndex(of: right.group)!
                    }
                    return left.title.localizedStandardCompare(right.title) == .orderedAscending
                }

            if !topics.isEmpty { return topics }
        }
        return []
    }

    private typealias Group = ShellHelpTopic.Group

    /// Where the pages might be, best guess first.
    ///
    /// The shell runs from three places and each has its own answer: a
    /// developer's `swift build` product, an install under `$PREFIX`, and a
    /// run from the repository root. `BASIC_USERDOCS` is ahead of all of them
    /// so a person editing the manual can point at what they are editing.
    static func directories(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var candidates: [URL] = []

        if let override = environment["BASIC_USERDOCS"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }

        // Installed: `$PREFIX/bin/basicshell` with the pages beside the demo
        // bundle, in `$PREFIX/lib/basicshell/UserDocs`.
        if let executable = Bundle.main.executablePath {
            let binDirectory = URL(fileURLWithPath: executable).deletingLastPathComponent()
            let prefix = binDirectory.deletingLastPathComponent()
            candidates.append(prefix.appendingPathComponent("lib/basicshell/UserDocs"))
            candidates.append(prefix.appendingPathComponent("share/basicshell/UserDocs"))
        }

        // In-tree: this file is `Code/BASICShell/Sources/BASICShell/…`, and the
        // pages are Studio's. Four levels up is `Code`.
        let code = URL(fileURLWithPath: String(#filePath))
            .deletingLastPathComponent()   // BASICShell
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // BASICShell (the package)
            .deletingLastPathComponent()   // Code
        candidates.append(code.appendingPathComponent("BASICStudio/UserDocs"))

        // Run from the repository root, or from Studio's own directory — the
        // two Studio itself looks in.
        let working = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(working.appendingPathComponent("Code/BASICStudio/UserDocs"))
        candidates.append(working.appendingPathComponent("UserDocs"))

        return candidates
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

    /// One sidebar row. Group headers are rows too, and show that group's
    /// contents — a row that selects to a blank page is a row that looks
    /// broken.
    private enum Row {
        case header(ShellHelpTopic.Group)
        case topic(Int)
    }

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

        // Headers interleaved with their pages, which is the sidebar's order
        // and also the order arrow keys walk.
        var rows: [Row] = []
        for group in ShellHelpTopic.Group.allCases {
            let indexes = topics.indices.filter { topics[$0].group == group }
            guard !indexes.isEmpty else { continue }
            rows.append(.header(group))
            rows.append(contentsOf: indexes.map { Row.topic($0) })
        }

        let items = rows.map { row -> SidebarItem in
            switch row {
            case .header(let group):
                // Uppercase and a marker, so a header reads as one on a list
                // that has no other way to say so.
                SidebarItem(icon: "▾", title: group.title.uppercased())
            case .topic(let index):
                SidebarItem(title: topics[index].title)
            }
        }

        let document = Panel("Help")
        document.themeContext = ThemeContext.contentWindow
        document.anchors = AnchorSet(leading: 0, trailing: 0, top: 1, bottom: 1)

        let status = StatusBar()
        let heading = Label("")
        status.addSegment(heading, percentage: 100)
        status.addSegment(Label("↑↓ topic   Esc close"), minimumWidth: 22)
        status.anchors = AnchorSet(leading: 0, trailing: 0, bottom: 0, height: 1)

        /// The page for a row: a topic's markdown, or a group's contents.
        func markdown(for row: Row) -> String {
            switch row {
            case .topic(let index):
                return topics[index].content
            case .header(let group):
                let listed = topics.filter { $0.group == group }
                    .map { "- \($0.title)" }
                    .joined(separator: "\n")
                return """
                # \(group.title)

                \(listed.isEmpty ? "_No pages._" : listed)
                """
            }
        }

        func caption(for row: Row) -> String {
            switch row {
            case .header(let group): group.title
            case .topic(let index): "\(topics[index].group.title) · \(topics[index].title)"
            }
        }

        let master = MasterDetail(items: items) { index in
            let view = MarkdownView(markdown: index < rows.count ? markdown(for: rows[index]) : "")
            view.anchors = .fill()
            return view
        }
        master.sidebarWidth = 30
        master.anchors = .fill()
        /// The window's name for what is on screen, in both places it appears.
        func nameCurrent(_ index: Int) {
            guard index < rows.count else { return }
            let text = caption(for: rows[index])
            document.title = text
            heading.text = text
        }

        master.onSelectionChanged = { index in
            if let index { nameCurrent(index) }
        }
        document.content.addSubview(master)

        // Opens on the first group header, so the reader arrives at the top of
        // the list looking at what the groups are — landing part-way down a
        // list of seventy-six pages, with the heading above already scrolled
        // off, tells them nothing about how it is organised.
        var start = 0
        if let wanted = wanted?.uppercased(), !wanted.isEmpty {
            let match = rows.firstIndex { row in
                guard case .topic(let index) = row else { return false }
                return topics[index].name.uppercased() == wanted
                    || topics[index].title.uppercased() == wanted
            }
            if let match { start = match }
        }
        master.list.select(start, notify: true)
        // Named here as well as from the callback: selecting the row that is
        // already selected is not a change, so the callback does not fire and
        // the window would open wearing its placeholder title.
        nameCurrent(start)

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
        _ = window.makeFirstResponder(master.list)

        do {
            try await app.run(window)
        } catch {
            return false
        }
        return true
    }
}
