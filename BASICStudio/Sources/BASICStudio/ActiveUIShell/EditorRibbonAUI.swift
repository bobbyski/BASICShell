//
//  EditorRibbonAUI.swift
//  BASICStudio
//
//  The ribbon across the top of the editor: the file, and a menu of the
//  functions in it that jumps to the one chosen.
//

import ActiveUI
import Foundation

/// The editor's ribbon, on the Mac and on iPad.
///
/// ```text
///   ┌─────────────────────────────────────────────────────────┐
///   │ 📄 main.bas  ›  [f] MoveGuard ⌄                          │  the ribbon
///   ├─────────────────────────────────────────────────────────┤
///   │ FUNCTION MoveGuard() AS VOID                            │  the editor
/// ```
///
/// The menu lists the program's functions and classes in the order they are
/// written (``ProgramOutline``), read again each time it opens, with its
/// `' MARK:` comments as headings. Its title is the function the caret is in,
/// or "Main program" outside them all, as the statements outside any
/// function are the program BASIC runs.
///
/// It looks as Freebird Studio's functions menu does (`EditorHeader`): the
/// same badges, `f.square` and `c.square`, and a MARK's name as a heading.
/// Its lines are the `-`s': before the name, a line above it; after, a line
/// below. (On iPhone and iPad a heading starts a section of its own, which
/// the system always rules off.)
@MainActor
final class EditorRibbonAUI {
    let root: AUIStack
    let fileLabel = AUILabel("")
    let functionsButton: AUIMenuButton

    /// The program's text, read when the outline is wanted.
    var text: () -> String = { "" }
    /// Called with a 1-based line to go to.
    var onJump: ((Int) -> Void)?

    /// The 1-based line the caret is on.
    private(set) var caretLine = 1
    private var outlineText: String?
    private var cachedOutline = ProgramOutline("")

    static let mainProgramTitle = "Main program"
    static let noFunctionsTitle = "No functions in this file"

    init() {
        functionsButton = AUIMenuButton(Self.mainProgramTitle, menu: AUIMenu("", items: []))
        functionsButton.isBordered = false
        functionsButton.tooltip = "Jump to a function"

        let file = AUIImageView(AUIImage(systemSymbolName: "doc.text", accessibilityDescription: nil))
        file.minimumSize = CGSize(width: 14, height: 14)
        file.maximumSize = CGSize(width: 14, height: 14)
        fileLabel.font = .caption
        let chevron = AUILabel("›")
        chevron.font = .caption

        root = AUIStack(.horizontal, spacing: 6, alignment: .center)
        root.wraps = false
        root.padding = AUIEdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10)
        root.addChild(file)
        root.addChild(fileLabel)
        root.addChild(chevron)
        root.addChild(functionsButton)
        root.addChild(AUISpacer())

        functionsButton.menu = AUIMenu("", items: []).dynamicItems { [weak self] in
            MainActor.assumeIsolated { self?.menuItems() ?? [] }
        }
    }

    /// The outline of the text as it is now; read again only when it has
    /// changed.
    var outline: ProgramOutline {
        let current = text()
        if current != outlineText {
            outlineText = current
            cachedOutline = ProgramOutline(current)
        }
        return cachedOutline
    }

    /// Shows `fileName`, and the function the caret is in now.
    func refresh(fileName: String) {
        if fileLabel.text != fileName {
            fileLabel.text = fileName
        }
        showCurrentFunction()
    }

    /// The caret moved to `line`: the title follows it.
    func caretMoved(to line: Int) {
        guard line != caretLine else { return }
        caretLine = line
        showCurrentFunction()
    }

    private func showCurrentFunction() {
        let entry = outline.entry(containing: caretLine)
        let title = entry?.title ?? Self.mainProgramTitle
        if functionsButton.title != title {
            functionsButton.title = title
        }
        let symbol = entry.map { Self.symbol(for: $0.kind) }
        if functionsButton.systemSymbol != symbol {
            functionsButton.systemSymbol = symbol
        }
    }

    /// A line of the menu, before it is a menu item.
    enum Row: Equatable {
        /// A function or class to jump to.
        case entry(ProgramOutline.Entry)
        /// A MARK's name.
        case heading(String)
        /// A rule between groups.
        case line
        /// Said when there is nothing to list.
        case empty(String)
    }

    /// The menu, as rows: the declarations in the order they are written,
    /// and each MARK a heading with a line above and below it as its `-`s
    /// ask. Never two lines together, nor one at the top or the bottom, nor a
    /// MARK last of all with nothing under it: those draw lines around
    /// nothing, and read as a list that did not finish loading.
    static func rows(for outline: ProgramOutline) -> [Row] {
        var entries = outline.entries
        while entries.last?.kind == .mark { entries.removeLast() }
        guard !entries.isEmpty else { return [.empty(noFunctionsTitle)] }
        var rows: [Row] = []
        var lineWanted = false
        func add(_ row: Row) {
            if lineWanted, !rows.isEmpty { rows.append(.line) }
            lineWanted = false
            rows.append(row)
        }
        for entry in entries {
            guard entry.kind == .mark else {
                add(.entry(entry))
                continue
            }
            if entry.separatorBefore { lineWanted = true }
            if !entry.name.isEmpty { add(.heading(entry.name)) }
            if entry.separatorAfter { lineWanted = true }
        }
        return rows
    }

    /// The menu's items, from ``rows(for:)``. Each declaration has its kind's
    /// badge, and a class's functions are set in under it; where a menu
    /// cannot indent (iPhone and iPad), they say the class instead.
    func menuItems() -> [AUIMenuItem] {
        Self.rows(for: outline).map { row in
            switch row {
            case .entry(let entry):
                return item(for: entry)
            case .heading(let name):
                return .sectionHeader(name)
            case .line:
                return .separator()
            case .empty(let text):
                let none = AUIMenuItem(text, action: {})
                none.isEnabled = false
                return none
            }
        }
    }

    private func item(for entry: ProgramOutline.Entry) -> AUIMenuItem {
        #if os(macOS)
        let title = entry.name
        #else
        let title = entry.title
        #endif
        let line = entry.line
        let item = AUIMenuItem(title) { [weak self] in self?.jump(to: line) }
        item.image = AUIImage(systemSymbolName: Self.symbol(for: entry.kind), accessibilityDescription: nil)
        item.indentationLevel = entry.container == nil ? 0 : 1
        return item
    }

    /// Goes to `line`, and shows where it went.
    func jump(to line: Int) {
        onJump?(line)
        caretLine = line
        showCurrentFunction()
    }

    static func symbol(for kind: ProgramOutline.Kind) -> String {
        switch kind {
        case .function: "f.square"
        case .class, .interface, .type: "c.square"
        case .mark: "text.justify.left"
        }
    }
}
