//
//  TabletopCompanionTests.swift
//  BASICStudioTests
//
//  BASIC-48: the Tabletop Companion example. The dice first: the project's
//  own dice/Dice.bas, seeded with RANDOMIZE 7, rolls exactly what an
//  independent model of the same generator and rules predicts, interpreted
//  and as WebAssembly alike. Then a player, end to end: makes a wizard with
//  the standard array, types over a score, saves them, copies and deletes a
//  copy, rolls from the sheet with and without advantage, takes damage and
//  heals, marks a condition, adds gear and notes, puts them in the party and
//  rolls initiative, uses the dice tray, quits, runs it again, and finds
//  everything still there.
//

import ActiveUI
import BASICCore
import Foundation
import Testing
@testable import BASICStudio

@Suite("BASIC-48 · The Tabletop Companion example", .serialized)
@MainActor
struct TabletopCompanionTests {
    /// The program's controls, found the way a person finds them.
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

        /// The one list: a table with no columns.
        func list() throws -> (id: Int, table: AUITable) {
            let (id, table) = try #require(all(AUITable.self).first { $0.1.columns == nil }, "the gear list")
            return (id, table)
        }

        func picker(startingWith first: String) throws -> AUIPicker {
            try #require(all(AUIPicker.self).first { $0.1.options.first == first }?.1, "a picker of \(first)…")
        }

        func label(startingWith words: String) -> String? {
            all(AUILabel.self).first { $0.1.text.hasPrefix(words) }?.1.text
        }

        var tabs: AUITabView? {
            bridge.views.values.lazy.compactMap { $0.children.first as? AUITabView }.first
        }

        var heading: String { all(AUILabel.self).first?.1.text ?? "" }
        var status: String { all(AUILabel.self).dropFirst().first?.1.text ?? "" }

        func cell(_ table: (id: Int, table: AUITable), _ row: Int, _ column: Int) -> String {
            guard case .text(let text)? = try? bridge.perform(.cell(id: table.id, row: row, column: column)) else { return "" }
            return text
        }

        func rows(_ table: (id: Int, table: AUITable)) -> Int { table.table.rowCount() }

        func show(_ tab: Int) async throws {
            let mark = "(switching)"
            all(AUILabel.self).dropFirst().first?.1.text = mark
            tabs?.selectedTabIndex = tab
            tabs?.onTabChange?(tab)
            try await studio.waitUntil("page \(tab) shown") { status != mark }
        }

        /// Clears the status line, so the next thing it says can be waited for.
        func hush() { all(AUILabel.self).dropFirst().first?.1.text = "" }

        func click(_ title: String) throws { try button(title).onClick?() }

        func type(_ text: String, into asking: String) throws { try field(asking).text = text }

        func pick(row: Int, in table: (id: Int, table: AUITable)) {
            table.table.selectedRows = [row]
            table.table.onSelectionChange?([row])
        }

        func pick(_ option: String, in picker: AUIPicker) throws {
            let index = try #require(picker.options.firstIndex(of: option), "\(option) in \(picker.options)")
            picker.selectedIndex = index
            picker.onSelectionChange?(index)
        }

        /// Types into an editable cell, as finishing typing there does.
        func type(_ text: String, row: Int, column: Int, in table: (id: Int, table: AUITable)) throws {
            let field = try #require(table.table.columns?[column].cellContent(row) as? AUITextField)
            field.onEndEditing?(text)
        }

