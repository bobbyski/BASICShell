//
//  DocsPaneAUI.swift
//  BASICStudio
//
//  The Documentation inspector, in ActiveUI.
//

import ActiveUI
import ActiveUIMarkdown
import Foundation

/// The Documentation inspector for the ActiveUI shell, drawn from
/// ``DocsPaneModel``. The page renders in an `AUIMarkdownEditor` set to
/// read-only preview, which takes MarkdownUI's place.
///
/// ```text
///   Documentation          Getting Started ▾      menu: a submenu per category
///   ──────────────────────────────────────────
///   # Getting Started                             the page, or "No
///   …                                             documentation found."
/// ```
///
/// Like `UserDocumentationPane`, it owns the loaded pages and the choice; the
/// first page shows until another is chosen.
@MainActor
final class DocsPaneAUI {
    let root: AUIView
    let menuButton: AUIMenuButton
    let viewer: AUIMarkdownEditor
    let emptyLabel: AUILabel
    private let docs: [UserDoc]
    private(set) var selectedID: UserDoc.ID?
    private(set) var drawn: DocsPaneModel?

    init(docs: [UserDoc] = UserDoc.loadAll()) {
        self.docs = docs
        // What the SwiftUI pane does on appear.
        selectedID = docs.first?.id

        let heading = AUILabel(DocsPaneModel.heading)
        heading.isBold = true
        let menu = AUIMenu("Documentation", items: [])
        menuButton = AUIMenuButton("Documentation Menu", systemSymbol: "book", menu: menu)
        let header = LogPaneAUI.row([heading, AUISpacer(), menuButton])
        header.padding = AUIEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        header.backgroundColor = .controlBackground

        viewer = AUIMarkdownEditor()
        viewer.isReadOnly = true
        viewer.isSourceHidden = true
        viewer.isRibbonHidden = true
        viewer.minimumSize = CGSize(width: 220, height: 200)
        emptyLabel = AUILabel(DocsPaneModel.emptyText)
        emptyLabel.textColor = .secondary
        let page = AUIZStack(alignment: .fill)
        page.addChild(viewer)
        page.addChild(emptyLabel)
        page.flexibility = .both()

        let body = AUIStack(.vertical, spacing: 0, alignment: .fill)
        body.wraps = false
        body.addChild(header)
        body.addChild(AUIDivider())
        body.addChild(page)
        root = body

        menu.dynamicItems { [weak self] in
            MainActor.assumeIsolated { self?.menuItems() ?? [] }
        }
        refresh()
    }

    /// Shows page `id`, as its menu item does.
    func select(_ id: UserDoc.ID) {
        selectedID = id
        refresh()
    }

    /// Brings the pane up to its state; nothing happens if nothing changed.
    func refresh() {
        let pane = DocsPaneModel(docs: docs, selectedID: selectedID)
        guard pane != drawn else { return }
        menuButton.title = pane.menuTitle
        menuButton.isHidden = !pane.showsMenu
        if pane.selectedDoc != drawn?.selectedDoc {
            viewer.load(markdown: pane.selectedDoc?.content ?? "")
        }
        viewer.isHidden = pane.selectedDoc == nil
        emptyLabel.isHidden = pane.selectedDoc != nil
        drawn = pane
    }

    private func menuItems() -> [AUIMenuItem] {
        DocsPaneModel(docs: docs, selectedID: selectedID).sections.map { section in
            let items = section.items.map { item in
                AUIMenuItem(item.title, action: { [weak self] in self?.select(item.id) })
                    .checked { item.isChecked }
            }
            return AUIMenuItem(section.title, submenu: AUIMenu(section.title, items: items))
        }
    }
}
