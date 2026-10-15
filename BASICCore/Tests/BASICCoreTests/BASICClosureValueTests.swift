import Foundation
import Testing
@testable import BASICCore

/// Closures as values in the interpreter (Documents/CLOSURES.md, Phase 2):
/// in a VARIANT and called through it, in a field and called as
/// `obj.Field(args)`, compared by identity, made with `AddressOf`, printed.
@Suite("Closure values")
struct BASICClosureValueTests {
    private func run(_ source: String) -> [String] {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource(source)
        session.submit("RUN")
        return host.output
    }

    /// `BASICCompiler/Tests/Programs/closure-values.bas`, which a `basicc`
    /// binary must print the same.
    @Test("the values conformance program prints what basicc prints")
    func conformanceProgram() {
        #expect(run("""
            ' Closures as values (Documents/CLOSURES.md, Phase 2): held in a VARIANT
            ' and called through it, held in a field and called as obj.Field(args),
            ' compared by identity, made from a FUNCTION with AddressOf, and printed.
            FUNCTION TYPE Unary(x AS INTEGER) AS INTEGER
            FUNCTION TYPE Twin(x AS INTEGER) AS INTEGER
            FUNCTION TYPE DUnary(x AS DOUBLE) AS INTEGER
            FUNCTION TYPE Shout(s AS STRING) AS VOID
            TYPE Holder
              F AS Unary
            END TYPE
            CLASS Button
              PUBLIC OnPress AS Unary
            END CLASS
            FUNCTION Square(n AS INTEGER) AS INTEGER
              RETURN n * n
            END FUNCTION
            FUNCTION Say(s AS STRING) AS VOID
              PRINT "SAY "; s
            END FUNCTION

            ON ERROR GOTO Trapped

            ' In a VARIANT, and called through it.
            DIM v AS VARIANT
            v = FUNCTION(x AS INTEGER) AS INTEGER = x * 3
            PRINT "VARIANT"; v(4)

            ' Unboxed into a function type of its shape, and refused by another.
            DIM u AS Unary
            u = v
            PRINT "UNBOXED"; u(5)
            DIM d AS DUnary
            d = v
            PRINT "AFTER DUNARY"

            ' In a record's field and a class's, called as one.
            DIM h AS Holder
            h.F = u
            PRINT "FIELD"; h.F(6)
            DIM b AS Button
            b = NEW Button()
            b.OnPress = u
            PRINT "PRESS"; b.OnPress(7)

            ' Equal when the same closure, whatever the type is called.
            DIM t AS Twin
            t = u
            PRINT "SAME"; t = u; t <> u; u = u; u <> u
            w = FUNCTION(x AS INTEGER) AS INTEGER = x * 3
            PRINT "OTHER"; w = u; w <> u

            ' A VARIANT holding a number cannot be called.
            n = 5
            DIM nv AS VARIANT
            nv = n
            PRINT "CALL"; nv(1)

            ' AddressOf a FUNCTION, and of a VOID one.
            DIM sq AS Unary
            sq = AddressOf Square
            PRINT "ADDRESSOF"; sq(9)
            DIM shout AS Shout
            shout = AddressOf Say
            shout("HI")

            ' A closure written in a class keeps the class's access (C13).
            FUNCTION TYPE Peek() AS INTEGER
            CLASS Vault
              PRIVATE Secret AS INTEGER
              FUNCTION Open(n AS INTEGER) AS VOID
                ME.Secret = n
              END FUNCTION
              FUNCTION Peeker() AS Peek
                RETURN FUNCTION() AS INTEGER = ME.Secret
              END FUNCTION
            END CLASS
            DIM vault AS Vault
            vault = NEW Vault()
            vault.Open(42)
            peek = vault.Peeker()
            PRINT "PRIVATE"; peek()

            ' What each prints.
            PRINT u
            PRINT sq
            END

            Trapped:
              PRINT "TRAPPED"; ERR
              RESUME NEXT
            """) == ["VARIANT12", "UNBOXED15", "TRAPPED13", "AFTER DUNARY", "FIELD18", "PRESS21", "SAME1010", "OTHER01", "TRAPPED13", "ADDRESSOF81", "SAY HI", "PRIVATE42", "<FUNCTION [anonymous closure]>", "<FUNCTION Square>"])
    }

    @Test("AddressOf a name that is no FUNCTION says so")
    func addressOfUnknown() {
        #expect(run("f = AddressOf Nowhere").joined().contains("there is no FUNCTION Nowhere"))
    }
}
