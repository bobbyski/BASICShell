import Foundation

/// `basicc new` — starter projects.
///
/// The layout is the one FreebirdStudio's and OmegaCLIDE's BASIC generators
/// will produce (BASIC_COMPILER.md, Phase 7), so a project born at the
/// terminal and one born in a wizard are the same project:
///
/// ```text
///   MyApp/
///     Makefile          build · run · clean (BASICC ?= basicc)
///     .gitignore        Build/
///     README.md         where basicc comes from
///     src/main.bas      the program
/// ```
public enum ProjectScaffold {
    /// The starters `basicc new` knows.
    public enum Kind: String, CaseIterable, Sendable {
        /// One file that prints, loops, and reads input.
        case console
        /// A program with functions, arrays, and DATA — the shape a real
        /// program grows into.
        case structured
        /// A full-screen TUIKit application: a window, a menu bar, controls,
        /// and named handlers.
        case tui

        /// One line for `basicc new --help`.
        public var summary: String {
            switch self {
            case .console: return "one .bas file that prints, loops, and reads input"
            case .structured: return "functions, arrays, and DATA in one program"
            case .tui: return "a full-screen TUIKit application with a window, a menu, and controls"
            }
        }
    }

    /// Something about the request the scaffold cannot honor.
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Creates the project; returns its root directory.
    @discardableResult
    public static func generate(named rawName: String, into destination: String, kind: Kind) throws -> String {
        let allowed = rawName.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        let name = String(String.UnicodeScalarView(allowed))
        guard !name.isEmpty else { throw Failure(description: "'\(rawName)' is not a usable project name") }

        let fileManager = FileManager.default
        let root = (destination as NSString).appendingPathComponent(name)
        guard !fileManager.fileExists(atPath: root) else { throw Failure(description: "\(root) already exists") }
        let sources = (root as NSString).appendingPathComponent("src")
        try fileManager.createDirectory(atPath: sources, withIntermediateDirectories: true)

        func write(_ contents: String, to directory: String, _ file: String) throws {
            try contents.write(toFile: (directory as NSString).appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try write(makefile(name: name), to: root, "Makefile")
        try write("Build/\n", to: root, ".gitignore")
        try write(readme(name: name), to: root, "README.md")
        try write(program(kind: kind, name: name), to: sources, "main.bas")
        return root
    }

    /// The TUI starter.
    ///
    /// Two rules it follows on purpose, both of them ones a first TUI program
    /// gets wrong: every handler is a NAMED function, because a closure would
    /// run and discard whatever it assigned; and anything it wants to report
    /// is kept in a GLOBAL and printed after `run` returns, because while the
    /// application is up the screen belongs to it.
    static func tuiProgram(name: String) -> String {
        """
        ' \(name) — a full-screen TUIKit application.
        '
        ' Run it in a terminal: a window with a menu bar, a field, a list and
        ' buttons. Tab moves between controls, Enter presses one, and the File
        ' menu (Alt-F, then Q) closes the application.

        GLOBAL app = TUIApp()
        GLOBAL banner = TUILabel("Tab to move, Enter to press.")
        GLOBAL who = TUIField("your name")
        GLOBAL picks = TUIList()
        GLOBAL report$ = ""

        LET win = TUIWindow()

        ' `&` marks the mnemonic, here and everywhere in TUIKit.
        LET bar = TUIMenu()
        bar.menu("&File")
        bar.item("&Quit", "Quit")
        win.add(bar)

        LET page = TUIStack("v")
        page.add(banner)
        page.add(TUILabel("Type a name, then press Greet"))
        page.add(who)

        picks.additem("BASIC")
        picks.additem("Swift")
        picks.onselect("Picked")
        page.add(picks)

        LET row = TUIStack("h")
        LET greet = TUIButton("Greet")
        greet.onclick("Greet")
        LET done = TUIButton("Quit")
        done.onclick("Quit")
        row.add(greet)
        row.add(done)
        page.add(row)

        win.add(page)

        app.run(win)

        PRINT "\(name) closed."
        IF report$ <> "" THEN PRINT report$

        FUNCTION Greet()
          IF who.value$() = "" THEN
            banner.text("Type a name in the field first.")
          ELSE
            banner.text("Hello, " + who.value$() + "!")
          END IF
        END FUNCTION

        FUNCTION Picked()
          banner.text("Language: " + picks.selectedtext$())
        END FUNCTION

        FUNCTION Quit()
          report$ = "Last status: " + banner.value$()
          app.stop()
        END FUNCTION

        """
    }

    static func makefile(name: String) -> String {
        """
        # BASIC build. `basicc` comes from the BASICCompiler package in the
        # BASICShell repo (`swift build` there puts it in .build/debug/basicc),
        # or from its buildAndInstall.sh.
        BASICC ?= basicc
        BUILD := Build
        NAME := \(name)

        .PHONY: run build clean help

        ## run — build, then run it
        run: build
        \t$(BUILD)/$(NAME)

        ## build — compile src/main.bas to Build/$(NAME)
        build:
        \t@mkdir -p $(BUILD)
        \t$(BASICC) build src/main.bas -o $(BUILD)/$(NAME)

        ## clean — remove everything the build produced
        clean:
        \trm -rf $(BUILD)

        ## help — list these targets
        help:
        \t@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## //'

        """
    }

    static func readme(name: String) -> String {
        """
        # \(name)

        A BASIC program compiled by `basicc`.

        ```sh
        make        # build and run
        make build  # just build, into Build/\(name)
        ```

        The same source runs unchanged in the interpreter:

        ```sh
        BASICShell src/main.bas
        ```

        `basicc` builds from the BASICCompiler package in the BASICShell repo
        (`swift build --package-path Code/BASICCompiler`), or installs with
        that package's `buildAndInstall.sh`. Set `BASICC=/path/to/basicc` to
        point the Makefile at a build.

        """
    }

    static func program(kind: Kind, name: String) -> String {
        switch kind {
        case .tui:
            return tuiProgram(name: name)
        case .console:
            return """
            ' \(name) — a console program.
            '
            ' Everything here runs the same way under BASICShell and basicc:
            ' the interpreter is the reference, the compiler matches it.

            PRINT "Hello from \(name)!"
            INPUT "What is your name? "; Name$
            IF Name$ = "" THEN Name$ = "stranger"
            PRINT "Nice to meet you, "; Name$; "."

            FOR I = 1 TO 5
              PRINT I; " squared is "; I * I
            NEXT I

            """
        case .structured:
            return """
            ' \(name) — functions, arrays, and DATA.
            '
            ' A FUNCTION's parameters and LOCAL variables are its own; every
            ' other name is shared with the whole program.

            FUNCTION Average(Count AS INTEGER) AS DOUBLE
              LOCAL Total = 0
              FOR K = 1 TO Count
                Total = Total + Scores(K)
              NEXT K
              RETURN Total / Count
            END FUNCTION

            FUNCTION Grade$(Score AS DOUBLE) AS STRING
              SELECT CASE Score
                CASE IS >= 90: RETURN "A"
                CASE IS >= 80: RETURN "B"
                CASE IS >= 70: RETURN "C"
                CASE ELSE: RETURN "F"
              END SELECT
            END FUNCTION

            DATA "Ada", 96, "Grace", 88, "Linus", 72
            DIM Scores(3)
            FOR I = 1 TO 3
              READ Student$, Scores(I)
              PRINT Student$; TAB(12); Scores(I); TAB(20); Grade$(Scores(I))
            NEXT I
            PRINT "Average:"; Average(3)

            """
        }
    }
}
