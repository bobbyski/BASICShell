//
//  ActiveUIPaneTests.swift
//  BASICStudioTests
//
//  Level 3 for P3: the ActiveUI inspector and its panes, with no window.
//

import ActiveUI
import AppKit
import Foundation
import Testing
@testable import BASICStudio

@Suite("ActiveUI panes", .serialized)
@MainActor
struct ActiveUIPaneTests {
    private func frames(_ layout: InspectorLayout, width: CGFloat) -> (main: CGRect, inspector: CGRect) {
        layout.place(in: CGRect(x: 0, y: 0, width: width, height: 600))
        layout.layoutChildren(in: CGRect(x: 0, y: 0, width: width, height: 600))
        return (layout.main.nativeView.frame, layout.inspector.nativeView.frame)
    }

    @Test("I1 I2 · The inspector opens at 360, keeps 260, and leaves the main pane 420")
    func inspectorWidths() {
        let layout = InspectorLayout(main: AUIView(), inspector: AUIView())
        layout.showsInspector = true
        var placed = frames(layout, width: 1200)
        #expect(placed.inspector.width == 360)
        // Frames are pixel-aligned, so compare to the half point.
        #expect(abs(placed.main.width - (1200 - 360 - 12)) < 0.5, "\(placed.main.width)")
        placed = frames(layout, width: 600)
        #expect(placed.inspector.width == 260)
        layout.showsInspector = false
        placed = frames(layout, width: 1200)
        #expect(placed.main.width == 1200)
        #expect(layout.inspector.isHidden && layout.handle.isHidden)
    }

    @Test("L1 L5 L6 · The Log pane lists the model's entries and enables Clear")
    func logPaneRows() {
        let model = StudioHarness().model
        model.clearLogs()
        let pane = LogPaneAUI(model: model)
        #expect(!pane.clear.isEnabled)
        model.appendLog(level: "WARN", issuer: .user, text: "careful")
        pane.refresh()
        #expect(pane.clear.isEnabled)
        #expect(pane.drawn?.rows.map(\.text) == ["careful"])
        #expect(pane.table.rowCount() == 1)
    }

    @Test("L3 L4 · The Log pane's toggles mirror the model, and write to it")
    func logPaneToggles() {
        let model = StudioHarness().model
        let pane = LogPaneAUI(model: model)
        #expect(pane.user.isOn && !pane.basic.isOn && !pane.trace.isOn)
        #expect(pane.traceButton.title == "TRON")
        model.toggleTraceLogging()
        pane.refresh()
        #expect(pane.trace.isOn && pane.traceButton.title == "TROFF")
        pane.basic.onChange?(true)
        #expect(model.showBasicLogs)
    }

    /// `view`'s frame in `root`'s coordinates, once `root` is laid out at
    /// `size` the way a window would lay it out.
    private func frame(of view: AUIView, in root: AUIView, size: CGSize) -> CGRect {
        root.place(in: CGRect(origin: .zero, size: size))
        root.nativeView.layoutSubtreeIfNeeded()
        return view.nativeView.convert(view.nativeView.bounds, to: root.nativeView)
    }

    @Test("L2 L3 · The Log header fits the inspector at its default width, as LogPane's does")
    func logHeaderFits() {
        let pane = LogPaneAUI(model: StudioHarness().model)
        let width = StudioShellModel.defaultInspectorWidth
        let size = CGSize(width: width, height: 100)
        let levels = frame(of: pane.levels, in: pane.header, size: size)
        let clear = frame(of: pane.clear, in: pane.header, size: size)
        // Inside the header's 12-point margin, with the title unclipped.
        #expect(levels.maxX <= width - 12 + 0.5, "\(levels)")
        #expect(clear.maxX <= width - 12 + 0.5, "\(clear)")
        #expect(levels.width >= pane.levels.layoutSize(fitting: size).width - 0.5)
    }

    @Test("L1 · A log entry's tint covers its padding, as LogPane's does")
    func logRowTint() throws {
        let row = LogPaneModel.Row(id: UUID(), time: "12:00:00.000", issuer: "U", level: "INFO",
                                   levelKind: .run, module: "demo.bas", text: "hello")
        let box = try #require(LogPaneAUI.rowView(row) as? AUIStack)
        let content = try #require(box.children.first)
        #expect(box.backgroundColor != nil)
        let inner = frame(of: content, in: box, size: CGSize(width: 300, height: 60))
        // The padded content starts 8 in from the tinted box's edge.
        #expect(abs(inner.minX - 8) < 0.5 && abs(inner.minY - 8) < 0.5, "\(inner)")
    }

