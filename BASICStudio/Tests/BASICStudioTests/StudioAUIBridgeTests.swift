//
//  StudioAUIBridgeTests.swift
//  BASICStudioTests
//
//  P6 in Studio: a BASIC program's own ActiveUI windows, end to end, with
//  the test playing the user. Windows stay off screen (showsWindows = false).
//

import ActiveUI
import ActiveUICharts
import AppKit
import BASICCore
import Foundation
import Testing
@testable import BASICStudio

@Suite("BASIC programs' ActiveUI windows", .serialized)
@MainActor
struct StudioAUIBridgeTests {
    private func harness(_ program: String) -> StudioHarness {
        let studio = StudioHarness(program: program)
        studio.model.auiBridge.showsWindows = false
        return studio
    }

    /// The first control of `type` the program made.
    private func control<T: AUIView>(_ type: T.Type, in bridge: StudioAUIBridge) -> (Int, T)? {
        bridge.views.sorted { $0.key < $1.key }.lazy.compactMap { id, view in (view as? T).map { (id, $0) } }.first
    }

    @Test("P6 · A program's window: clicks and a selection reach its handlers, run() returns when it closes")
    func windowRoundTrip() async throws {
        let studio = harness("""
        GLOBAL clicks = 0
        let w = AUIWindow("Picker")
        let l = AUILabel("none yet")
        let b = AUIButton("Count")
        let li = AUIList()
        li.add("Ada")
        li.add("Grace")
        w.add(l)
        w.add(b)
        w.add(li)
        b.onclick("Counted")
        on aui select call Picked
        w.run()
        print "clicks "; clicks; " label "; l.text$()

        function Counted()
            clicks = clicks + 1
        end function

        function Picked(event as BASICAUIEvent)
            l.text("picked " + event.Text$)
        end function
        """)
        let bridge = studio.model.auiBridge
        studio.model.runEditorProgram()
        try await studio.waitUntil("the window") {
            (try? bridge.perform(.isOpen(id: 1))) == .flag(true) && bridge.views.count == 3
        }
        let (_, button) = try #require(control(AUIButton.self, in: bridge))
        button.onClick?()
        button.onClick?()
        let (_, list) = try #require(control(AUITable.self, in: bridge))
        #expect(list.rowCount() == 2)
        list.selectedRows = [1]
        list.onSelectionChange?([1])
        let (_, label) = try #require(control(AUILabel.self, in: bridge))
        try await studio.waitUntil("the handler") { label.text == "picked Grace" }
        _ = try bridge.perform(.close(id: 1))
        try await studio.waitUntilStopped()
        #expect(studio.model.consoleText.contains("clicks 2 label picked Grace"))
        #expect(bridge.views.isEmpty, "the program's controls go when it ends")
    }

    @Test("P6 · A dialog's show waits for its button, and answers its index")
    func dialog() async throws {
        let studio = harness("""
        let d = AUIDialog("Delete?", "It cannot be undone.")
        d.addbutton("Cancel")
        d.addbutton("Delete")
        print "chose"; d.show()
        """)
        var shown: (String, String, [String])?
        studio.model.auiBridge.presentDialog = { title, message, buttons, done in
            shown = (title, message, buttons)
            done(1)
        }
        try await studio.run()
        #expect(shown?.0 == "Delete?" && shown?.2 == ["Cancel", "Delete"])
        #expect(studio.lastRunOutput.hasPrefix("chose1\n"))
    }

    @Test("P6 · A table takes rows of cells; a field's text reads back")
    func tableAndField() async throws {
        let studio = harness("""
        let t = AUITable("Name", "Born")
        t.addrow("Ada", 1815)
        t.addrow("Grace", 1906)
        let f = AUIField("hello", "Say something")
        print t.count(); " "; f.text$()
        """)
        try await studio.run()
        #expect(studio.lastRunOutput.hasPrefix("2 hello\n"))
    }

    @Test("P6 · The field reports submit and change")
    func fieldEvents() async throws {
        let studio = harness("""
        let w = AUIWindow("Form")
        let f = AUIField("", "Name")
        w.add(f)
        f.onsubmit("Submitted")
        w.run()

        function Submitted(event as BASICAUIEvent)
            print "submitted "; event.Text$
            w.close()
        end function
        """)
        let bridge = studio.model.auiBridge
        studio.model.runEditorProgram()
        try await studio.waitUntil("the window") { (try? bridge.perform(.isOpen(id: 1))) == .flag(true) }
        let (_, field) = try #require(control(AUITextField.self, in: bridge))
        field.onSubmit?("Bobby")
        try await studio.waitUntilStopped()
        #expect(studio.model.consoleText.contains("submitted Bobby"))
    }

