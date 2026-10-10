//
//  GradeBookTests.swift
//  BASICStudioTests
//
//  BASIC-30: the Grade Book example, end to end. The test is the teacher: it
//  opens Examples ▸ Apps ▸ Grade Book, makes a book, adds students and
//  assignments, enters grades, takes attendance, reads the summaries, quits,
//  runs it again, and finds everything still there. The figures it checks
//  were worked out by hand:
//
//  Quiz 1 (Q1, 20 points, weight 1), Test 1 (Q1, 100, weight 3),
//  Quiz 2 (Q2, 20, weight 1), Midterm (S1, 50, weight 2).
//
//               Quiz 1  Test 1  Quiz 2  Midterm   Q1          Q2      S1
//    Hopper       15      -       12      40      75 C        60 D    73.8 C
//    Johnson      20      70      -       30      77.5 C      -       71.7 C
//    Lovelace     18      95      20      45      93.8 A      100 A   93.6 A
//
//  Q1 for Lovelace: (1 × 18/20 + 3 × 95/100) / (1 + 3) = 0.9375.
//  S1 for Hopper: (1 × 15/20 + 1 × 12/20 + 2 × 40/50) / (1 + 1 + 2) = 0.7375.
//  A missing grade is left out, not counted as 0.
//
//  Attendance: 2026-10-05 Hopper absent, Johnson tardy; 2026-10-06 Hopper
//  absent, Lovelace tardy and then present again. So Hopper 2 absences,
//  Johnson 1 tardy, Lovelace none.
//

import ActiveUI
import ActiveUICharts
import AppKit
import BASICCore
import Foundation
import Testing
@testable import BASICStudio

@Suite("BASIC-30 · The Grade Book example", .serialized)
@MainActor
struct GradeBookTests {
    /// The program's controls, found the way a person finds them: a button by
    /// its title, a field by what it asks for, a table by its columns.
    @MainActor
    private struct Screen {
        let studio: StudioHarness
        var bridge: StudioAUIBridge { studio.model.auiBridge }

        func all<T: AUIView>(_ type: T.Type) -> [(Int, T)] {
            bridge.views.sorted { $0.key < $1.key }.compactMap { id, view in (view as? T).map { (id, $0) } }
        }

        func button(_ title: String) throws -> AUIButton {
            try #require(all(AUIButton.self).first { $0.1.title == title }?.1, "a button \(title)")
        }

        func field(_ asking: String) throws -> AUITextField {
            try #require(all(AUITextField.self).first { ($0.1.placeholder ?? "").hasPrefix(asking) }?.1, "a field for \(asking)")
        }

        func table(_ columns: String...) throws -> (id: Int, table: AUITable) {
            let found = all(AUITable.self).first { $0.1.columns?.map(\.title) == columns }
            let (id, table) = try #require(found, "a table of \(columns)")
            return (id, table)
        }

        var tabs: AUITabView? {
            bridge.views.values.lazy.compactMap { $0.children.first as? AUITabView }.first
        }

        /// The line over the tabs, and the line under them: the first two
        /// labels the program made.
        var heading: String { all(AUILabel.self).first?.1.text ?? "" }
        var status: String { all(AUILabel.self).dropFirst().first?.1.text ?? "" }

        func cell(_ table: (id: Int, table: AUITable), _ row: Int, _ column: Int) -> String {
            guard case .text(let text)? = try? bridge.perform(.cell(id: table.id, row: row, column: column)) else { return "" }
            return text
        }

        func rows(_ table: (id: Int, table: AUITable)) -> Int {
            table.table.rowCount()
        }

        // MARK: What the teacher does

        /// Switches to a tab, and waits for the program to fill the page in:
        /// switching clears the line under the tabs, so the test marks it
        /// first and waits for the mark to go.
        func show(_ tab: Int) async throws {
            let mark = "(switching)"
            all(AUILabel.self).dropFirst().first?.1.text = mark
            tabs?.selectedTabIndex = tab
            tabs?.onTabChange?(tab)
            try await studio.waitUntil("page \(tab) shown") { status != mark }
            // Clearing the line is the handler's first act; filling the
            // page in, and emptying its fields, comes after.
            try await settle()
        }

        /// Waits until the program has handled everything posted so far:
        /// two more turns of its window's `run()`, each of which runs the
        /// handlers waiting. Under load, a page could still be filling in
        /// (and emptying its fields) when the test typed into it.
        func settle() async throws {
            let start = BASICAUIRunLoop.passes
            try await studio.waitUntil("the program to settle") { BASICAUIRunLoop.passes >= start + 2 }
        }

