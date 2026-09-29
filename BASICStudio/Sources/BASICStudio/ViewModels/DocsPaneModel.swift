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

    init(docs: [UserDoc], selectedID: UserDoc.ID?) {
        let showingID = selectedID ?? docs.first?.id
        selectedDoc = docs.first { $0.id == showingID }
        menuTitle = selectedDoc?.title ?? "Documentation Menu"
        showsMenu = !docs.isEmpty
        sections = UserDocCategory.allCases.compactMap { category in
            let pages = docs.filter { $0.category == category }
            guard !pages.isEmpty else { return nil }
            return Section(
                title: category.title,
                items: pages.map { Item(id: $0.id, title: $0.title, isChecked: $0.id == showingID) }
            )
        }
    }
}
