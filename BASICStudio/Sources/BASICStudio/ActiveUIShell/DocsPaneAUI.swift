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
        #if !os(iOS)
        viewer.isReadOnly = true
        viewer.isSourceHidden = true
        viewer.isRibbonHidden = true
        #endif
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

#if os(iOS)
import ActiveUICoreEditor
import MarkdownUI
import SwiftUI

typealias DocsViewer = DocsMarkdownPage

/// The Documentation page on iPhone and iPad: MarkdownUI, laid out in
/// GitHub's style (code blocks, lists, tables) as the SwiftUI shell draws
/// these pages on the Mac. ActiveUIMarkdown's iOS preview is still a
/// line-by-line stand-in (its AUI-IOS-STUB(P10)), with none of that.
///
/// The colors are the stylesheet's, not GitHub's: `color` is the ink,
/// `background` the paper and `-aui-tint-color` the links, as the Mac's
/// markdown editor takes them. Without a theme they are the system's.
@MainActor
final class DocsMarkdownPage: AUIView {
    final class Model: ObservableObject {
        @Published var markdown = ""
        @Published var colors = DocsMarkdownColors()
        /// Called with a page's file name when a link to it is followed.
        var onOpenPage: ((String) -> Void)?
    }

    let model = Model()
    private let controller: UIHostingController<DocsMarkdownView>
    private let host: AUINativeHost

    var markdown: String { model.markdown }

    init() {
        controller = UIHostingController(rootView: DocsMarkdownView(model: model))
        controller.view.backgroundColor = .clear
        host = AUINativeHost(controller.view)
        super.init(nativeView: AUIView.makeContainerBacking())
        addChild(host)
    }

    func load(markdown: String) {
        model.markdown = markdown
    }

    override func layoutChildren(in bounds: CGRect) {
        host.place(in: bounds)
    }

    override func applyForegroundColor(_ color: AUIColor?) {
        super.applyForegroundColor(color)
        model.colors.text = color.map { Color(uiColor: $0.native) }
    }

    override func applyThemeBackground(_ color: AUIColor?) {
        super.applyThemeBackground(color)
        model.colors.background = color.map { Color(uiColor: $0.native) }
    }

    override func applyTintColor(_ color: AUIColor?) {
        super.applyTintColor(color)
        model.colors.link = color.map { Color(uiColor: $0.native) }
    }
}

/// The page's three colors, each nil for the system's own.
struct DocsMarkdownColors: Equatable {
    var text: Color?
    var background: Color?
    var link: Color?
}

struct DocsMarkdownView: View {
    @ObservedObject var model: DocsMarkdownPage.Model

    var body: some View {
        ScrollView {
            Markdown(model.markdown)
                .markdownTheme(Self.theme(model.colors))
                .markdownCodeSyntaxHighlighter(DocsCodeHighlighter(ink: model.colors.text ?? .primary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
        }
        .background(model.colors.background ?? .clear)
        // A link to another page (`[IF THEN](IF_THEN.md)`) opens that page
        // here; anything else goes where the system sends it.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == nil, url.pathExtension.lowercased() == "md" else { return .systemAction }
            model.onOpenPage?(url.lastPathComponent)
            return .handled
        })
    }

    /// GitHub's layout in the page's colors. GitHub's own theme paints its
    /// text, code and table rows in fixed grays of its own, which show as
    /// dark blocks on a red or navy page; here the paper shows through, and
    /// the shading is the ink at low strength, so it follows any theme.
    static func theme(_ colors: DocsMarkdownColors) -> Theme {
        let ink = colors.text ?? .primary
        let shade = ink.opacity(0.1)
        let rule = ink.opacity(0.25)
        return Theme.gitHub
            .text {
                ForegroundColor(ink)
                FontSize(16)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.85))
                BackgroundColor(shade)
            }
            .link {
                ForegroundColor(colors.link ?? .accentColor)
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(rule)
                        .relativeFrame(width: .em(0.2))
                    configuration.label
                        .markdownTextStyle { ForegroundColor(ink.opacity(0.75)) }
                        .relativePadding(.horizontal, length: .em(1))
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.225))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.85))
                        }
                        .padding(16)
                }
                .background(shade)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .markdownMargin(top: 0, bottom: 16)
            }
            .table { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(color: rule))
                    .markdownTableBackgroundStyle(.alternatingRows(Color.clear, shade))
                    .markdownMargin(top: 0, bottom: 16)
            }
    }
}
/// Code blocks in the source editor's colors.
///
/// The Mac's markdown engine colors a ```` ```basic ```` fence with its own
/// highlighter; MarkdownUI draws every code block in one color unless it is
/// given one. This is the iOS editor's: its grammars and its palette, through
/// `AUICodeHighlight`. Plain code stays in the page's ink, and comments are
/// that ink dimmed, as the editor draws them.
struct DocsCodeHighlighter: CodeSyntaxHighlighter {
    /// The page's text color.
    let ink: Color

    func highlightCode(_ code: String, language: String?) -> Text {
        guard let language, !language.isEmpty else { return Text(code) }
        var text = AttributedString()
        for run in AUICodeHighlight.runs(code, language: language) {
            var piece = AttributedString(run.text)
            if let color = run.color {
                piece.foregroundColor = Color(uiColor: (run.isDim ? color.opacity(0.6) : color).native)
            } else if run.isDim {
                piece.foregroundColor = ink.opacity(0.6)
            }
            var intent: InlinePresentationIntent = []
            if run.isBold { intent.insert(.stronglyEmphasized) }
            if run.isItalic { intent.insert(.emphasized) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            text += piece
        }
        return Text(text)
    }
}
#else
typealias DocsViewer = AUIMarkdownEditor
#endif