        func click(_ title: String) throws {
            try button(title).onClick?()
        }

        func type(_ text: String, into asking: String) throws {
            try field(asking).text = text
        }

        func pick(row: Int, in table: (id: Int, table: AUITable)) {
            table.table.selectedRows = [row]
            table.table.onSelectionChange?([row])
        }

        func pick(_ index: Int, in picker: AUIPicker) {
            picker.selectedIndex = index
            picker.onSelectionChange?(index)
        }

        func pick(day: String, in picker: AUIDatePicker) throws {
            let date = try #require(StudioAUIBridge.date(from: day))
            picker.date = date
            picker.onChange?(date)
        }

        func typePoints(_ points: String, row: Int, in table: (id: Int, table: AUITable)) throws {
            let field = try #require(table.table.columns?[1].cellContent(row) as? AUITextField)
            field.onEndEditing?(points)
        }

        func mark(_ choice: Int, row: Int, in table: (id: Int, table: AUITable)) throws {
            let choices = try #require(table.table.columns?[1].cellContent(row) as? AUISegmentedControl)
            choices.onSelectionChange?(choice)
        }
    }

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gradebook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Waits for `condition`, and on a timeout says what the program's
    /// status line said, which is where it explains a refusal.
    /// Then waits for the program to settle: what is waited for is often a
    /// handler's first effect, and the rest of it comes after.
    private func waitFor(_ what: String, on screen: Screen, _ condition: () -> Bool) async throws {
        do {
            try await screen.studio.waitUntil(what, condition)
        } catch {
            Issue.record("\(what): the status line says \"\(screen.status)\"")
            throw error
        }
        try await screen.settle()
    }

    /// Runs the open project and waits for its window.
    private func run(_ screen: Screen) async throws {
        screen.studio.model.runEditorProgram()
        try await screen.studio.waitUntil("the Grade Book window") {
            screen.bridge.windows.keys.contains { (try? screen.bridge.perform(.isOpen(id: $0))) == .flag(true) } && screen.tabs != nil
        }
    }

    /// Closes the window, as the teacher quitting, and waits for the program
    /// to end.
    private func quit(_ screen: Screen) async throws {
        let window = try #require(screen.bridge.windows.keys.first)
        _ = try screen.bridge.perform(.close(id: window))
        try await screen.studio.waitUntilStopped()
    }

