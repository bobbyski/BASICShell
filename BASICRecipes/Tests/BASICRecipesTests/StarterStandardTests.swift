//
//  StarterStandardTests.swift
//  BASICRecipesTests
//
//  Every starter done right (Freebird Studio's New Project plan, Phase 9):
//  each recipe split into models, views, controllers and app, its main.bas
//  only wiring them together, a documentation comment on every routine,
//  type, field and GLOBAL, the commands each in one routine and grayed out
//  until they apply, and data kept in Application Support.
//

import Foundation
import Testing
@testable import BASICRecipes

/// A recipe's `.bas` files, by path under `src/`.
private func sources(_ shortName: String) throws -> [String: String] {
    let recipe = try #require(BASICRecipes.builtIn(named: shortName), "no recipe \(shortName)")
    var files: [String: String] = [:]
    for file in recipe.files where file.path.hasPrefix("src/") && file.path.hasSuffix(".bas") {
        files[String(file.path.dropFirst("src/".count))] = file.contents
    }
    return files
}

/// A line with its comment and surrounding blanks taken off: `'` starts a
/// comment anywhere outside a string.
private func code(_ line: Substring) -> String {
    // `//` and `///` start comments too, as they do in Swift.
    if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return "" }
    var inString = false
    var result = ""
    for character in line {
        if character == "\"" { inString.toggle() }
        if character == "'" && !inString { break }
        result.append(character)
    }
    return result.trimmingCharacters(in: .whitespaces)
}

// MARK: - Documentation comments

/// What is wrong with a file's documentation comments: each declaration that
/// has none on the line above it, each parameter its comment leaves out, and
/// each result it does not describe.
///
/// The form is BASIC's own (`BASICDocumentation.swift`, checked by
/// basiclint's `doc.*` rules): `///` lines just above the declaration, a
/// summary, then `- Parameter name:` for each parameter and `- Returns:` for
/// a result. Declarations are `CLASS`, `TYPE`, `RECORD`, `FUNCTION` (and
/// methods), `GLOBAL`, a class's `PUBLIC` fields and a type's fields.
func documentationProblems(in text: String, file: String) -> [String] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var problems: [String] = []
    var insideType = false
    for (number, raw) in lines.enumerated() {
        let line = code(raw)
        let upper = line.uppercased()
        if upper.hasPrefix("END TYPE") || upper.hasPrefix("END RECORD") { insideType = false; continue }
        let declares = ["CLASS ", "TYPE ", "RECORD ", "FUNCTION ", "GLOBAL ", "PUBLIC "].contains { upper.hasPrefix($0) }
            || (insideType && upper.contains(" AS "))
        if upper.hasPrefix("TYPE ") || upper.hasPrefix("RECORD ") { insideType = true }
        guard declares else { continue }

        // The comment is the run of `///` lines just above.
        var comment: [String] = []
        var above = number - 1
        while above >= 0, lines[above].trimmingCharacters(in: .whitespaces).hasPrefix("///") {
            comment.insert(lines[above].trimmingCharacters(in: .whitespaces), at: 0)
            above -= 1
        }
        let place = "\(file):\(number + 1) \(line)"
        guard !comment.isEmpty else {
            problems.append("\(place): no /// comment")
            continue
        }
        guard upper.hasPrefix("FUNCTION ") else { continue }

        // Each parameter is documented, and a result other than VOID too.
        let signature = line.dropFirst("FUNCTION ".count)
        if let open = signature.firstIndex(of: "("), let close = signature.lastIndex(of: ")"), open < close {
            let list = signature[signature.index(after: open)..<close]
            for parameter in list.split(separator: ",") {
                let name = parameter.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
                guard !name.isEmpty else { continue }
                if !comment.contains(where: { $0.hasPrefix("/// - Parameter \(name):") }) {
                    problems.append("\(place): parameter \(name) is not documented")
                }
            }
            let result = signature[signature.index(after: close)...].trimmingCharacters(in: .whitespaces).uppercased()
            if result.hasPrefix("AS ") && result != "AS VOID" && !comment.contains(where: { $0.hasPrefix("/// - Returns:") }) {
                problems.append("\(place): what it returns is not documented")
            }
        }
    }
    return problems
}

@Suite("Every starter done right")
struct StarterStandardTests {
    /// The starters held to the standard, by short name.
    static let starters = ["activeui.counter", "activeui", "activeui.masterdetail"]

