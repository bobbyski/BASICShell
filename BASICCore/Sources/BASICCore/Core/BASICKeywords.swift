//
//  BASICKeywords.swift
//  BASICCore
//
//  The language's vocabulary, in one place.
//
//  ## Why this exists
//
//  There were four lists, and no two of them agreed:
//
//  | Where                                | Words | Used for                  |
//  |--------------------------------------|-------|---------------------------|
//  | `BASICCompletionEngine`              |    57 | tab-completion            |
//  | `BASICProgram.listingKeywords`       |    58 | `LIST` colouring          |
//  | `BASICParser.statementKeywords`      |    87 | parser dispatch           |
//  | `MonacoEditor.swift` (BASICStudio)   |   153 | the Studio editor         |
//
//  The consequences were not academic. The shell's editor rendered `CLS`,
//  `OPEN`, `LOCATE`, `PSET` and every builtin as plain text while Studio
//  coloured them; Studio knew nothing of `ASYNC`, `AWAIT`, `TASK` or
//  `HTTPGETASYNC`, so the async features had no highlighting there at all. And
//  completion offered `WHILE`, `WEND`, `DO`, `LOOP`, `BREAK`, `CONTINUE`,
//  `CONST` and `DECLARE` — none of which this language implements. Tab-complete
//  `WHILE` and the parser reads it as a variable and asks for an `=`.
//
//  Every consumer now reads from here.
//
//  ## Where the contents come from
//
//  Not from a fifth hand-written list. Each category was derived from what the
//  implementation actually accepts:
//
//  - `functions` **is** ``BASICInterpreter/intrinsicFunctionNames``, not a copy
//    of it. A builtin added to the interpreter is highlighted and completed the
//    same day, by nobody.
//  - The statement categories were taken from every `matchIdentifier("…")` in
//    ``BASICParser`` — the words the parser genuinely dispatches on — and
//    `BASICKeywordTests` fails if the parser learns one that never arrived here.
//  - `types` were taken from the parser's type-name switch, and every one of
//    them is proved parseable by a test rather than trusted.
//
//  Words the language does *not* implement are deliberately absent. Advertising
//  a keyword nobody wrote is worse than not advertising it: completion offers
//  it, an editor colours it, and the program still does not run.
public enum BASICKeywords {

    /// What a word is, which is what a highlighter needs in order to colour it.
    ///
    /// Semantic rather than visual: Studio gives each its own colour, the
    /// terminal editor currently folds several together, and neither choice
    /// belongs in this file.
    public enum Category: Sendable, Hashable, CaseIterable {
        /// Flow of control: `IF`, `FOR`, `GOTO`, `AWAIT`.
        case control
        /// Names and shapes: `DIM`, `FUNCTION`, `CLASS`, `PUBLIC`.
        case declaration
        /// Console, files, and the shell: `PRINT`, `OPEN`, `PUSHD`.
        case io
        /// Drawing: `PSET`, `CIRCLE`, `PAINT`.
        case graphics
        /// Type names and literals: `INTEGER`, `STRING`, `TRUE`.
        case type
        /// Words that are keywords only in a modifier or `OPTION` position —
        /// `OPTION SHELLMODE`, `EXIT ERRORS ONLY`. Reserved in context and
        /// nowhere else, which is why they are not lumped in with the rest.
        case option
        /// Intrinsic functions: `LEN`, `MID$`, `SLEEP`, `HTTPGETASYNC`.
        case function
    }

    /// Flow of control.
    public static let control: Set<String> = [
        "AND", "ASYNC", "AWAIT", "BACKGROUND", "CALL", "CANCEL", "CASE", "ELSE",
        "ELSEIF", "END", "ERROR", "EXIT", "FOR", "GOSUB", "GOTO", "IF", "IS",
        "JOIN", "NEXT", "ON", "OR", "PAUSE", "REM", "RESUME", "RETURN", "SELECT",
        "STEP", "STOP", "THEN", "TO", "YIELD",
    ]