    @Test("A teacher's term, end to end: a book, students, assignments, grades, attendance, the summaries, and all of it again after quitting")
    func aTeachersTerm() async throws {
        let examples = try scratch()
        defer { try? FileManager.default.removeItem(at: examples) }
        let studio = StudioHarness()
        let model = studio.model
        model.auiBridge.showsWindows = false
        model.examplesFolderOverride = examples
        var asked: [String] = []
        model.auiBridge.presentDialog = { title, _, _, done in
            asked.append(title)
            done(0)
        }
        let screen = Screen(studio: studio)

        // Examples ▸ Apps ▸ Grade Book opens the project, on a copy.
        let example = try #require(model.bundledExamples.first { $0.projectFolder == "apps/GradeBook.basproj" })
        #expect(example.title == "Grade Book" && example.menuFolders == ["apps"])
        model.loadBundledExample(example)
        let project = examples.appendingPathComponent("GradeBook.basproj")
        #expect(model.currentProgramURL == project.appendingPathComponent("src/main.bas"))

        // The first run: no book yet, so the Books page.
        try await run(screen)
        #expect(screen.tabs?.selectedTabIndex == 0)
        #expect(screen.heading == "No book is open yet.")

        // A book for second period.
        try screen.type("Algebra I", into: "Class")
        try screen.type("2", into: "Period")
        try screen.click("Make book")
        let students = try screen.table("Last name", "First name", "Student ID")
        try await waitFor("the book made", on: screen) { screen.heading.hasPrefix("Period 2 - Algebra I - ") }
        // The heading changes first; the Students tab is picked after it.
        try await waitFor("the Students tab", on: screen) { screen.tabs?.selectedTabIndex == 1 }

        // Making the book picked the Students tab, whose change event fills
        // the page in and empties its fields, after the heading changed:
        // typing now could be wiped (flaky under load until 2026-10-10).
        try await screen.settle()

        // Students, and one added by mistake and deleted.
        for (first, last, number) in [("Ada", "Lovelace", ""), ("Grace", "Hopper", "1002"), ("Katherine", "Johnson", ""), ("Pat", "Mistake", "")] {
            try screen.type(first, into: "First name")
            try screen.type(last, into: "Last name")
            try screen.type(number, into: "Student ID")
            let before = screen.rows(students)
            try screen.click("Add student")
            try await waitFor("\(first) added", on: screen) { screen.rows(students) == before + 1 }
        }
        #expect((0..<4).map { screen.cell(students, $0, 0) } == ["Hopper", "Johnson", "Lovelace", "Mistake"])
        screen.pick(row: 3, in: students)
        try await waitFor("Pat picked", on: screen) { (try? screen.field("First name").text) == "Pat" }
        try screen.click("Delete student")
        try await waitFor("Pat deleted", on: screen) { screen.rows(students) == 3 }
        #expect(asked == ["Delete Pat Mistake?"])

        // A change to a student.
        screen.pick(row: 0, in: students)
        try await waitFor("Grace picked", on: screen) { (try? screen.field("Student ID").text) == "1002" }
        try screen.type("2002", into: "Student ID")
        try screen.click("Save changes")
        try await waitFor("Grace saved", on: screen) { screen.cell(students, 0, 2) == "2002" }
        #expect(screen.heading.hasSuffix("(3 students)"))

        // Assignments, each with its points, weight, date and term.
        try await screen.show(2)
        let assignments = try screen.table("Date", "Assignment", "Term", "Points", "Weight")
        let assignmentDate = try #require(screen.all(AUIDatePicker.self).first?.1)
        let termPicker = try #require(screen.all(AUIPicker.self).first { $0.1.options.first == "Q1" }?.1)
        for (title, points, weight, day, term) in [("Quiz 1", "20", "1", "2026-09-10", 0), ("Test 1", "100", "3", "2026-09-30", 0), ("Quiz 2", "20", "1", "2026-11-12", 1), ("Midterm", "50", "2", "2026-12-15", 4)] {
            try screen.type(title, into: "Assignment")
            try screen.type(points, into: "Points possible")
            try screen.type(weight, into: "Weight")
            assignmentDate.date = try #require(StudioAUIBridge.date(from: day))
            termPicker.selectedIndex = term
            let before = screen.rows(assignments)
            try screen.click("Add assignment")
            try await waitFor("\(title) added", on: screen) { screen.rows(assignments) == before + 1 }
        }
        #expect((0..<4).map { screen.cell(assignments, $0, 1) } == ["Quiz 1", "Test 1", "Quiz 2", "Midterm"])
        #expect(screen.cell(assignments, 3, 2) == "S1" && screen.cell(assignments, 3, 4) == "2")

        // Grades, an assignment at a time. Rows are Hopper, Johnson, Lovelace.
        try await screen.show(3)
        let grades = try screen.table("Student", "Points", "Percent", "Grade")
        let gradesFor = try #require(screen.all(AUIPicker.self).dropFirst().first?.1)
        try await waitFor("the grades page", on: screen) { gradesFor.options.count == 4 && screen.rows(grades) == 3 }
        #expect(gradesFor.options.first == "Quiz 1 (Q1, 20 points)")
        let entries: [[String]] = [["15", "20", "18"], ["", "70", "95"], ["12", "", "20"], ["40", "30", "45"]]
        for (assignment, points) in entries.enumerated() {
            screen.pick(assignment, in: gradesFor)
            try await waitFor("assignment \(assignment)", on: screen) { screen.cell(grades, 0, 1) == "" && screen.cell(grades, 0, 2) == "missing" }
            for (row, score) in points.enumerated() where !score.isEmpty {
                try screen.typePoints(score, row: row, in: grades)
                // Its handler's last act is to say so: the next pick waits
                // for it, so it cannot land before the handler is done.
                try await waitFor("points \(score)", on: screen) {
                    screen.cell(grades, row, 2) != "missing" && screen.status.hasPrefix("Saved \(score) for ")
                }
            }
        }
        // Midterm is showing: 40/50 is 80% and a B.
        #expect(screen.cell(grades, 0, 2) == "80%" && screen.cell(grades, 0, 3) == "B")
        // Something that is not a number is put back, and said so.
        try screen.typePoints("abc", row: 0, in: grades)
        try await waitFor("abc refused", on: screen) { screen.status.contains("is not a number of points") }
        #expect(screen.cell(grades, 0, 1) == "40")

        // Attendance on two days. Present 0, Absent 1, Tardy 2.
        try await screen.show(4)
        let attendance = try screen.table("Student", "Attendance")
        let day = try #require(screen.all(AUIDatePicker.self).last?.1)
        try screen.pick(day: "2026-10-05", in: day)
        try await waitFor("the 5th", on: screen) { screen.rows(attendance) == 3 && screen.cell(attendance, 0, 1) == "Present" }
        try screen.mark(1, row: 0, in: attendance)
        try screen.mark(2, row: 1, in: attendance)
        try await waitFor("the 5th marked", on: screen) { screen.status.hasPrefix("Marked Katherine Johnson Tardy") }
        try screen.pick(day: "2026-10-06", in: day)
        try await waitFor("the 6th", on: screen) { screen.cell(attendance, 1, 1) == "Present" }
        try screen.mark(1, row: 0, in: attendance)
        try screen.mark(2, row: 2, in: attendance)
        try screen.mark(0, row: 2, in: attendance)
        try await waitFor("the 6th marked", on: screen) { screen.status.hasPrefix("Marked Ada Lovelace Present") }
        try screen.pick(day: "2026-10-05", in: day)
        try await waitFor("the 5th again", on: screen) {
            screen.rows(attendance) == 3 && (0..<3).map { screen.cell(attendance, $0, 1) } == ["Absent", "Tardy", "Present"]
        }

        // The summary, against the figures worked out by hand.
        let expected: [[String]] = [
            ["Grace Hopper", "2", "0", "75 C", "60 D", "73.8 C", "-", "-", "-"],
            ["Katherine Johnson", "0", "1", "77.5 C", "-", "71.7 C", "-", "-", "-"],
            ["Ada Lovelace", "0", "0", "93.8 A", "100 A", "93.6 A", "-", "-", "-"],
        ]
        let summary = try screen.table("Student", "Absences", "Tardies", "Q1", "Q2", "S1", "Q3", "Q4", "S2")
        func summaryRows() -> [[String]] {
            (0..<screen.rows(summary)).map { row in (0..<9).map { screen.cell(summary, row, $0) } }
        }
        try await screen.show(5)
        try await waitFor("the summary", on: screen) { screen.rows(summary) == 3 }
        #expect(summaryRows() == expected)

        // One assignment's grades: Quiz 1 is two A's and a C, best first.
        try await screen.show(6)
        let report = try screen.table("Student", "Grade", "Points")
        let pie = try #require(screen.all(AUIChart.self).first?.1)
        try await waitFor("Quiz 1's summary", on: screen) { screen.rows(report) == 3 }
        let quiz1 = try #require(pie.marks.first as? AUISectorMark).resolve()
        #expect(quiz1.map(\.series) == ["A (2)", "C (1)"] && quiz1.map(\.y) == [2, 1])
        #expect((0..<3).map { "\(screen.cell(report, $0, 0)) \(screen.cell(report, $0, 1)) \(screen.cell(report, $0, 2))" } == [
            "Katherine Johnson A 20 of 20", "Ada Lovelace A 18 of 20", "Grace Hopper C 15 of 20",
        ])
        // Test 1: an A, a C, and Grace missing, last.
        let reportFor = try #require(screen.all(AUIPicker.self).last?.1)
        screen.pick(1, in: reportFor)
        try await waitFor("Test 1's summary", on: screen) { screen.cell(report, 0, 0) == "Ada Lovelace" }
        #expect(screen.cell(report, 2, 0) == "Grace Hopper" && screen.cell(report, 2, 1) == "Missing")

        // Quit, and run again: everything is still there.
        try await quit(screen)
        #expect(model.consoleText.contains("Grade Book closed. Everything is saved in "))
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("GradeBook.sqlite").path))
        try await run(screen)
        try await waitFor("the book reopened", on: screen) { screen.heading.hasPrefix("Period 2 - Algebra I - ") }
        #expect(screen.tabs?.selectedTabIndex == 1)
        let againStudents = try screen.table("Last name", "First name", "Student ID")
        #expect((0..<screen.rows(againStudents)).map { screen.cell(againStudents, $0, 0) } == ["Hopper", "Johnson", "Lovelace"])
        let againSummary = try screen.table("Student", "Absences", "Tardies", "Q1", "Q2", "S1", "Q3", "Q4", "S2")
        try await screen.show(5)
        try await waitFor("the summary again", on: screen) { screen.rows(againSummary) == 3 }
        #expect((0..<3).map { row in (0..<9).map { screen.cell(againSummary, row, $0) } } == expected)
        try await quit(screen)
    }
}