    @Test("O2 · The Docs menu stays inside a narrow inspector, and at its title's width in a wide one")
    func docsMenuFits() {
        let docs = [UserDoc(id: "A.md", title: "Async Programming Tutorial", category: .tutorials, content: "# A")]
        let pane = DocsPaneAUI(docs: docs)
        let natural = pane.menuButton.maximumSize.width
        #expect(natural > 80 && natural <= 280)
        let narrow = frame(of: pane.menuButton, in: pane.root, size: CGSize(width: 300, height: 400))
        #expect(narrow.maxX <= 300 - 12 + 0.5, "\(narrow)")
        let wide = frame(of: pane.menuButton, in: pane.root, size: CGSize(width: 700, height: 400))
        #expect(abs(wide.maxX - (700 - 12)) < 0.5, "\(wide)")
        #expect(abs(wide.width - natural) < 0.5, "\(wide)")
    }

    @Test("L7 · The Levels menu: a header, then each level checked")
    func levelsMenu() {
        let model = StudioHarness().model
        model.clearLogs()
        model.appendLog(level: "INFO", issuer: .user, text: "a")
        let pane = LogPaneAUI(model: model)
        let items = pane.levels.menu.itemsProvider?() ?? pane.levels.menu.items
        #expect(items.first?.title == "All Selected")
        #expect(items.last?.title == "INFO")
        #expect(items.last?.stateProvider?() == .on)
    }

    @Test("O2 O3 · The Docs pane shows the first page, and the menu switches pages")
    func docsPane() {
        let docs = [
            UserDoc(id: "T.md", title: "Tutorial", category: .tutorials, content: "# Tutorial"),
            UserDoc(id: "R.md", title: "Reference", category: .reference, content: "# Reference"),
        ]
        let pane = DocsPaneAUI(docs: docs)
        #expect(pane.menuButton.title == "Tutorial")
        #expect(!pane.viewer.isHidden && pane.emptyLabel.isHidden)
        #expect(pane.viewer.markdown.contains("Tutorial"))
        pane.select("R.md")
        #expect(pane.menuButton.title == "Reference")
        #expect(pane.viewer.markdown.contains("Reference"))
    }

    @Test("O2 · The Docs menu lists every section: the pull-down's title does not eat the first")
    func docsMenuListsEverySection() throws {
        let pane = DocsPaneAUI(docs: UserDoc.loadAll())
        func popups(in view: NSView) -> [NSPopUpButton] {
            (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popups(in:))
        }
        let menu = try #require(popups(in: pane.menuButton.nativeView).first?.menu)
        // Opening is when a dynamic menu used to rebuild and lose item 0.
        menu.delegate?.menuNeedsUpdate?(menu)
        // Item 0 is the pull-down's own title, which AppKit does not list.
        let listed = menu.items.dropFirst()
        #expect(listed.map(\.title) == ["Tutorials", "Reference"])
        let tutorials = try #require(listed.first?.submenu)
        tutorials.delegate?.menuNeedsUpdate?(tutorials)
        #expect(tutorials.items.count == UserDoc.loadAll().filter { $0.category == .tutorials }.count)
    }

    @Test("The toolbar's Examples menu is the demos tree, as the menu bar's is")
    func examplesMenu() throws {
        let model = StudioHarness().model
        let menu = StudioActiveUIShell.examplesMenu(model: model).makeNativeMenu()
        menu.delegate?.menuNeedsUpdate?(menu)
        #expect(menu.items.map(\.title) == model.exampleTree.folders.map(\.title))
        #expect(menu.items.allSatisfy { $0.submenu != nil })
        func programs(in category: String) throws -> [String] {
            let submenu = try #require(menu.items.first { $0.title == category }?.submenu)
            submenu.delegate?.menuNeedsUpdate?(submenu)
            return submenu.items.map(\.title)
        }
        #expect(try programs(in: "Games").contains("Roids"))
        #expect(try programs(in: "Language").contains("Hello"))
    }

    @Test("O5 · The Docs pane with no pages says so, and has no menu")
    func docsPaneEmpty() {
        let pane = DocsPaneAUI(docs: [])
        #expect(pane.menuButton.isHidden)
        #expect(pane.viewer.isHidden && !pane.emptyLabel.isHidden)
    }

    @Test("T6 T7 T8 T15 · The shell shows one inspector at a time, beside the main pane")
    func shellInspectors() async throws {
        let studio = StudioActiveUIShell(model: StudioHarness().model)
        #expect(!studio.layout.showsInspector)
        StudioShellModel.perform(.logs, on: studio.model)
        studio.refresh()
        #expect(studio.layout.showsInspector)
        #expect(!studio.logPane.root.isHidden && studio.docsPane.root.isHidden)
        StudioShellModel.perform(.docs, on: studio.model)
        studio.refresh()
        #expect(studio.logPane.root.isHidden && !studio.docsPane.root.isHidden)
        StudioShellModel.perform(.docs, on: studio.model)
        studio.refresh()
        #expect(!studio.layout.showsInspector)
    }
}
