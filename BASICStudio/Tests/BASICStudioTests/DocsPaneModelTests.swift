//
//  DocsPaneModelTests.swift
//  BASICStudioTests
//
//  P1 unit 2: the Documentation inspector's projection.
//

import Foundation
import Testing
@testable import BASICStudio

@Suite("DocsPaneModel")
struct DocsPaneModelTests {
    private static let docs = [
        UserDoc(id: "TUTORIAL_1.md", title: "First Steps", category: .tutorials, content: "# First Steps"),
        UserDoc(id: "LANGUAGE.md", title: "Language", category: .reference, content: "# Language"),
        UserDoc(id: "SOUND.md", title: "Sound", category: .reference, content: "# Sound"),
    ]

    @Test("O3 · With nothing chosen, the first page shows and is checked")
    func firstPageByDefault() {
        let pane = DocsPaneModel(docs: Self.docs, selectedID: nil)
        #expect(pane.selectedDoc?.id == "TUTORIAL_1.md")
        #expect(pane.menuTitle == "First Steps")
        #expect(pane.sections.flatMap(\.items).filter(\.isChecked).map(\.id) == ["TUTORIAL_1.md"])
    }

    @Test("O2 · Sections come in category order, Tutorials then Reference, pages in given order")
    func sections() {
        let pane = DocsPaneModel(docs: Self.docs, selectedID: "SOUND.md")
        #expect(pane.sections.map(\.title) == ["Tutorials", "Reference"])
        #expect(pane.sections[1].items.map(\.title) == ["Language", "Sound"])
        #expect(pane.sections[1].items.map(\.isChecked) == [false, true])
        #expect(pane.menuTitle == "Sound")
        #expect(pane.selectedDoc?.content == "# Sound")
    }

    @Test("O2 · A category with no pages has no submenu")
    func emptyCategoryIsDropped() {
        let pane = DocsPaneModel(docs: Array(Self.docs.dropFirst()), selectedID: nil)
        #expect(pane.sections.map(\.title) == ["Reference"])
    }

    @Test("O5 · With no pages: no menu, no page, the fallback title")
    func noPages() {
        let pane = DocsPaneModel(docs: [], selectedID: nil)
        #expect(!pane.showsMenu)
        #expect(pane.selectedDoc == nil)
        #expect(pane.menuTitle == "Documentation Menu")
        #expect(pane.sections.isEmpty)
        #expect(DocsPaneModel.emptyText == "No documentation found.")
    }

    @Test("A chosen page that has gone shows nothing, as before")
    func staleSelection() {
        let pane = DocsPaneModel(docs: Self.docs, selectedID: "GONE.md")
        #expect(pane.selectedDoc == nil)
        #expect(pane.menuTitle == "Documentation Menu")
        #expect(pane.sections.flatMap(\.items).allSatisfy { !$0.isChecked })
    }

    @Test("O1 · The shipped pages load, tutorials and reference both")
    func shippedPagesLoad() {
        let docs = UserDoc.loadAll()
        #expect(!docs.isEmpty)
        #expect(docs.contains { $0.category == .tutorials })
        #expect(docs.contains { $0.category == .reference })
    }
}
