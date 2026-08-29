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

@Suite("BASIC keyword vocabulary")
struct BASICKeywordTests {

    /// Every word the parser dispatches on is a word the vocabulary knows.
    ///
    /// This is the test that matters. Adding a statement to ``Parser``
    /// means adding it to `statementKeywords`, and that now fails here until
    /// the word reaches ``BASICKeywords`` — which is what makes it complete,
    /// highlight in the shell editor, and colour in Studio. Before this, all
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

    /// Nothing the language does not implement is advertised.
    ///
    /// A regression guard with names on it. Each of these was in the old
    /// completion list, none of them parses, and each therefore offered the
    /// user a keyword that produces `Syntax error: Expected =` — the parser
    /// reading it as a variable, because that is all it is.
    @Test("unimplemented keywords are not advertised")
    func unimplementedKeywordsAreAbsent() {
        for word in ["WHILE", "WEND", "DO", "LOOP", "UNTIL", "BREAK", "CONTINUE",
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
