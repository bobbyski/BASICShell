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
/// ``DocsPaneModel``. The page renders in ActiveUI's `AUIMarkdownEditor`,
/// read-only, with its source and ribbon hidden, on the Mac and on iPhone
/// and iPad alike. (The iPad drew it with MarkdownUI, a SwiftUI package,
/// until 2026-10-10: no SwiftUI, ever.)
///
/// ```text
///   Documentation          Getting Started ▾      menu: a submenu per category
///   ──────────────────────────────────────────
///   # Getting Started                             the page, or "No
///   …                                             documentation found."
/// ```
///
/// It owns the loaded pages and the choice; the first page shows until
/// another is chosen. A link to another page opens it here.
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
        selectedID = docs.first?.id

        let heading = AUILabel(DocsPaneModel.heading)
        heading.isBold = true
        let menu = AUIMenu("Documentation", items: [])
        menuButton = AUIMenuButton("Documentation Menu", systemSymbol: "book", menu: menu)
        // The menu's width: at most 280, and able to shrink toward 80 when
        // the inspector is narrow.
        menuButton.flexibility = .horizontal()
        menuButton.minimumSize = CGSize(width: 80, height: 0)
        let headerRow = LogPaneAUI.ends(heading, menuButton)
        headerRow.padding = AUIEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        let header = LogPaneAUI.card(headerRow, color: .controlBackground)

        viewer = AUIMarkdownEditor()
        viewer.isReadOnly = true
        viewer.isSourceHidden = true
        viewer.isRibbonHidden = true
        // The theme's `.markdown` rule colors the page on both platforms.
        viewer.themeClasses = "markdown"
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

        // A link to another page (`[IF THEN](IF_THEN.md)`) opens that page
        // here; anything else goes where the system sends it.
        viewer.onLinkActivated = { [weak self] link in
            guard let self, let page = Self.page(linkedBy: link, among: self.docs) else { return false }
            self.select(page)
            return true
        }
        refresh()
    }

    /// The page a link names, when it names one of `docs`: a relative link to
    /// a `.md` file, or the same as a file URL.
    static func page(linkedBy link: String, among docs: [UserDoc]) -> UserDoc.ID? {
        guard let url = URL(string: link), url.scheme == nil || url.scheme == "file",
              url.pathExtension.lowercased() == "md" else { return nil }
        let name = url.lastPathComponent
        return docs.contains { $0.id == name } ? name : nil
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
        // Built whole, not with `dynamicItems`. A pull-down spends item 0 on
        // its title, and AUIMenuButton's placeholder for it does not survive
        // a dynamic menu's rebuild on open: the first section, Tutorials,
        // became the hidden title and only Reference showed.
        menuButton.menu = AUIMenu("Documentation", items: menuItems(pane))
        menuButton.title = pane.menuTitle
        fitMenuToTitle()
        menuButton.isHidden = !pane.showsMenu
        if pane.selectedDoc != drawn?.selectedDoc {
            viewer.load(markdown: pane.selectedDoc?.content ?? "")
        }
        viewer.isHidden = pane.selectedDoc == nil
        emptyLabel.isHidden = pane.selectedDoc != nil
        drawn = pane
    }

    /// Caps the menu at its title's width, and at 280. Flexible so it can
    /// shrink, it must not grow past what it shows.
    private func fitMenuToTitle() {
        menuButton.maximumSize.width = .greatestFiniteMagnitude
        let natural = menuButton.layoutSize(fitting: CGSize(width: 10_000, height: 10_000)).width
        menuButton.maximumSize.width = min(280, natural)
    }

    private func menuItems(_ pane: DocsPaneModel) -> [AUIMenuItem] {
        pane.sections.map { section in
            let items = section.items.map { item in
                AUIMenuItem(item.title, action: { [weak self] in self?.select(item.id) })
                    .checked { item.isChecked }
            }
            return AUIMenuItem(section.title, submenu: AUIMenu(section.title, items: items))
        }
    }
}
