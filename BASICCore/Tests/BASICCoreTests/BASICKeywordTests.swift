//
//  BASICKeywordTests.swift
//  BASICCoreTests
//
//  The tests that keep ``BASICKeywords`` current.
//
//  A vocabulary is only single-sourced for as long as nothing drifts away from
//  it, and "remember to update the keyword list" is not a mechanism. These are.
//

import Testing
@testable import BASICCore
@testable import BASICSyntax

@Suite("BASIC keyword vocabulary")
struct BASICKeywordTests {

    /// Every word the parser dispatches on is a word the vocabulary knows.
    ///
    /// This is the test that matters. Adding a statement to ``Parser``
    /// means adding it to `statementKeywords`, and that now fails here until
    /// the word reaches ``BASICKeywords`` — which is what makes it complete,
    /// highlight in the shell editor, and color in Studio. Before this, all
    /// four of those were separate acts of memory and three of them were
    /// routinely forgotten.
    @Test("the parser dispatches on nothing the vocabulary has not heard of")
    func parserKeywordsAreKnown() {
        let unknown = Parser.statementKeywords.subtracting(BASICKeywords.all)
        #expect(
            unknown.isEmpty,
            """
            \(unknown.sorted().joined(separator: ", ")) \
            \(unknown.count == 1 ? "is a statement keyword" : "are statement keywords") \
            the parser accepts but BASICKeywords does not list, so they will not \
            complete or highlight anywhere. Add them to the right category in \
            BASICKeywords.swift.
            """
        )
    }

    /// Every intrinsic function is in the vocabulary.
    ///
    /// True by construction today — `functions` *is* the interpreter's set —
    /// and this is here so that it stays true if anyone ever replaces the
    /// derivation with a copy.
    @Test("every intrinsic function is in the vocabulary")
    func intrinsicFunctionsAreKnown() {
        let missing = BASICInterpreter.intrinsicFunctionNames
            .subtracting(BASICKeywords.all)
        #expect(missing.isEmpty, "not in BASICKeywords: \(missing.sorted())")
    }

    /// Every name in `types` is one the parser accepts as a type.
    ///
    /// Proved by declaring a variable of it rather than by comparing two lists,
    /// because comparing two lists is how the type names drifted in the first
    /// place. `RECORD`, `CLASS` and `INTERFACE` take a name after them and
    /// `VOID` is a return type only, so each is given a declaration it should
    /// actually be valid in.
    @Test("every type name in the vocabulary parses")
    func typeNamesParse() {
        for name in BASICKeywords.types.sorted() {
            let source: String
            switch name {
            case "RECORD", "CLASS", "INTERFACE":
                source = "DIM X AS \(name) Thing"
            case "VOID":
                // A return type only — the parser rejects it anywhere else, by
                // name, which is itself worth not regressing.
                source = "FUNCTION F() AS VOID\nEND FUNCTION"
            case "TRUE", "FALSE":
                source = "LET X = \(name)"
            default:
                source = "DIM X AS \(name)"
            }
            let session = BASICSession(host: TestHost())
            session.program.loadSource(source)
            let diagnostics = session.diagnostics()
            let messages = diagnostics.map { $0.message }.joined(separator: "; ")
            #expect(
                diagnostics.isEmpty,
                "\(name) is listed as a type but did not parse in `\(source)`: \(messages)"
            )
        }
    }

    /// Every pseudo class the vocabulary lists is one the interpreter builds.
    ///
    /// Proved by constructing each, not by comparing lists — the same reason
    /// the type-name test declares a variable. A pseudo class is recognized by
    /// a string comparison inside `.newObject`, which no derivation from the
    /// parser can see, so this is the only thing standing between that switch
    /// and the vocabulary.
    ///
    /// The assertion is narrow on purpose: constructing a `VectorTerminal` on a
    /// host with no terminal may well fail, and that is not what is being
    /// tested. "Unknown CLASS" is — it is what the interpreter says when the
    /// name reached the bottom of the switch unrecognized.
    @Test("every pseudo class in the vocabulary can be constructed")
    func pseudoClassesAreConstructible() {
        for name in BASICKeywords.pseudoClasses.sorted() {
            let session = BASICSession(host: TestHost())
            session.program.loadSource("LET Handle = \(name)()")
            session.submit("RUN")
            // "array index must be numeric" belongs here too: a name the
            // constructor does not know is parsed as an array subscript, so a
            // missing registration reports a subscript complaint rather than an
            // unknown class. Checking only for "Unknown CLASS" let three
            // unregistered classes through.
            let complaints = (session.diagnostics().map { $0.message } + TestHost().output)
                .filter {
                    $0.contains("Unknown CLASS") || $0.contains("array index must be numeric")
                }
            #expect(
                complaints.isEmpty,
                "\(name) is listed as a pseudo class but the interpreter does not know it"
            )
        }
    }

    /// Every TUI pseudo class is registered where construction looks for it.
    ///
    /// The vocabulary and ``BASICInterpreter/tuiClassNames`` are separate
    /// lists, and a name in the first but not the second constructs as an array
    /// subscript. Compared directly, so the failure names the missing entry
    /// rather than leaving it to be inferred from a runtime message.
    @Test("every TUI pseudo class has a constructor entry")
    func tuiPseudoClassesAreRegistered() {
        let listed = BASICKeywords.pseudoClasses.filter { $0.hasPrefix("TUI") }
        for name in listed.sorted() {
            #expect(
                BASICInterpreter.tuiClassNames[name] != nil,
                "\(name) is in BASICKeywords.pseudoClasses but not in tuiClassNames"
            )
        }
        for name in BASICInterpreter.tuiClassNames.keys.sorted() {
            #expect(
                BASICKeywords.pseudoClasses.contains(name),
                "\(name) is in tuiClassNames but not in BASICKeywords.pseudoClasses"
            )
        }
    }

    /// Every listed pseudo-variable really is reserved.
    ///
    /// Proved by assigning to one and reading it back, not by comparing lists.
    /// `STATUS` and `ERRORLEVEL` intercept the *read*, so a program that says
    /// `GLOBAL status = 5` and prints it gets 0 — the assignment appears to
    /// work and the value never arrives. That is worth a regression test
    /// precisely because nothing about it looks wrong at the call site.
    @Test("assigning to a reserved pseudo-variable does not change what it reads")
    func pseudoVariablesAreReserved() {
        for name in ["STATUS", "ERRORLEVEL"] {
            let host = TestHost()
            let session = BASICSession(host: host)
            session.program.loadSource("GLOBAL \(name) = 5\nPRINT \(name)")
            session.submit("RUN")
            #expect(
                host.output != ["5"],
                "\(name) is listed as reserved but behaved like an ordinary variable"
            )
        }
    }

    /// Nothing the language does not implement is advertised.
    ///
    /// A regression guard with names on it. Each of these was in the old
    /// completion list, none of them parses, and each therefore offered the
    /// user a keyword that produces `Syntax error: Expected =` — the parser
    /// reading it as a variable, because that is all it is.
    ///
    /// `WHILE` and `WEND` used to be on this list and are not any more: they
    /// are implemented, in the interpreter and in the compiler both, and
    /// `while.bas` holds the two to the same output. `NOT`, `XOR`, `EQV` and
    /// `IMP` were never on it because they were never offered, which was its
    /// own kind of wrong — `logical.bas` covers all six operators now.
    @Test("unimplemented keywords are not advertised")
    func unimplementedKeywordsAreAbsent() {
        for word in ["DO", "LOOP", "UNTIL", "BREAK", "CONTINUE",
                     "CONST", "DECLARE"] {
            #expect(
                !BASICKeywords.isKeyword(word),
                "\(word) is advertised but the parser does not implement it"
            )
        }
    }

    /// Categories partition the vocabulary: every word has exactly one.
    @Test("every word has a category")
    func everyWordIsCategorised() {
        for word in BASICKeywords.all {
            #expect(BASICKeywords.category(of: word) != nil, "uncategorised: \(word)")
        }
    }

    /// Lookup ignores case, because BASIC does.
    @Test("lookup is case-insensitive")
    func lookupIgnoresCase() {
        #expect(BASICKeywords.category(of: "print") == .io)
        #expect(BASICKeywords.category(of: "Print") == .io)
        #expect(BASICKeywords.category(of: "mid$") == .function)
        #expect(BASICKeywords.category(of: "Sleep") == .function)
        #expect(BASICKeywords.category(of: "notakeyword") == nil)
    }
}