    @Test("P6 · Stop ends a program waiting in run(), and its window goes")
    func stopWhileRunning() async throws {
        let studio = harness("""
        let w = AUIWindow("Forever")
        w.run()
        print "not reached"
        """)
        let bridge = studio.model.auiBridge
        studio.model.runEditorProgram()
        try await studio.waitUntil("the window") { (try? bridge.perform(.isOpen(id: 1))) == .flag(true) }
        studio.model.stopProgram()
        try await studio.waitUntilStopped()
        #expect(!studio.model.consoleText.contains("not reached"))
        #expect(bridge.views.isEmpty && (try? bridge.perform(.isOpen(id: 1))) == .flag(false))
    }

    /// ACTIVEUI_TRANSITION.md P6.4: the demo is the acceptance test. If a
    /// user could not do this, the binding has a hole.
    @Test("P6.4 · aui-gallery.bas, from the Examples menu, worked through by the user")
    func galleryDemo() async throws {
        let studio = harness("")
        let example = try #require(studio.model.bundledExamples.first { $0.path == "activeui/aui-gallery" })
        studio.model.loadBundledExample(example)
        let bridge = studio.model.auiBridge
        var asked: String?
        bridge.presentDialog = { title, _, _, done in
            asked = title
            done(0)
        }
        studio.model.runEditorProgram()
        try await studio.waitUntil("the window") { (try? bridge.perform(.isOpen(id: 1))) == .flag(true) }

        // Ids follow the program's order of construction.
        let info = try #require(bridge.views[2] as? AUILabel)
        let field = try #require(bridge.views[3] as? AUITextField)
        let names = try #require(bridge.views[4] as? AUITable)
        let born = try #require(bridge.views[5] as? AUITable)
        let counter = try #require(bridge.views[6] as? AUIButton)
        let add = try #require(bridge.views[8] as? AUIButton)
        let clear = try #require(bridge.views[10] as? AUIButton)
        #expect(names.rowCount() == 3 && born.rowCount() == 3)

        field.text = "Hedy Lamarr"
        add.onClick?()
        try await studio.waitUntil("the name added") { info.text == "Added Hedy Lamarr." }
        #expect(names.rowCount() == 4 && field.text.isEmpty)

        counter.onClick?()
        counter.onClick?()
        try await studio.waitUntil("the count") { counter.title == "Clicked 2 times" }

        names.selectedRows = [1]
        names.onSelectionChange?([1])
        try await studio.waitUntil("the pick") { info.text == "You picked Grace Hopper, row 2." }

        clear.onClick?()
        try await studio.waitUntil("the clear") { info.text == "Cleared." }
        #expect(asked == "Clear the list?" && names.rowCount() == 0 && born.rowCount() == 3)

        _ = try bridge.perform(.close(id: 1))
        try await studio.waitUntilStopped()
        #expect(studio.model.consoleText.contains("Window closed.\nThe window closed after 2 clicks, with 0 names.\n"))
    }

    /// P6.6: a real ActiveUI app, translated file for file, behaves as the
    /// original does. ActiveUICounterDemo counts clicks into its label.
    @Test("P6.6 · The translated ActiveUICounterDemo counts its clicks")
    func counterDemo() async throws {
        let studio = harness("")
        let example = try #require(studio.model.bundledExamples.first { $0.path == "activeui/ActiveUICounterDemo" })
        studio.model.loadBundledExample(example)
        let bridge = studio.model.auiBridge
        studio.model.runEditorProgram()
        try await studio.waitUntil("the window") { (try? bridge.perform(.isOpen(id: 2))) == .flag(true) }
        let (_, label) = try #require(control(AUILabel.self, in: bridge))
        let (_, button) = try #require(control(AUIButton.self, in: bridge))
        #expect(label.text == "Count: 0" && button.title == "Click me")
        button.onClick?()
        button.onClick?()
        try await studio.waitUntil("two clicks") { label.text == "Count: 2" }
        _ = try bridge.perform(.close(id: 2))
        try await studio.waitUntilStopped()
    }

    @Test("P6 · The bridge builds each kind of control, and refuses a request for the wrong one")
    func bridgeKinds() throws {
        let bridge = StudioAUIBridge()
        bridge.showsWindows = false
        _ = try bridge.perform(.create(id: 1, kind: .window, arguments: ["W"]))
        _ = try bridge.perform(.create(id: 2, kind: .stack, arguments: ["horizontal"]))
        _ = try bridge.perform(.create(id: 3, kind: .button, arguments: ["B"]))
        _ = try bridge.perform(.add(parent: 1, child: 2))
        _ = try bridge.perform(.add(parent: 2, child: 3))
        #expect((bridge.views[2] as? AUIStack)?.axis == .horizontal)
        #expect((bridge.views[2] as? AUIStack)?.children.count == 1)
        _ = try bridge.perform(.setText(id: 1, text: "Renamed"))
        #expect(bridge.windows[1]?.title == "Renamed")
        #expect(throws: BASICError.self) { try bridge.perform(.text(id: 3)) }
        _ = try bridge.perform(.setEnabled(id: 3, enabled: false))
        #expect(bridge.views[3]?.isEnabled == false)
    }