    /// The ActiveUI starters' files, each in its folder.
    static let activeUIFiles: [(String, Set<String>)] = [
        ("activeui.counter", ["main.bas", "models/Counter.bas", "views/CounterView.bas",
                              "controllers/CounterWindowController.bas"]),
        ("activeui", ["main.bas", "models/TodoTask.bas", "models/TaskList.bas", "models/TaskStore.bas",
                      "models/TabSeparated.bas", "views/TaskListView.bas", "views/StatusBarView.bas",
                      "controllers/TodoWindowController.bas", "app/DataFolder.bas"]),
        ("activeui.masterdetail", ["main.bas", "models/Item.bas", "models/ItemList.bas", "models/ItemStore.bas",
                                   "models/TabSeparated.bas", "views/ItemSidebarView.bas", "views/ItemDetailView.bas",
                                   "controllers/ItemsWindowController.bas", "app/DataFolder.bas"]),
    ]

    @Test("The ActiveUI starters are split into models, views, controllers and app, and main.bas imports each file",
          arguments: activeUIFiles)
    func fileSet(starter: (String, Set<String>)) throws {
        let files = try sources(starter.0)
        #expect(Set(files.keys) == starter.1)
        let main = try #require(files["main.bas"])
        for path in starter.1 where path != "main.bas" {
            #expect(main.contains("IMPORT \"\(path)\""), "\(starter.0): main.bas does not import \(path)")
        }
        let recipe = try #require(BASICRecipes.builtIn(named: starter.0))
        #expect(recipe.files.contains { $0.path == "README.md" && $0.contents.contains("How the comments are written") },
                "\(starter.0) has a README of its own that says how the comments are written")
    }

    @Test("Each main.bas only wires the parts together: no routines or types, the parts as GLOBALs, and a short start",
          arguments: starters)
    func mainOnlyWires(starter: String) throws {
        let main = try #require(try sources(starter)["main.bas"])
        var statements: [String] = []
        for raw in main.split(separator: "\n") {
            let line = code(raw)
            guard !line.isEmpty else { continue }
            let upper = line.uppercased()
            #expect(!["FUNCTION ", "CLASS ", "TYPE ", "RECORD ", "SUB "].contains { upper.hasPrefix($0) },
                    "\(starter): main.bas declares \(line)")
            if !upper.hasPrefix("IMPORT ") && !upper.hasPrefix("GLOBAL ") { statements.append(line) }
        }
        // Each statement makes a part, or starts the window and runs it.
        #expect(statements.count <= 8, "\(starter): \(statements)")
        #expect(statements.last == "theWindow.Run()")
        #expect(statements.contains { $0.hasPrefix("theWindow.Start(\"{{NAME}}\"") })
        for statement in statements.dropLast() {
            let wires = statement.contains(" = NEW ") || statement.hasPrefix("theWindow.Start(")
                || statement.contains("File$ = DataFolder$(\"{{NAME}}\")") || statement.contains(" = Read")
            #expect(wires, "\(starter): main.bas does more than wire: \(statement)")
        }
    }

    /// Every recipe, by short name: all of them are held to the comments.
    static let everyRecipe = BASICRecipes.builtIn.map(BASICRecipes.shortName)

    @Test("Every routine, type, field and GLOBAL has a /// documentation comment, with its parameters and result",
          arguments: everyRecipe)
    func documentation(starter: String) throws {
        for (path, text) in try sources(starter).sorted(by: { $0.key < $1.key }) {
            let problems = documentationProblems(in: text, file: "\(starter)/\(path)")
            #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
        }
    }

    /// The other starters' files, each in its folder. The console and
    /// structured programs are one file on purpose (the smallest program,
    /// and a program small enough to read at once), and the gallery keeps
    /// the one folder of the Swift gallery it translates file for file.
    static let otherFiles: [(String, Set<String>)] = [
        ("console", ["main.bas"]),
        ("structured", ["main.bas"]),
        ("game", ["main.bas", "models/Characters.bas", "models/Shooting.bas", "views/GameView.bas",
                  "controllers/Controls.bas", "controllers/GameLoop.bas"]),
        ("tui", ["main.bas", "models/LanguageList.bas", "models/Greeting.bas", "views/GreetingView.bas",
                 "views/StatusLine.bas", "controllers/MainWindowController.bas", "app/AppMenus.bas"]),
        ("contacts", ["main.bas", "models/ContactModel.bas", "models/ContactStorage.bas", "views/ContactWindow.bas",
                      "views/ContactDialogs.bas", "app/ContactApp.bas", "app/DataFolder.bas"]),
    ]

    @Test("The other starters are in folders as far as each is meant to be, and main.bas imports each file",
          arguments: otherFiles)
    func otherFileSets(starter: (String, Set<String>)) throws {
        let files = try sources(starter.0)
        #expect(Set(files.keys) == starter.1)
        let main = try #require(files["main.bas"])
        for path in starter.1 where path != "main.bas" {
            #expect(main.contains("IMPORT \"\(path)\""), "\(starter.0): main.bas does not import \(path)")
        }
        // Only main.bas imports, so the files are read in one place.
        for (path, text) in files where path != "main.bas" {
            #expect(!text.split(separator: "\n").map(code).contains { $0.uppercased().hasPrefix("IMPORT ") }, "\(starter.0)/\(path)")
        }
    }

    @Test("The TUI App, the Game and the Contact Book start from main.bas in a line or two",
          arguments: [("tui", ["theApp = TUIApp()", "theGreetingView = NEW GreetingView()", "theStatusLine = NEW StatusLine()",
                               "theWindow = NEW MainWindowController()", "theWindow.Start(\"{{NAME}}\", StarterLanguages())",
                               "theWindow.Run()", "PRINT \"{{NAME}} closed.\"",
                               "IF theWindow.LastStatus <> \"\" THEN PRINT \"Last status: \" + theWindow.LastStatus"]),
                      ("game", ["ON GAMEPAD CALL GamepadChanged", "ON RESIZE CALL WindowResized", "RunGame()"]),
                      ("contacts", ["RunContactBook()"])])
    func otherMainsOnlyWire(starter: String, statements expected: [String]) throws {
        let main = try #require(try sources(starter)["main.bas"])
        let statements = main.split(separator: "\n").map(code).filter {
            !$0.isEmpty && !$0.hasPrefix("#!") && !["IMPORT ", "GLOBAL "].contains(where: $0.uppercased().hasPrefix)
        }
        #expect(statements == expected)
    }

    @Test("The TUI App's commands are in its toolbar and its menus, each through one handler")
    func tuiCommands() throws {
        let files = try sources("tui")
        let controller = try #require(files["controllers/MainWindowController.bas"])
        let menus = try #require(files["app/AppMenus.bas"])
        for (title, handler, method) in [("Greet", "GreetPressed", "Greet"), ("Quit", "QuitPressed", "Quit")] {
            #expect(controller.contains("bar.additem(\"\(title)\""), "\(title) is not in the toolbar")
            #expect(controller.contains("\"\(handler)\")"))
            #expect(menus.contains("bar.item(\"&\(title)\", \"\(handler)\")"), "\(title) is not in the menus")
            #expect(controller.contains("FUNCTION \(handler)() AS VOID\n    theWindow.\(method)()\nEND FUNCTION"))
        }
        // No row of buttons: the commands are the toolbar's.
        #expect(!files.values.contains { $0.contains("TUIButton(") })
        #expect(controller.contains("ME.Window.onclose(\"QuitPressed\")") && controller.contains("ME.Shell.onquit(\"QuitPressed\")"))
    }

    @Test("The Contact Book keeps its book in Application Support, or in APP_DATA_DIR")
    func contactsDataFolder() throws {
        let files = try sources("contacts")
        #expect(try #require(files["app/ContactApp.bas"]).contains("CurrentPath$ = DataFolder$(\"Contact Book\") + \"/contacts.json\""))
        #expect(try #require(files["app/DataFolder.bas"]).contains("ENVIRON$(\"APP_DATA_DIR\")"))
    }

    @Test("The checker finds what is missing")
    func documentationChecker() {
        let text = """
        /// Squares.
        ///
        /// - Parameter n: The number.
        FUNCTION Square(n AS DOUBLE) AS DOUBLE
        END FUNCTION

        FUNCTION Bare() AS VOID
        END FUNCTION
        /// Half.
        FUNCTION Half(a AS INTEGER, b AS INTEGER) AS VOID
        END FUNCTION
        TYPE T
            /// Kept.
            Kept AS STRING
            Loose AS STRING
        END TYPE
        """
        #expect(documentationProblems(in: text, file: "x") == [
            "x:4 FUNCTION Square(n AS DOUBLE) AS DOUBLE: what it returns is not documented",
            "x:7 FUNCTION Bare() AS VOID: no /// comment",
            "x:10 FUNCTION Half(a AS INTEGER, b AS INTEGER) AS VOID: parameter a is not documented",
            "x:10 FUNCTION Half(a AS INTEGER, b AS INTEGER) AS VOID: parameter b is not documented",
            "x:12 TYPE T: no /// comment",
            "x:15 Loose AS STRING: no /// comment",
        ])
    }

    /// Each ActiveUI starter's commands: the button, the handler it names,
    /// and the controller's method the handler hands it to.
    static let commands: [(String, [(button: String, handler: String, method: String)])] = [
        ("activeui.counter", [("Reset", "ResetPressed", "ResetCount")]),
        ("activeui", [("New Task", "NewTaskPressed", "NewTask"), ("Done", "DonePressed", "MarkDone"),
                      ("Delete", "DeletePressed", "DeleteTask"), ("Clear Done", "ClearDonePressed", "ClearDone")]),
        ("activeui.masterdetail", [("New Item", "NewItemPressed", "NewItem"), ("Favorite", "FavoritePressed", "ToggleFavorite"),
                                   ("Delete", "DeletePressed", "DeleteItem")]),
    ]

    @Test("The commands are in one place, across the top where the toolbar goes: each a button whose handler hands it to one method",
          arguments: commands)
    func commandsInOnePlace(starter: (String, [(button: String, handler: String, method: String)])) throws {
        let files = try sources(starter.0)
        let controllerPath = try #require(files.keys.first { $0.hasPrefix("controllers/") })
        let controller = try #require(files[controllerPath])
        let build = try #require(controller.range(of: "FUNCTION BuildCommands()"))
        let buildBody = controller[build.lowerBound...].prefix { _ in true }
            .components(separatedBy: "END FUNCTION").first ?? ""
        for command in starter.1 {
            #expect(buildBody.contains("AUIButton(\"\(command.button)\")"), "\(starter.0): \(command.button) is not made with the commands")
            #expect(buildBody.contains(".onclick(\"\(command.handler)\")"), "\(starter.0): \(command.button) does not name \(command.handler)")
            #expect(controller.contains("FUNCTION \(command.handler)() AS VOID\n    theWindow.\(command.method)()\nEND FUNCTION"),
                    "\(starter.0): \(command.handler) does not hand its command to \(command.method)")
            #expect(controller.contains("    FUNCTION \(command.method)() AS VOID"), "\(starter.0): no \(command.method) command")
        }
        // No row of buttons anywhere else: the counter's Click me is the app.
        for (path, text) in files where path != controllerPath {
            let buttons = text.components(separatedBy: "AUIButton(").count - 1
            let allowed = starter.0 == "activeui.counter" && path == "views/CounterView.bas" ? 1 : 0
            #expect(buttons == allowed, "\(starter.0)/\(path) makes \(buttons) buttons")
        }
        // Gray out what does not apply: RefreshCommands (or the counter's
        // Refresh) sets every command's enabled state.
        let refresh = try #require(controller.components(separatedBy: starter.0 == "activeui.counter" ? "FUNCTION Refresh()" : "FUNCTION RefreshCommands()").dropFirst().first)
        let refreshBody = refresh.components(separatedBy: "END FUNCTION").first ?? ""
        #expect(refreshBody.components(separatedBy: ".enabled(").count - 1 == starter.1.count, "\(starter.0): \(refreshBody)")
    }

    @Test("Each window is brought up to date once it is built, before it opens, so nothing opens enabled that should be grayed out",
          arguments: starters)
    func refreshedBeforeItOpens(starter: String) throws {
        let files = try sources(starter)
        let controller = try #require(files.first { $0.key.hasPrefix("controllers/") }?.value)
        let start = try #require(controller.components(separatedBy: "    FUNCTION Start(").dropFirst().first)
        let startBody = start.components(separatedBy: "END FUNCTION").first ?? ""
        let built = try #require(startBody.range(of: "ME.BuildCommands()"))
        let refreshed = try #require(startBody.range(of: "ME.Refresh()"), "\(starter): Start does not call Refresh")
        #expect(built.upperBound <= refreshed.lowerBound, "\(starter): Refresh comes before the commands are built")
        #expect(startBody.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("ME.Refresh()"),
                "\(starter): Refresh is the last thing Start does")
        if starter != "activeui.counter" {
            let refresh = try #require(controller.components(separatedBy: "    FUNCTION Refresh()").dropFirst().first)
            #expect((refresh.components(separatedBy: "END FUNCTION").first ?? "").contains("ME.RefreshCommands()"))
        }
    }

    @Test("Models know nothing of windows, and only the store reads and writes files", arguments: starters)
    func modelsArePlain(starter: String) throws {
        for (path, text) in try sources(starter) where path.hasPrefix("models/") {
            let lines = text.split(separator: "\n").map(code)
            #expect(!lines.contains { $0.contains("AUI") }, "\(starter)/\(path) uses ActiveUI")
            if !path.hasSuffix("Store.bas") {
                #expect(!lines.contains { $0.contains("File.") }, "\(starter)/\(path) touches files")
            }
        }
    }

    @Test("Data is kept in Application Support/<App>/, or in APP_DATA_DIR",
          arguments: [("activeui", "tasks.txt"), ("activeui.masterdetail", "items.txt")])
    func dataFolder(starter: String, file: String) throws {
        let files = try sources(starter)
        let folder = try #require(files["app/DataFolder.bas"])
        #expect(folder.contains("ENVIRON$(\"APP_DATA_DIR\")"))
        #expect(folder.contains("ENVIRON$(\"HOME\") + \"/Library/Application Support/\" + appName"))
        #expect(folder.contains("File.Mkdir"))
        let main = try #require(files["main.bas"])
        #expect(main.contains("DataFolder$(\"{{NAME}}\") + \"/\(file)\""))
    }
}
