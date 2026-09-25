import Foundation
import Testing
@testable import BASICCore

/// `DATE`, `TIME`, `DATETIME` and `DECIMAL` (DB19, D0.7).
///
/// The reason these are four types rather than a `DOUBLE` and a `STRING` is
/// exactness, so that is what most of these check — and the reason the `#`
/// literal needed care is that `#` has marked a file number since the 1970s,
/// so that is what the rest check.
@Suite("BASICTemporalTypes")
struct BASICTemporalTypeTests {

    private func run(_ source: String) throws -> String {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource(source, fileName: "test.bas")
        try session.runProgram()
        return host.output.joined(separator: "")
    }

    // MARK: - Literals

    @Test("The shape between the hashes decides which of the three it is")
    func literalsReadByShape() throws {
        #expect(try run("PRINT #2026-09-25#") == "2026-09-25")
        #expect(try run("PRINT #14:30:00#") == "14:30:00")
        #expect(try run("PRINT #2026-09-25 14:30:00#") == "2026-09-25T14:30:00")
        // A machine writes the `T`; a person writes the space. Same instant.
        #expect(try run("PRINT #2026-09-25T14:30:00#") == "2026-09-25T14:30:00")
        #expect(try run("PRINT #14:30#") == "14:30:00")
    }

    @Test("A # that is not a literal is still a file number")
    func hashStillMarksAFile() throws {
        // The whole risk of the spelling: `#` has meant a file number since the
        // 1970s, and every program that uses one must keep working.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("db19-\(UUID().uuidString).txt").path
        let output = try run("""
        OPEN "\(path)" FOR OUTPUT AS #1
        PRINT #1, "still a file"
        CLOSE #1
        OPEN "\(path)" FOR INPUT AS #1
        LINE INPUT #1, L$
        CLOSE #1
        PRINT L$
        """)
        #expect(output == "still a file")
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("Something between hashes that is not a date is not a literal")
    func nonLiteralsAreLeftAlone() throws {
        // Checked by *parsing* rather than by pattern, so the lexer and the
        // evaluator cannot disagree about what a literal is.
        #expect(BASICTemporalLiteral.isLiteral("2026-09-25"))
        #expect(BASICTemporalLiteral.isLiteral("14:30"))
        #expect(!BASICTemporalLiteral.isLiteral("2026-13-01"), "there is no month 13")
        #expect(!BASICTemporalLiteral.isLiteral("25:00:00"), "there is no hour 25")
        #expect(!BASICTemporalLiteral.isLiteral("1"))
        #expect(!BASICTemporalLiteral.isLiteral(""))
    }

    @Test("A bare number is still a DOUBLE; only the D suffix is exact")
    func theSuffixIsWhatChooses() throws {
        #expect(try run("PRINT 0.1 + 0.2") == "0.30000000000000004")
        #expect(try run("PRINT 0.1D + 0.2D") == "0.3")
        // Every existing program means DOUBLE by `1.5`, and still does.
        #expect(try run("PRINT 1.5") == "1.5")
    }

    // MARK: - Exactness

    @Test("DECIMAL arithmetic is exact, which is the entire point")
    func decimalArithmeticIsExact() throws {
        #expect(try run("PRINT 19.99D * 3D") == "59.97")
        #expect(try run("PRINT 1D / 8D") == "0.125")
        // Money, the case the type exists for: a hundred pennies is a pound.
        #expect(try run("""
        DIM TOTAL AS DECIMAL
        TOTAL = 0D
        FOR I = 1 TO 100
            TOTAL = TOTAL + 0.01D
        NEXT
        PRINT TOTAL
        """) == "1")
        // The same loop in DOUBLE is what this replaces.
        #expect(try run("""
        T = 0
        FOR I = 1 TO 100
            T = T + 0.01
        NEXT
        PRINT T = 1
        """) == "0")
    }

    @Test("A fractional DOUBLE will not silently become a DECIMAL")
    func noSilentLossThroughDouble() throws {
        // `Decimal(0.1)` is not one tenth. Refusing by name is the only honest
        // answer: the exactness was gone before the conversion was asked for.
        #expect(throws: BASICError.self) { try run("PRINT CDEC(0.1)") }
        // A whole number is exact either way, so it converts.
        #expect(try run("PRINT CDEC(42)") == "42")
        #expect(try run("PRINT CDEC(\"0.1\") + CDEC(\"0.2\")") == "0.3")
    }

    // MARK: - Comparison

    @Test("Comparison is by component, not by text")
    func comparisonIsExact() throws {
        // `.5` and `.500` are the same instant and print differently, so a
        // text comparison would call them different.
        #expect(try run("PRINT #14:30:00.5# = #14:30:00.500#") == "1")
        #expect(try run("PRINT #2026-09-26# > #2026-09-25#") == "1")
        #expect(try run("PRINT #2026-09-25 09:00:00# < #2026-09-25 17:00:00#") == "1")
    }

    @Test("Two different kinds have no order, and say so")
    func differentKindsDoNotCompare() {
        // Inventing an order -- midnight, say -- would have this answer
        // something rather than say it is not a question.
        #expect(throws: BASICError.self) { try run("PRINT #2026-09-25# < #14:30:00#") }
    }

    @Test("Arithmetic on a date needs a unit, so it is refused rather than guessed")
    func dateArithmeticIsRefused() {
        // `date + 1` meaning a day in one place and a second in another is how
        // a language ends up with two answers.
        #expect(throws: BASICError.self) { try run("PRINT #2026-09-25# + 1") }
    }

    // MARK: - Conversions and assignment

    @Test("Text converts, because that is how these arrive")
    func textConverts() throws {
        #expect(try run("PRINT CDATE(\"2026-01-02\")") == "2026-01-02")
        #expect(try run("PRINT CTIME(\"09:05\")") == "09:05:00")
        #expect(try run("PRINT CDATETIME(\"2026-01-02 09:05:00\")") == "2026-01-02T09:05:00")
        // A DATETIME has both halves, so either can be taken from it.
        #expect(try run("PRINT CDATE(#2026-01-02 09:05:00#)") == "2026-01-02")
        #expect(try run("PRINT CTIME(#2026-01-02 09:05:00#)") == "09:05:00")
    }

    @Test("A declared variable holds its own type, and refuses what is not one")
    func declaredTypesHold() throws {
        #expect(try run("""
        DIM D AS DATE
        D = "2026-03-04"
        PRINT D
        """) == "2026-03-04", "text assigns, as it does from a file or an INPUT")
        #expect(throws: BASICError.self) {
            try run("""
            DIM D AS DATE
            D = "not a date"
            PRINT D
            """)
        }
        #expect(throws: BASICError.self) {
            try run("""
            DIM M AS DECIMAL
            M = "not a number"
            PRINT M
            """)
        }
    }

    // MARK: - The database side

    @Test("The four types map to the columns the provider boundary already had")
    func theyMapToColumns() throws {
        let session = BASICSession(host: TestHost())
        session.program.loadSource("""
        class Invoice
            public Id as integer database key
            public Raised as date database
            public DueAt as datetime database
            public At as time database
            public Total as decimal database
        end class
        print "ok"
        """, fileName: "test.bas")
        try session.runProgram()
        let definition = try #require(session.declaredClasses["INVOICE"])
        let mapping = try BASICObjectMapper.map(definition)
        #expect(mapping.column(forField: "Raised")?.columnType == .date)
        #expect(mapping.column(forField: "DueAt")?.columnType == .timestamp)
        #expect(mapping.column(forField: "At")?.columnType == .time)
        // DB19 settled 28 significant digits, VB's Decimal and what SQL expects.
        #expect(mapping.column(forField: "Total")?.columnType
                == .decimal(precision: BASICDecimal.significantDigits, scale: 6))
    }
}