    @Test("Grade Book · Tabs show each page under its title, and a tab the user picks reaches onchange")
    func tabs() async throws {
        let studio = harness("""
        let w = AUIWindow("Book")
        let tabs = AUITabs()
        let first = AUILabel("first page")
        let second = AUILabel("second page")
        tabs.addtab("Students", first)
        tabs.addtab("Grades", second)
        w.add(tabs)
        tabs.onchange("Switched")
        w.run()

        function Switched(event as BASICAUIEvent)
            print "tab "; event.Index; " "; event.Text$; " "; tabs.selectedtext$()
            w.close()
        end function
        """)
        let bridge = studio.model.auiBridge
        studio.model.runEditorProgram()
        try await studio.waitUntil("the window") { (try? bridge.perform(.isOpen(id: 1))) == .flag(true) }
        let tabView = try #require(bridge.views.values.lazy.compactMap { $0.children.first as? AUITabView }.first)
        #expect((try? bridge.perform(.itemCount(id: 2))) == .number(2))
        tabView.selectedTabIndex = 1
        tabView.onTabChange?(1)
        try await studio.waitUntilStopped()
        #expect(studio.model.consoleText.contains("tab 1 Grades Grades"))
    }

    @Test("Grade Book · A table's editable and choice cells take what the user types or picks, and report it")
    func editableCells() async throws {
        let studio = harness("""
        GLOBAL changes = 0
        let w = AUIWindow("Grades")
        let t = AUITable("Student", "Points", "Status")
        t.addrow("Ada", "18", "Present")
        t.addrow("Grace", "", "Present")
        t.editable("Points")
        t.choices("Status", "Present", "Absent", "Tardy")
        w.add(t)
        t.onchange("Changed")
        w.run()
        print "Grace "; t.cell$(1, "Points"); " "; t.cell$(1, "Status")

        function Changed(event as BASICAUIEvent)
            print "row"; event.Index; " column"; event.Column; " "; event.Text$
            changes = changes + 1
            if changes = 2 then w.close()
        end function
        """)
        let bridge = studio.model.auiBridge
        studio.model.runEditorProgram()
        try await studio.waitUntil("the window") { (try? bridge.perform(.isOpen(id: 1))) == .flag(true) }
        let (_, table) = try #require(control(AUITable.self, in: bridge))
        let columns = try #require(table.columns)
        let points = try #require(columns[1].cellContent(1) as? AUITextField)
        let status = try #require(columns[2].cellContent(1) as? AUISegmentedControl)
        #expect(columns[0].cellContent(0) is AUILabel)
        #expect(status.segments == ["Present", "Absent", "Tardy"] && status.selectedIndex == 0)
        points.onEndEditing?("20")
        status.onSelectionChange?(2)
        try await studio.waitUntilStopped()
        let output = studio.model.consoleText
        #expect(output.contains("row1 column1 20"), "\(output)")
        #expect(output.contains("row1 column2 Tardy"), "\(output)")
        #expect(output.contains("Grace 20 Tardy"), "\(output)")
    }

    @Test("Grade Book · A picker's options, a date, and a pie chart's slices")
    func pickerDateAndPie() async throws {
        let studio = harness("""
        let w = AUIWindow("Summary")
        let term = AUIPicker("Q1", "Q2", "S1")
        let day = AUIDate("2026-10-07")
        let pie = AUIPieChart("Grades")
        pie.addslice("A", 3)
        pie.addslice("B", 1)
        w.add(term)
        w.add(day)
        w.add(pie)
        term.onchange("Picked")
        w.run()
        print day.text$(); " "; pie.count(); " "; term.selectedindex()

        function Picked(event as BASICAUIEvent)
            print "picked "; event.Text$; event.Index
            w.close()
        end function
        """)
        let bridge = studio.model.auiBridge
        studio.model.runEditorProgram()
        try await studio.waitUntil("the window") { (try? bridge.perform(.isOpen(id: 1))) == .flag(true) }
        let (_, picker) = try #require(control(AUIPicker.self, in: bridge))
        let (_, date) = try #require(control(AUIDatePicker.self, in: bridge))
        let (_, chart) = try #require(control(AUIChart.self, in: bridge))
        #expect(picker.options == ["Q1", "Q2", "S1"])
        #expect(StudioAUIBridge.text(of: date.date) == "2026-10-07")
        let slices = try #require(chart.marks.first as? AUISectorMark).resolve()
        #expect(slices.map(\.y) == [3, 1])
        picker.selectedIndex = 2
        picker.onSelectionChange?(2)
        try await studio.waitUntilStopped()
        #expect(studio.model.consoleText.contains("picked S12"))
        #expect(studio.model.consoleText.contains("2026-10-07 2 2"))
    }
}
