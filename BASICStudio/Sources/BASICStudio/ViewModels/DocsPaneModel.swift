//
//  DocsPaneModel.swift
//  BASICStudio
//
//  What the Documentation inspector shows, for either shell.
//

import Foundation

/// The Documentation inspector as values: its menu and the page it shows.
///
/// The pane owns two pieces of state, the loaded pages and the chosen page,
/// and this is built from them. It is a projection like ``LogPaneModel``.
/// It owns nothing and imports no UI framework, so both shells read it.
///
/// ```text
///   ┌ Documentation          📖 Getting Started ▾ ┐   menuTitle; the menu is
///   ├─────────────────────────────────────────────┤   sections by category,
///   │ # Getting Started                           │   each page checked if
///   │ …                                           │   it is the one showing
///   └─────────────────────────────────────────────┘   selectedDoc, or emptyText
/// ```
struct DocsPaneModel: Equatable {
    /// One category's submenu.
    struct Section: Equatable {
        let title: String
        let items: [Item]
        /// Submenus inside this one: the Reference topics, when there are any.
        var groups: [Section] = []
    }

    /// One page in the menu.
    struct Item: Equatable {
        let id: UserDoc.ID
        let title: String
        let isChecked: Bool
    }

    /// The pane's heading.
    static let heading = "Documentation"
    /// Shown in place of a page when none were found.
    static let emptyText = "No documentation found."

    /// The page showing: the chosen one, or the first until one is chosen.
    let selectedDoc: UserDoc?
    /// The menu button's label.
    let menuTitle: String
    /// There is no menu when there are no pages.
    let showsMenu: Bool
    /// One submenu per category that has pages, in category order.
    let sections: [Section]

    /// - Parameter topics: Reference topics from `TOPICS.json`. With some, the
    ///   Reference section is a submenu per topic, and pages no topic lists go
    ///   under More Reference; with none, it is one list, as it always was.
    init(docs: [UserDoc], selectedID: UserDoc.ID?, topics: [UserDocTopic] = []) {
        let showingID = selectedID ?? docs.first?.id
        selectedDoc = docs.first { $0.id == showingID }
        menuTitle = selectedDoc?.title ?? "Documentation Menu"
        showsMenu = !docs.isEmpty
        sections = UserDocCategory.allCases.compactMap { category in
            let pages = docs.filter { $0.category == category }
            guard !pages.isEmpty else { return nil }
            func item(_ doc: UserDoc) -> Item {
                Item(id: doc.id, title: doc.title, isChecked: doc.id == showingID)
            }
            guard category == .reference, !topics.isEmpty else {
                return Section(title: category.title, items: pages.map(item))
            }
            let byID = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var groups = topics.compactMap { topic -> Section? in
                let listed = topic.pages.compactMap { byID[$0] }
                return listed.isEmpty ? nil : Section(title: topic.title, items: listed.map(item))
            }
            let placed = Set(topics.flatMap(\.pages))
            let unplaced = pages.filter { !placed.contains($0.id) }
            if !unplaced.isEmpty {
                groups.append(Section(title: "More Reference", items: unplaced.map(item)))
            }
            return Section(title: category.title, items: [], groups: groups)
        }
    }
}