        /// Picks one of a cell's choices.
        func choose(_ choice: Int, row: Int, column: Int, in table: (id: Int, table: AUITable)) throws {
            let choices = try #require(table.table.columns?[column].cellContent(row) as? AUISegmentedControl)
            choices.onSelectionChange?(choice)
        }
    }

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tabletop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func waitFor(_ what: String, on screen: Screen, _ condition: () -> Bool) async throws {
        do {
            try await screen.studio.waitUntil(what, condition)
        } catch {
            Issue.record("\(what): the status line says \"\(screen.status)\"")
            throw error
        }
    }

    private func run(_ screen: Screen) async throws {
        screen.studio.model.runEditorProgram()
        try await screen.studio.waitUntil("the Tabletop Companion window") {
            screen.bridge.windows.keys.contains { (try? screen.bridge.perform(.isOpen(id: $0))) == .flag(true) } && screen.tabs != nil
        }
    }

    private func quit(_ screen: Screen) async throws {
        let window = try #require(screen.bridge.windows.keys.first)
        _ = try screen.bridge.perform(.close(id: window))
        try await screen.studio.waitUntilStopped()
    }

    // MARK: - The dice

    /// What RANDOMIZE 7 rolls for each, worked out by a model of the same
    /// generator (a 64-bit LCG, `INT(RND * sides) + 1`) and the rules in
    /// Dice.bas, written apart from it; and what bad notation is told.
    private static let seededRolls = """
        d20 = [10] = 10
        3d8+2 = [7, 1, 1] + 2 = 11
        4d6dl1 = [(3), 6, 4, 3] = 13
        4d6dh1 = [3, 3, 2, (6)] = 8
        2d20kh1+3 = [(1), 9] + 3 = 12
        2d20kl1-1 = [10, (12)] - 1 = 9
        1d8+1d6+3 = [5] + [1] + 3 = 9
        d% = [39] = 39
        4dF = [+, -, +, +] = 2
        10d6! = [6!+1, 5, 1, 4, 1, 1, 3, 5, 2, 5] = 34
        d2 = [2] = 2
        3d7 = [1, 4, 6] = 11
        D 30 + 5 = [16] + 5 = 21
        5 = 5 = 5
        -d4+10 = -[2] + 10 = 8
        2d6dl2 ! Dropping 2 of 2 dice would leave none.
        d1 ! A die has from 2 to 1000 sides, not 1.
        3x ! Expected + or - before "x".
        4dF! ! Fudge dice do not explode.
        2d20kh = [(8), 15] = 15
        3d6+ ! Expected dice or a number at the end.
        """

    /// The project's Text.bas and dice/Dice.bas, with the globals main.bas
    /// declares for them, and a driver that rolls each notation above.
    private func diceProgram(in project: URL) throws -> String {
        let text = try String(contentsOf: project.appendingPathComponent("src/Text.bas"), encoding: .utf8)
        let dice = try String(contentsOf: project.appendingPathComponent("src/dice/Dice.bas"), encoding: .utf8)
        // Each line is the notation, then " = " and the roll, or " ! " and
        // why it cannot be read.
        let notations = Self.seededRolls.split(separator: "\n").map { line in
            let end = [line.range(of: " = "), line.range(of: " ! ")].compactMap { $0?.lowerBound }.min() ?? line.endIndex
            return String(line[..<end])
        }
        let rolls = notations.map { "Show(\"\($0)\")" }.joined(separator: "\n")
        return """
            GLOBAL DiceTotal = 0
            GLOBAL DiceDetail$ = ""
            GLOBAL DiceError$ = ""
            GLOBAL DiceSource$ = ""
            GLOBAL DiceAt = 1
            GLOBAL DiceTermShown$ = ""
            GLOBAL DieRoll(99) AS INTEGER
            GLOBAL DieKept(99) AS INTEGER
            GLOBAL DieShown$(99) AS STRING
            \(text)
            \(dice)
            FUNCTION Show(notation$ AS STRING)
                LOCAL total = RollDice(notation$)
                IF DiceError$ <> "" THEN
                    PRINT notation$; " ! "; DiceError$
                ELSE
                    PRINT notation$; " = "; DiceDetail$
                END IF
            END FUNCTION
            PRINT "ROLLS"
            RANDOMIZE 7
            \(rolls)
            PRINT "DONE"
            """
    }

    private func printedRolls(_ console: String) -> String? {
        guard let start = console.range(of: "ROLLS\n", options: .backwards),
              let end = console.range(of: "DONE", range: start.upperBound..<console.endIndex) else { return nil }
        return String(console[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .newlines)
    }

    @Test("The dice notation, seeded: every die, keep and drop, explosions, Fudge dice, several terms, and bad notation, interpreted and as WebAssembly")
    func seededDice() async throws {
        let examples = try scratch()
        defer { try? FileManager.default.removeItem(at: examples) }
        let setup = StudioHarness()
        setup.model.examplesFolderOverride = examples
        let example = try #require(setup.model.bundledExamples.first { $0.projectFolder == "apps/TabletopCompanion.basproj" })
        setup.model.loadBundledExample(example)
        let program = try diceProgram(in: examples.appendingPathComponent("TabletopCompanion.basproj"))

        let interpreted = StudioHarness(program: program)
        interpreted.model.runEditorProgram()
        try await interpreted.waitUntilStopped()
        #expect(printedRolls(interpreted.model.consoleText) == Self.seededRolls, "\(interpreted.model.consoleText.suffix(1200))")

        let compiled = StudioHarness(program: program)
        compiled.model.compiledRunTarget = .webAssembly
        compiled.model.jitEditorProgram()
        try await compiled.waitUntil("the WebAssembly run to finish", timeout: .seconds(120)) {
            !compiled.model.isJITRunning && compiled.model.consoleText.contains("DONE")
        }
        #expect(printedRolls(compiled.model.consoleText) == Self.seededRolls, "\(compiled.model.consoleText.suffix(1200))")
    }

    // MARK: - As WebAssembly

    @Test("As WebAssembly, as on iPad: the window opens on the Generator, a character is saved, and the dice tray rolls")
    func asWebAssembly() async throws {
        let examples = try scratch()
        defer { try? FileManager.default.removeItem(at: examples) }
        let studio = StudioHarness()
        let model = studio.model
        model.auiBridge.showsWindows = false
        model.examplesFolderOverride = examples
        let screen = Screen(studio: studio)
        let example = try #require(model.bundledExamples.first { $0.projectFolder == "apps/TabletopCompanion.basproj" })
        model.loadBundledExample(example)

        model.compiledRunTarget = .webAssembly
        model.jitEditorProgram()
        try await studio.waitUntil("the window, compiled", timeout: .seconds(120)) {
            screen.bridge.windows.keys.contains { (try? screen.bridge.perform(.isOpen(id: $0))) == .flag(true) } && screen.tabs != nil
        }
        let scores = try screen.table("Ability", "Score", "Modifier")
        try await waitFor("the draft", on: screen) { screen.rows(scores) == 6 }
        try screen.type("Kai Compiled", into: "Name")
        try screen.click("Save character")
        try await waitFor("Kai saved", on: screen) { screen.heading.hasPrefix("Kai Compiled - ") }

        try await screen.show(4)
        let history = try screen.table("Dice", "How they came up", "Total")
        let roll = try screen.field("Dice to roll")
        for (die, made) in [("dF", "dF"), ("dF", "2dF"), ("d4", "d4+2dF")] {
            try screen.click(die)
            try await waitFor(made, on: screen) { roll.text == made }
        }
        try screen.click("Roll")
        try await waitFor("two Fudge dice and a d4", on: screen) { screen.rows(history) == 1 }
        #expect((-1...6).contains(Int(screen.cell(history, 0, 2)) ?? 99), "\(screen.cell(history, 0, 1))")

        let window = try #require(screen.bridge.windows.keys.first)
        _ = try screen.bridge.perform(.close(id: window))
        try await studio.waitUntil("the compiled run to end", timeout: .seconds(30)) { !model.isJITRunning }
        #expect(!model.consoleText.contains("rror"), "\(model.consoleText.suffix(400))")
        #expect(model.consoleText.contains("Tabletop Companion closed."), "\(model.consoleText.suffix(400))")
    }

    // MARK: - A player, end to end

    @Test("A player, end to end: make a character, keep them, play them, roll for them, and find them all again after quitting")
    func aPlayersEvening() async throws {
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

        // Examples ▸ Apps ▸ Tabletop Companion opens the project, on a copy.
        let example = try #require(model.bundledExamples.first { $0.projectFolder == "apps/TabletopCompanion.basproj" })
        #expect(example.title == "Tabletop Companion" && example.menuFolders == ["apps"])
        model.loadBundledExample(example)
        let project = examples.appendingPathComponent("TabletopCompanion.basproj")
        #expect(model.currentProgramURL == project.appendingPathComponent("src/main.bas"))

        // The first run: nobody yet, so the Generator, with a draft ready.
        try await run(screen)
        #expect(screen.tabs?.selectedTabIndex == 1)
        #expect(screen.heading == "No character is being played yet.")
        let scores = try screen.table("Ability", "Score", "Modifier")
        try await waitFor("the draft", on: screen) { screen.rows(scores) == 6 }
        #expect((0..<6).map { screen.cell(scores, $0, 0) } == ["Strength", "Dexterity", "Constitution", "Intelligence", "Wisdom", "Charisma"])
        #expect(try !screen.field("Name").text.isEmpty, "a name made up")
        // D&D's standard array to begin with, the best where a fighter
        // needs it: Strength, then Constitution, then Dexterity.
        try await waitFor("the standard array", on: screen) { (0..<6).map { screen.cell(scores, $0, 1) } == ["15", "13", "14", "10", "12", "8"] }

        // A wizard, by the standard array: the 15 goes on Intelligence, the
        // 8 on Strength, as a wizard's needs say.
        try screen.pick("Wizard", in: try screen.picker(startingWith: "Fighter"))
        try await waitFor("the wizard's gear", on: screen) { screen.label(startingWith: "Gear:")?.contains("Spellbook") == true }
        try screen.pick("Standard array", in: try screen.picker(startingWith: "4d6, drop the lowest"))
        try await waitFor("the standard array", on: screen) { (0..<6).map { screen.cell(scores, $0, 1) } == ["8", "14", "13", "15", "12", "10"] }

        // A score typed over, and one refused.
        try screen.type("16", row: 3, column: 1, in: scores)
        try await waitFor("Intelligence 16", on: screen) { screen.cell(scores, 3, 2) == "+3" }
        try screen.type("19", row: 0, column: 1, in: scores)
        try await waitFor("19 refused", on: screen) { screen.status == "A score is from 3 to 18." }
        #expect(screen.cell(scores, 0, 1) == "8")
        // Hit points: a d6 and +1 for Constitution 13.
        #expect(screen.label(startingWith: "Hit points 7 (a d6 hit die, +1 for Constitution)") != nil, "\(screen.label(startingWith: "Hit points") ?? "")")

        // Named and saved, and played at once.
        try screen.type("Mira Test", into: "Name")
        try screen.click("Save character")
        try await waitFor("Mira saved", on: screen) { screen.heading == "Mira Test - Human Wizard, level 1" }

        // The Characters page: copied, and the copy deleted, after asking.
        try await screen.show(0)
        let characters = try screen.table("Name", "Genre", "Ancestry", "Role", "Level", "Hit points", "Portrait")
        try await waitFor("the characters", on: screen) { screen.rows(characters) == 1 }
        #expect(screen.cell(characters, 0, 0) == "Mira Test" && screen.cell(characters, 0, 5) == "7 of 7")
        screen.pick(row: 0, in: characters)
        try await waitFor("Mira picked", on: screen) { screen.status.hasPrefix("Playing Mira Test") }
        try screen.click("Copy character")
        try await waitFor("the copy", on: screen) { screen.rows(characters) == 2 }
        #expect(screen.cell(characters, 1, 0) == "Mira Test (copy)")
        screen.pick(row: 1, in: characters)
        try await waitFor("the copy picked", on: screen) { screen.heading.hasPrefix("Mira Test (copy)") }
        try screen.click("Delete character")
        try await waitFor("the copy deleted", on: screen) { screen.rows(characters) == 1 }
        #expect(asked == ["Delete Mira Test (copy)?"])
        #expect(screen.heading == "No character is being played yet.")
        screen.pick(row: 0, in: characters)
        try await waitFor("Mira played again", on: screen) { screen.heading == "Mira Test - Human Wizard, level 1" }

        // The sheet: a check with one tap, then another with advantage.
        try await screen.show(2)
        let abilities = try screen.table("Ability", "Score", "Modifier", "Check")
        try await waitFor("Mira's abilities", on: screen) { screen.rows(abilities) == 6 && screen.cell(abilities, 3, 3) == "1d20+3" }
        #expect(screen.cell(abilities, 3, 1) == "16")
        screen.pick(row: 3, in: abilities)
        try await waitFor("an Intelligence check", on: screen) { screen.label(startingWith: "Intelligence check (1d20+3): [") != nil }
        try screen.pick("Advantage", in: try screen.picker(startingWith: "Normal"))
        screen.pick(row: 0, in: abilities)
        try await waitFor("a Strength check with advantage", on: screen) { screen.label(startingWith: "Strength check (2d20kh1-1): [") != nil }
        try screen.click("Attack")
        try await waitFor("an attack", on: screen) { screen.label(startingWith: "Attack (2d20kh1+4): [") != nil }

        // Hit points: hurt, healed, temporary ones, which go first.
        func amount(_ hit: String, _ button: String, then health: String) async throws {
            try screen.type(hit, into: "Amount")
            try screen.click(button)
            try await waitFor("\(button) \(hit)", on: screen) { screen.label(startingWith: "Hit points: ") == "Hit points: \(health)" }
        }
        try await amount("3", "Take damage", then: "4 of 7")
        try await amount("10", "Heal", then: "7 of 7")
        try await amount("5", "Temporary hit points", then: "7 of 7, and 5 temporary")
        try await amount("6", "Take damage", then: "6 of 7")

        // A condition, gear and notes.
        let conditions = try screen.table("Condition", "Has it")
        #expect(screen.cell(conditions, 5, 0) == "Prone")
        try screen.choose(1, row: 5, column: 1, in: conditions)
        try await waitFor("Mira prone", on: screen) { screen.status == "Mira Test is prone." }
        let gear = try screen.list()
        let carried = screen.rows(gear)
        try screen.type("Lantern", into: "New item")
        try screen.click("Add item")
        try await waitFor("the lantern", on: screen) { screen.rows(gear) == carried + 1 }
        #expect(screen.cell(gear, carried, 0) == "Lantern")
        try screen.type("Owes the innkeeper", into: "Notes")
        try screen.click("Save notes")
        try await waitFor("the notes saved", on: screen) { screen.status == "Saved the notes for Mira Test." }

        // The party: Mira at the table, and initiative.
        try await screen.show(3)
        let members = try screen.table("Name", "Role", "Hit points", "In the party")
        try await waitFor("the party's list", on: screen) { screen.cell(members, 0, 2) == "6 of 7" }
        try screen.choose(1, row: 0, column: 3, in: members)
        try await waitFor("Mira in the party", on: screen) { screen.status == "Mira Test joins the party." }
        try screen.click("Roll initiative")
        let order = try screen.table("Turn", "Name", "Initiative")
        try await waitFor("the order", on: screen) { screen.status == "Mira Test goes first." }
        #expect(screen.rows(order) == 1)
        #expect(screen.cell(order, 0, 1) == "Mira Test")
        let log = try screen.table("Who", "For", "Dice", "Total")
        #expect((0..<screen.rows(log)).map { screen.cell(log, $0, 1) } == ["Initiative", "Attack", "Strength check", "Intelligence check"])

        // The dice tray: a d7, dice pressed into one roll, a die added to a
        // roll typed in, a roll typed in, and one that cannot be read.
        try await screen.show(4)
        let history = try screen.table("Dice", "How they came up", "Total")
        let roll = try screen.field("Dice to roll")
        try screen.click("d7")
        try await waitFor("d7 in the box", on: screen) { roll.text == "d7" }
        try screen.click("Roll")
        try await waitFor("a d7", on: screen) { screen.rows(history) == 1 }
        let seven = Int(screen.cell(history, 0, 2)) ?? 0
        #expect((1...7).contains(seven))
        try screen.click("Clear")
        try await waitFor("an empty box", on: screen) { roll.text.isEmpty }
        for (die, made) in [("d6", "d6"), ("d8", "d6+d8"), ("d6", "2d6+d8")] {
            try screen.click(die)
            try await waitFor(made, on: screen) { roll.text == made }
        }
        try screen.click("Roll")
        try await waitFor("2d6+d8", on: screen) { screen.rows(history) == 2 }
        #expect(screen.cell(history, 0, 0) == "2d6+d8")
        #expect((3...20).contains(Int(screen.cell(history, 0, 2)) ?? 0), "\(screen.cell(history, 0, 1))")
        try screen.type("3d8+2", into: "Dice to roll")
        try screen.click("d4")
        try await waitFor("a d4 added", on: screen) { roll.text == "3d8+2+d4" }
        try screen.type("4d6dl1", into: "Dice to roll")
        try screen.click("Roll")
        try await waitFor("4d6dl1", on: screen) { screen.rows(history) == 3 }
        #expect(screen.cell(history, 0, 0) == "4d6dl1" && screen.cell(history, 0, 1).contains("("))
        try screen.type("3x", into: "Dice to roll")
        try screen.click("Roll")
        try await waitFor("3x refused", on: screen) { screen.label(startingWith: "Could not roll") != nil }
        #expect(screen.label(startingWith: "Could not roll") == "Could not roll \"3x\": Expected + or - before \"x\".")
        #expect(screen.rows(history) == 3)

        // Quit, and run it again: Mira, as she was left.
        try await quit(screen)
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("TabletopCompanion.sqlite").path))
        try await run(screen)
        try await waitFor("Mira again", on: screen) { screen.heading == "Mira Test - Human Wizard, level 1" }
        #expect(screen.tabs?.selectedTabIndex == 0)
        try await screen.show(2)
        // The notes are the last of the sheet to be filled in.
        try await waitFor("Mira's sheet", on: screen) { (try? screen.field("Notes").text) == "Owes the innkeeper" }
        #expect(screen.label(startingWith: "Hit points: ") == "Hit points: 6 of 7")
        let conditionsAgain = try screen.table("Condition", "Has it")
        #expect(screen.cell(conditionsAgain, 5, 1) == "Yes")
        let gearAgain = try screen.list()
        #expect((0..<screen.rows(gearAgain)).map { screen.cell(gearAgain, $0, 0) }.last == "Lantern")
        try await screen.show(3)
        let logAgain = try screen.table("Who", "For", "Dice", "Total")
        try await waitFor("the session's log, kept", on: screen) { screen.rows(logAgain) >= 4 }
        try await quit(screen)
    }
}
