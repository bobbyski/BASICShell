import BASICLint
@testable import BASICLintCodeWatch
import CodeWatchLint
import Foundation
import Testing

// BASIC in CodeWatch: the front end, and CodeWatch's own rules running on a
// BASIC file through it. This is the cross-language fixture Architecture.md
// §5 asks for — the same program shape, linted by the engine that lints
// Pascal, Java, Kotlin and C#.

@Suite("BASIC through CodeWatchLint")
struct CodeWatchFrontEndTests {
    /// A program with a routine, branches, a loop, and a GOTO.
    static let program = """
    ' A gallery of shapes the front end has to map.
    IMPORT "helper.bas"

    TYPE Point
        x AS INTEGER
        y AS INTEGER
    END TYPE

    FUNCTION Classify(n AS INTEGER) AS STRING
        IF n < 0 THEN
            RETURN "negative"
        ELSE
            IF n = 0 THEN
                RETURN "zero"
            END IF
        END IF
        RETURN "positive"
    END FUNCTION

    DIM total AS INTEGER
    total = 0
    FOR index = 1 TO 10
        total = total + index
    NEXT index
    PRINT Classify(total)
    Again:
        GOTO Again
    """

    private func parse() throws -> CodeWatchLint.LintTree {
        try BASICFrontEnd().parse(source: Self.program, path: "gallery.bas")
    }

    @Test func theLanguageIsRegisteredAndFindsItsFiles() {
        #expect(LintLanguage.language(forPath: "a/b/program.BAS") == .basic)
        #expect(LintLanguage.basic.fileExtensions == ["bas"])
        // BASIC folds case, as Pascal does: `Total` and `total` are one name.
        #expect(LintLanguage.basic.isCaseSensitive == false)
    }

    @Test func theTreeCarriesWhatCodeWatchsRulesLookFor() throws {
        let tree = try parse()
        let kinds = Set(tree.root.descendants.map(\.kind))
        for expected in [LintNodeKind.routineDeclaration, .typeDeclaration, .branch, .loop, .gotoStatement, .importDeclaration, .assignment] {
            #expect(kinds.contains(expected), Comment(rawValue: "no \(expected) node"))
        }
    }

    @Test func nodesAreInTheRightPlaceInTheFile() throws {
        let tree = try parse()
        let routine = tree.root.descendants.first { $0.kind == .routineDeclaration }
        #expect(routine != nil)
        // The routine begins where FUNCTION is written and spans its body.
        #expect(routine?.range.start.line == 9)
        #expect((routine?.range.end.line ?? 0) > 9)
    }

    @Test func codeWatchsOwnRulesRunOnIt() throws {
        let tree = try parse()
        let rules = RuleCatalog.rules(for: .basic)
        #expect(!rules.isEmpty, "no CodeWatch rule claims to support BASIC")
        // The engine walks it without complaint, which is the point: a
        // language is a mapping, not a second linter.
        let findings = LintEngine(rules: rules).run(tree)
        #expect(findings.allSatisfy { $0.path == "gallery.bas" })
    }
}

extension CodeWatchFrontEndTests {
    /// A routine with more branches than the threshold allows, so a shared
    /// rule has something to find.
    static var tangled: String {
        var lines = ["FUNCTION Tangled(n AS INTEGER) AS INTEGER"]
        for value in 0..<14 {
            lines += ["    IF n = \(value) THEN", "        RETURN \(value)", "    END IF"]
        }
        lines += ["    RETURN 0", "END FUNCTION", "PRINT Tangled(1)"]
        return lines.joined(separator: "\n") + "\n"
    }

    @Test func aSharedComplexityRuleActuallyFires() throws {
        let tree = try BASICFrontEnd().parse(source: Self.tangled, path: "tangled.bas")
        let findings = LintEngine(rules: RuleCatalog.rules(for: .basic)).run(tree)
        #expect(
            findings.contains { $0.ruleID == "complexity.cyclomatic" },
            Comment(rawValue: "CodeWatch's own complexity rule found nothing: \(findings.map(\.ruleID))")
        )
    }
}
