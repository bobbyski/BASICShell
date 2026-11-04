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

    @Test("O3 · The Documentation opens on the Beginner's Guide, first of every tutorial")
    func opensOnTheBeginnersGuide() {
        let docs = UserDoc.loadAll()
        let pane = DocsPaneModel(docs: docs, selectedID: nil)
        #expect(pane.selectedDoc?.id == UserDoc.startPageID)
        #expect(pane.menuTitle == "Beginner's Guide to BASIC")
        let tutorials = pane.sections.first { $0.title == "Tutorials" }?.items.map(\.title) ?? []
        #expect(tutorials.first == "Beginner's Guide to BASIC")
        #expect(tutorials.count == 7, "\(tutorials)")
    }

    @Test("Without a shell (iPhone, iPad, Android) the BASICrc tutorial is left out, and so is the link to it")
    func shellPagesStayOnTheDesktop() throws {
        let desktop = UserDoc.loadAll(hasShell: true)
        let touch = UserDoc.loadAll(hasShell: false)
        #expect(desktop.contains { $0.id == "TUTORIAL_BASICRC.md" })
        #expect(!touch.contains { $0.id == "TUTORIAL_BASICRC.md" })
        #expect(touch.count == desktop.count - 1)

        let guide = try #require(touch.first { $0.id == UserDoc.startPageID })
        #expect(!guide.content.contains("TUTORIAL_BASICRC.md"), "no link leads to a page that is not there")
        #expect(guide.content.contains("(TUTORIAL_TUIKIT.md)"), "the other tutorials are still listed")
        let desktopGuide = try #require(desktop.first { $0.id == UserDoc.startPageID })
        #expect(desktopGuide.content.contains("(TUTORIAL_BASICRC.md)"))

        let tutorials = DocsPaneModel(docs: touch, selectedID: nil).sections.first { $0.title == "Tutorials" }?.items.map(\.title) ?? []
        #expect(!tutorials.contains("BASICrc Tutorial"))
        #expect(tutorials.count == 6, "\(tutorials)")
    }

    @Test("Topics group the Reference pages, in topic order, and unlisted pages go under More Reference")
    func topics() {
        let docs = Self.docs + [UserDoc(id: "PRINT.md", title: "PRINT", category: .reference, content: "# PRINT")]
        let topics = [
            UserDocTopic(title: "Input and Output", pages: ["PRINT.md", "SOUND.md", "GONE.md"]),
            UserDocTopic(title: "Empty", pages: ["NOTHING.md"]),
        ]
        let pane = DocsPaneModel(docs: docs, selectedID: "PRINT.md", topics: topics)
        let reference = pane.sections.first { $0.title == "Reference" }
        #expect(reference?.items.isEmpty == true)
        #expect(reference?.groups.map(\.title) == ["Input and Output", "More Reference"])
        #expect(reference?.groups.first?.items.map(\.id) == ["PRINT.md", "SOUND.md"])
        #expect(reference?.groups.first?.items.first?.isChecked == true)
        #expect(reference?.groups.last?.items.map(\.id) == ["LANGUAGE.md"])
        // Tutorials are not grouped.
        #expect(pane.sections.first?.groups.isEmpty == true)
    }

    @Test("With no topics, Reference stays one flat list")
    func noTopics() {
        let pane = DocsPaneModel(docs: Self.docs, selectedID: nil, topics: [])
        #expect(pane.sections.last?.groups.isEmpty == true)
        #expect(pane.sections.last?.items.map(\.id) == ["LANGUAGE.md", "SOUND.md"])
    }

    @Test("The real TOPICS.json lists every Reference page exactly once")
    func realTopicsCoverTheReference() {
        let topics = UserDoc.loadTopics()
        let listed = topics.flatMap(\.pages)
        let reference = UserDoc.loadAll(hasShell: true).filter { $0.category == .reference }.map(\.id)
        #expect(!topics.isEmpty)
        #expect(Set(listed).count == listed.count, "a page is in two topics")
        #expect(Set(reference).subtracting(listed).isEmpty, "pages in no topic: \(Set(reference).subtracting(listed).sorted())")
        #expect(Set(listed).subtracting(reference).isEmpty, "topics name pages that do not exist: \(Set(listed).subtracting(reference).sorted())")
    }
}