    /// Names and shapes.
    public static let declaration: Set<String> = [
        "AS", "CLASS", "DATA", "DEF", "DEFAULT", "DIM", "FIELD", "FUNCTION",
        "GLOBAL", "IMPLEMENTS", "IMPORT", "INHERITS", "INTERFACE", "LABEL",
        "LET", "LOCAL", "ME", "META", "MODULE", "MUTABLE", "NAME", "NEW", "OPTION",
        "OVERRIDES", "PRIVATE", "PROTECTED", "PUBLIC", "READ", "READONLY",
        "RECORD", "RESTORE", "STRONG", "SUB", "TYPE", "VIRTUAL", "WEAK",
    ]

    /// Console, files, and the shell.
    public static let io: Set<String> = [
        "CD", "CLOSE", "DIRS", "EXEC", "EXPORT", "FILES", "GET", "INPUT",
        "INPUT#", "LINE", "LOAD", "LOG", "LSET", "OPEN", "PIPE", "POPD",
        "PRINT", "PRINT#", "PUSHD", "PUT", "PWD", "RANDOMIZE", "RESET", "RSET",
        "SAVE", "SETENV", "SHELL", "SYSTEM", "UNSETENV", "WHICH", "WRITE",
        "WRITE#",
    ]

    /// Drawing.
    public static let graphics: Set<String> = [
        "CIRCLE", "CLS", "COLOR", "DRAW", "LOCATE", "PAINT", "PRESET", "PSET",
        "SCREEN",
    ]

    /// Type names and literals.
    ///
    /// Kept in step with the parser's type-name switch by a test that declares
    /// a variable of each — a list that merely claims to match the parser is
    /// the thing this file exists to abolish.
    public static let types: Set<String> = [
        "BOOLEAN", "CLASS", "DICTIONARY", "DOUBLE", "FALSE", "FILE", "INTEGER",
        "INTERFACE", "JSON", "RECORD", "SINGLE", "STRING", "TASK", "TRUE",
        "VARIANT", "VOID",
    ]

    /// The host-backed classes — the "pseudo classes" a program constructs with
    /// `NEW`, or by calling the name, and then sends messages to:
    ///
    /// ```basic
    /// let vtg = VectorTerminal()
    /// vtg.rect("panel", 32, 48, 520, 260, "#22c55e", "#07111dcc", 2, 16, 1)
    /// ```
    ///
    /// They are not user classes and never appear in `CLASS` definitions: the
    /// interpreter recognises the name in `.newObject` and hands back a
    /// `systemObject` the host implements.
    ///
    /// They were missing from this file until the vocabulary was audited for
    /// TUIKIT_PLAN.md. That is instructive: the categories above were derived
    /// from the parser's `matchIdentifier` calls, and a pseudo class is matched
    /// by a string comparison in the `.newObject` switch instead — so a purely
    /// mechanical derivation could not see them, and neither could the drift
    /// test. `BASICKeywordTests` now constructs each of these to prove the
    /// interpreter still answers to it.
    public static let pseudoClasses: Set<String> = [
        "FILE", "HTTPCLIENT", "RICHMARKDOWN", "RICHPANEL", "RICHTABLE",
        "RICHPROGRESS", "RICHSYNTAX", "RICHTEXT", "SECONDSTIMER",
        "TUIAPP", "TUIBUTTON", "TUICHECK", "TUIDIALOG", "TUIFIELD", "TUIGAUGE",
        "TUILABEL", "TUILIST", "TUIMENU", "TUISTACK", "TUITABLE", "TUITEXT",
        "TUIWINDOW", "TUIFLOATWINDOW", "TUITOOLBAR", "TUITABS", "TUIPANEL",
        "TUISTATUS", "TUIDIVIDER", "TUISIDEBAR", "TUITOGGLE", "TUIRADIO",
        "TUISEGMENTS", "TUICOMBO", "TUIPOPUP", "TUISLIDER", "TUISTEPPER",
        "TUILEVEL", "TUIPROGRESS", "TUIDATE", "TUICOLOR", "TUIMATRIX",
        "TUISEARCH", "TUIPASTE", "TUITOKENS", "TUICOMPLETIONS", "TUIRANGE",
        "TUITREE", "TUIDIRTREE", "TUIBROWSER", "TUIPATH", "TUIFAVORITES",
        "TUIMASTERDETAIL", "TUICOLLECTION", "TUISYNTAX", "TUIMARKDOWN",
        "TUIRICH",
        "VECTORTERMINAL", "VTG",
    ]

