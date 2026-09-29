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
