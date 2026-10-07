//
//  EditorRibbonTests.swift
//  BASICStudioTests
//
//  The ribbon over the editor: the outline it reads from a program, the
//  menu it makes of it, MARK groups and their lines, and jumping.
//

import ActiveUI
import Foundation
import Testing
@testable import BASICStudio

@Suite("Editor ribbon", .serialized)
@MainActor
struct EditorRibbonTests {
    private let program = """
    ' A program with a little of everything.
    GLOBAL score AS INTEGER

    ' MARK: - Playing -
    FUNCTION Main() AS VOID
        PRINT Num$(score)
    END FUNCTION

    FUNCTION Num$(value AS INTEGER) AS STRING
        RETURN STR$(value)
    END FUNCTION

    ' MARK: - Shapes
    CLASS Report
        public Title as string
        function Summary$() as string
            return ME.Title
        end function
        PRIVATE OVERRIDES FUNCTION Hidden() AS INTEGER
            RETURN 1
        END FUNCTION
    END CLASS

    INTERFACE Printable
        FUNCTION ToText$() AS STRING
    END INTERFACE

    TYPE Point
        X AS DOUBLE
        Y AS DOUBLE
    END TYPE

    DEF FNArea(r) = 3.14159 * r * r
    REM MARK: Last words
    ASYNC FUNCTION Later() AS VOID
    END FUNCTION
    Main()
    """

    // MARK: - The outline

    @Test("Functions, classes and their methods, types and MARKs, in the order written")
    func outline() {
        let outline = ProgramOutline(program)
        #expect(outline.entries.map(\.title) == [
            "Playing", "Main", "Num$", "Shapes", "Report", "Report.Summary$", "Report.Hidden",
            "Printable", "Point", "FNArea", "Last words", "Later",
        ])
        #expect(outline.entries.map(\.line) == [4, 5, 9, 13, 14, 16, 19, 24, 28, 33, 34, 35])
        let main = outline.entries[1]
        #expect(main.kind == .function && main.endLine == 7)
        #expect(outline.entries[4].kind == .class && outline.entries[4].endLine == 22)
        #expect(outline.entries[7].kind == .interface)
        #expect(outline.entries[8].kind == .type)
    }

    @Test("A MARK's dashes say where its lines go")
    func markDashes() {
        let marks = ProgramOutline("""
        ' MARK: - Both -
        ' MARK: - Before
        ' MARK: After -
        ' mark: Neither
        ' MARK: -
        x = 1 ' MARK: not at the start of the line
        PRINT "MARK: in a string"
        """).entries
        #expect(marks.map(\.name) == ["Both", "Before", "After", "Neither", ""])
        #expect(marks.map(\.separatorBefore) == [true, true, false, false, true])
        #expect(marks.map(\.separatorAfter) == [true, false, true, false, false])
    }

    @Test("MARK after any of BASIC's comments; nothing in a comment is a function")
    func commentKinds() {
        let entries = ProgramOutline("""
        // MARK: - Slashes
        # MARK: Hash -
        REM MARK: Rem
        // FUNCTION Old()
        # FUNCTION Older()
        ' FUNCTION Oldest()
        REM FUNCTION Ancient()
        10 FUNCTION Numbered()
        END FUNCTION
        """).entries
        #expect(entries.map(\.title) == ["Slashes", "Hash", "Rem", "Numbered"])
    }

    @Test("The caret's function: a method before its class, and none outside them")
    func containing() {
        let outline = ProgramOutline(program)
        #expect(outline.entry(containing: 6)?.title == "Main")
        #expect(outline.entry(containing: 17)?.title == "Report.Summary$")
        #expect(outline.entry(containing: 15)?.title == "Report")
        #expect(outline.entry(containing: 2) == nil)
        #expect(outline.entry(containing: 4) == nil)
        #expect(outline.entry(containing: 37) == nil)
    }

    @Test("A function still being typed, with no END yet, runs to the end")
    func unfinished() {
        let outline = ProgramOutline("FUNCTION Half(n)\n  RETURN n / 2\n")
        #expect(outline.entries.map(\.name) == ["Half"])
        #expect(outline.entry(containing: 3)?.name == "Half")
    }

    // MARK: - The menu

    private func describe(_ rows: [EditorRibbonAUI.Row]) -> [String] {
        rows.map { row in
            switch row {
            case .entry(let entry): return entry.title
            case .heading(let name): return "# " + name
            case .line: return "---"
            case .empty(let text): return "(\(text))"
            }
        }
    }

    @Test("The menu: MARK headings with their lines, never doubled, nor first or last")
    func menuRows() {
        let rows = EditorRibbonAUI.rows(for: ProgramOutline(program))
        #expect(describe(rows) == [
            "# Playing", "---", "Main", "Num$", "---", "# Shapes", "Report", "Report.Summary$",
            "Report.Hidden", "Printable", "Point", "FNArea", "# Last words", "Later",
        ])
    }

    @Test("A bare MARK is a line, and a MARK at the end heads nothing")
    func bareAndTrailingMarks() {
        let rows = EditorRibbonAUI.rows(for: ProgramOutline("""
        FUNCTION A()
        END FUNCTION
        ' MARK: -
        ' MARK: -
        FUNCTION B()
        END FUNCTION
        ' MARK: - Tail -
        """))
        #expect(describe(rows) == ["A", "---", "B"])
        #expect(describe(EditorRibbonAUI.rows(for: ProgramOutline("PRINT 1\n"))) == ["(No functions in this file)"])
    }

    @Test("Choosing a function jumps there, and the title says where the caret is")
    func jumping() {
        let ribbon = EditorRibbonAUI()
        let text = program
        ribbon.text = { text }
        var jumps: [Int] = []
        ribbon.onJump = { jumps.append($0) }
        ribbon.refresh(fileName: "main.bas")
        #expect(ribbon.fileLabel.text == "main.bas")
        #expect(ribbon.functionsButton.title == EditorRibbonAUI.mainProgramTitle)

        let items = ribbon.menuItems()
        let summary = try? #require(items.first { $0.title == "Summary$" || $0.title == "Report.Summary$" })
        summary?.perform()
        #expect(jumps == [16])
        #expect(ribbon.functionsButton.title == "Report.Summary$")
        #expect(ribbon.functionsButton.systemSymbol == "f.square")

        ribbon.caretMoved(to: 2)
        #expect(ribbon.functionsButton.title == EditorRibbonAUI.mainProgramTitle)
        ribbon.caretMoved(to: 14)
        #expect(ribbon.functionsButton.title == "Report")
        #expect(ribbon.functionsButton.systemSymbol == "c.square")
    }

    @Test("In the shell, the ribbon heads the editor and moves its caret")
    func inTheShell() throws {
        let model = StudioHarness().model
        let studio = StudioActiveUIShell(model: model)
        model.programText = program
        studio.refresh()
        #expect(studio.ribbon.functionsButton.title == EditorRibbonAUI.mainProgramTitle)
        #expect(studio.ribbon.fileLabel.text == "Untitled")

        studio.ribbon.jump(to: 9)
        #expect(studio.ribbon.functionsButton.title == "Num$")
        #expect(SourceEditorAUI.line(at: 0, in: "a\nb") == 1)
        #expect(SourceEditorAUI.line(at: 2, in: "a\nb") == 2)
    }
}
