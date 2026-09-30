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
    let viewer: DocsViewer
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
        // The menu's width: at most 280, as `UserDocumentationPane` frames
        // it, and able to shrink toward 80 when the inspector is narrow.
        menuButton.flexibility = .horizontal()
        menuButton.minimumSize = CGSize(width: 80, height: 0)
        let headerRow = LogPaneAUI.ends(heading, menuButton)
        headerRow.padding = AUIEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        let header = LogPaneAUI.card(headerRow, color: .controlBackground)

        viewer = DocsViewer()
        #if os(iOS)
        let viewerView = viewer.host
        #else
        viewer.isReadOnly = true
        viewer.isSourceHidden = true
        viewer.isRibbonHidden = true
        let viewerView: AUIView = viewer
        #endif
        viewerView.minimumSize = CGSize(width: 220, height: 200)
        emptyLabel = AUILabel(DocsPaneModel.emptyText)
        emptyLabel.textColor = .secondary
        let page = AUIZStack(alignment: .fill)
        page.addChild(viewerView)
        page.addChild(emptyLabel)
        page.flexibility = .both()

        let body = AUIStack(.vertical, spacing: 0, alignment: .fill)
        body.wraps = false
        body.addChild(header)
        body.addChild(AUIDivider())
        body.addChild(page)
        root = body

        #if os(iOS)
        viewer.model.onOpenPage = { [weak self] name in self?.select(name) }
        #endif
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
        #if os(iOS)
        viewer.host.isHidden = pane.selectedDoc == nil
        #else
        viewer.isHidden = pane.selectedDoc == nil
        #endif
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

#if os(iOS)
import MarkdownUI
import SwiftUI

typealias DocsViewer = DocsMarkdownPage

/// The Documentation page on iPhone and iPad: MarkdownUI in GitHub's style
/// (code blocks, lists, tables), as the SwiftUI shell draws these pages on
/// the Mac. ActiveUIMarkdown's iOS preview is still a line-by-line stand-in
/// (its AUI-IOS-STUB(P10)), with none of that.
@MainActor
final class DocsMarkdownPage {
    final class Model: ObservableObject {
        @Published var markdown = ""
        /// Called with a page's file name when a link to it is followed.
        var onOpenPage: ((String) -> Void)?
    }

    let model = Model()
    /// The page, to put in a layout.
    let host: AUINativeHost
    private let controller: UIHostingController<DocsMarkdownView>

    var markdown: String { model.markdown }

    init() {
        controller = UIHostingController(rootView: DocsMarkdownView(model: model))
        controller.view.backgroundColor = .clear
        host = AUINativeHost(controller.view)
    }

    func load(markdown: String) {
        model.markdown = markdown
    }
}

struct DocsMarkdownView: View {
    @ObservedObject var model: DocsMarkdownPage.Model

    var body: some View {
        ScrollView {
            Markdown(model.markdown)
                .markdownTheme(.gitHub)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
        }
        // A link to another page (`[IF THEN](IF_THEN.md)`) opens that page
        // here; anything else goes where the system sends it.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == nil, url.pathExtension.lowercased() == "md" else { return .systemAction }
            model.onOpenPage?(url.lastPathComponent)
            return .handled
        })
    }
}
#else
typealias DocsViewer = AUIMarkdownEditor
#endif