    /// Names the language answers to itself, whatever a program assigns.
    ///
    /// `STATUS` and `ERRORLEVEL` read back the last command's exit status;
    /// `CURRENT_TASK$` and friends report execution context. They are not
    /// keywords in any grammatical sense — a program may write
    /// `GLOBAL status = 5` and it will appear to work — but the *read* is
    /// intercepted, so it prints 0.
    ///
    /// That silent shadowing is the least obvious trap in the language, and it
    /// was found by a demo picking `status` as a variable name. Listing them
    /// here does not fix it; it makes them highlight and complete, so they at
    /// least look reserved before someone chooses one.
    public static let pseudoVariables: Set<String> = [
        "CURRENT_FUNCTION$", "CURRENT_TASK$", "CURRENT_THREAD$", "ERRORLEVEL",
        "STATUS",
    ]

    /// Words reserved only in a modifier or `OPTION` position.
    public static let options: Set<String> = [
        "AIBASIC", "AUTO", "CAPTURES", "ERR", "ERRORS", "EXCLUDE", "EXITVAR",
        "GAMEPAD", "IBM", "KEYS", "LENGTH", "MAX", "MODE", "MOUSE", "OFF",
        "ONLY", "SEEK", "SHELLMODE", "STRINGSUB", "TIMEOUT", "TROFF", "TRON",
        "TTY", "USING",
    ]

    /// Intrinsic functions.
    ///
    /// Derived, never transcribed. `LEN` is added because the parser gives it
    /// its own production rather than routing it through the intrinsic table —
    /// the one builtin that is not in the interpreter's list, and exactly the
    /// kind of thing a hand-maintained copy would have lost.
    public static let functions: Set<String> =
        BASICInterpreter.intrinsicFunctionNames.union(["LEN"])

    /// Every word in the language.
    public static let all: Set<String> =
        control.union(declaration).union(io).union(graphics)
            .union(types).union(pseudoClasses).union(pseudoVariables)
            .union(options).union(functions)

    /// Every word, ordered — for completion menus and anything else that shows
    /// them to a person.
    public static let sortedWords: [String] = all.sorted()

    /// What `word` is, or `nil` if the language has never heard of it.
    ///
    /// Case-insensitive, because BASIC is: `print`, `Print`, and `PRINT` are
    /// one keyword and every consumer of this would otherwise have to remember
    /// to uppercase first.
    public static func category(of word: String) -> Category? {
        categories[word.uppercased()]
    }

    /// Whether `word` is a keyword of any kind.
    public static func isKeyword(_ word: String) -> Bool {
        categories[word.uppercased()] != nil
    }

    // Built once. A word in more than one category — `CLASS` declares and also
    // names a type, `SEEK` is both a function and an OPTION word — takes the
    // first that claims it, in the order below. Highlighting has to pick one
    // colour, and the declaration reading is the one a reader meets first.
    private static let categories: [String: Category] = {
        var table: [String: Category] = [:]
        for (words, category) in [
            (control, Category.control),
            (declaration, .declaration),
            (io, .io),
            (graphics, .graphics),
            (types, .type),
            (pseudoClasses, .type),
            (pseudoVariables, .function),
            (options, .option),
            (functions, .function),
        ] {
            for word in words where table[word] == nil {
                table[word] = category
            }
        }
        return table
    }()
}
