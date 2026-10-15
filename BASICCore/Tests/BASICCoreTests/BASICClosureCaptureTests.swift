import Foundation
import Testing
@testable import BASICCore

/// What a closure does with the variables it captures, in the interpreter
/// (Documents/CLOSURES.md, Bobby's rulings C1–C6, 2026-10-15): it shares
/// them, as VB does, unless its `CAPTURES` list asks for a `STRONG` copy it
/// may change or a `READONLY` one it may not.
@Suite("Closure captures")
struct BASICClosureCaptureTests {
    private func run(_ source: String) -> [String] {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource(source)
        session.submit("RUN")
        return host.output
    }

    @Test("a closure shares a function's local after the function returns: each counter counts on its own")
    func counterFactory() {
        let output = run("""
        function type Counter() as integer
        function MakeCounter() as Counter
          local count as integer = 0
          local tick as Counter
          tick = function() as integer
            count = count + 1
            return count
          end function
          return tick
        end function
        c = MakeCounter()
        d = MakeCounter()
        print str$(c()) + str$(c()) + str$(c()) + str$(d())
        """)
        #expect(output == [" 1 2 3 1"])
    }

    @Test("a closure's write reaches the variable, and it sees later changes")
    func sharedByDefault() {
        let output = run("""
        total = 0
        add = function(n as integer) as integer
          total = total + n
          return total
        end function
        x = add(5)
        x = add(7)
        print total
        total = 100
        print add(1)
        """)
        #expect(output == ["12", "101"])
    }

    @Test("the shared variable is the one where the closure was made, not a caller's local of the same name")
    func sharedLexically() {
        let output = run("""
        total = 0
        add = function(n as integer) as integer
          total = total + n
          return total
        end function
        function Caller() as integer
          local total = 100
          return add(1)
        end function
        print Caller()
        print total
        """)
        #expect(output == ["1", "1"])
    }

    @Test("CAPTURES MUTABLE spells out the shared variable")
    func mutableIsShared() {
        let output = run("""
        n = 10
        bump = function() as integer captures mutable n
          n = n + 1
          return n
        end function
        x = bump()
        print n
        """)
        #expect(output == ["11"])
    }

    @Test("CAPTURES STRONG is the closure's own copy: its changes persist between calls and never reach the variable")
    func strongIsAChangeableCopy() {
        let output = run("""
        n = 10
        bump = function() as integer captures strong n
          n = n + 1
          return n
        end function
        print bump()
        print bump()
        n = 50
        print bump()
        print n
        """)
        #expect(output == ["11", "12", "13", "50"])
    }

    @Test("CAPTURES READONLY is frozen, and assigning it is a runtime error ON ERROR traps")
    func readOnlyIsAnError() {
        let stopped = run("""
        p$ = "A"
        f = function() as string captures readonly p$
          p$ = "B"
          return p$
        end function
        x$ = f()
        """)
        #expect(stopped.joined(separator: "\n").contains("p$ is captured READONLY"))

        let trapped = run("""
        on error goto Handler
        p$ = "A"
        f = function() as string captures read-only p$
          p$ = "B"
          return p$
        end function
        x$ = f()
        print "after "; p$
        end
        Handler:
          print "trapped"
          resume next
        """)
        #expect(trapped == ["trapped", "after A"])
    }

    @Test("a LOCAL declared on each pass of a loop is a new variable, so each closure keeps its own")
    func localInALoopIsFresh() {
        let output = run("""
        function type Getter() as integer
        dim g(3) as Getter
        for i = 1 to 3
          local v as integer = i * 10
          g(i) = function() as integer = v
        next i
        h = g(1)
        k = g(3)
        print str$(h()) + str$(k())
        """)
        #expect(output == [" 10 30"])
    }

    @Test("ME is the closure's own copy: changes persist in the closure and never reach the object (C6)")
    func meIsACopy() {
        let output = run("""
        function type Bump() as integer
        class Box
          public N as integer
          function Bumper() as Bump
            local b as Bump
            b = function() as integer
              ME.N = ME.N + 1
              return ME.N
            end function
            return b
          end function
        end class
        dim x as Box
        x = new Box()
        x.N = 5
        f = x.Bumper()
        print f()
        print f()
        print x.N
        """)
        #expect(output == ["6", "7", "5"])
    }

    @Test("a closure that shares an array sees and makes element changes")
    func sharedArray() {
        let output = run("""
        dim a(3) as integer
        setter = function(i as integer, v as integer) as integer
          a(i) = v
          return a(i)
        end function
        x = setter(2, 42)
        a(1) = 7
        reader = function() as integer = a(1) + a(2)
        print a(2)
        print reader()
        """)
        #expect(output == ["42", "49"])
    }

    /// `BASICCompiler/Tests/Programs/closure-capture.bas`, which a `basicc`
    /// binary must print the same (CLOSURES.md 1.14).
    @Test("the capture conformance program prints what basicc prints")
    func conformanceProgram() {
        let output = run("""
        ' Closure captures (Documents/CLOSURES.md, rulings C1-C6): a closure shares
        ' the variables it uses, as VB's do; CAPTURES STRONG is its own copy, which
        ' it may change; CAPTURES READONLY is a frozen copy it may not.
        FUNCTION TYPE Counter() AS INTEGER
        FUNCTION TYPE Getter() AS INTEGER

        ' A function's local, shared after the function returns: each counter counts.
        FUNCTION MakeCounter() AS Counter
          LOCAL count AS INTEGER = 0
          LOCAL tick AS Counter
          tick = FUNCTION() AS INTEGER
            count = count + 1
            RETURN count
          END FUNCTION
          RETURN tick
        END FUNCTION
        c = MakeCounter()
        d = MakeCounter()
        PRINT "COUNTERS"; c(); c(); c(); d()

        ' A write reaches the variable, and a later change is seen.
        total = 0
        add = FUNCTION(n AS INTEGER) AS INTEGER
          total = total + n
          RETURN total
        END FUNCTION
        x = add(5)
        x = add(7)
        PRINT "TOTAL"; total
        total = 100
        PRINT "AFTER"; add(1)

        ' The variable where the closure was made, not a caller's of the same name.
        FUNCTION Caller() AS INTEGER
          LOCAL total AS INTEGER = 500
          RETURN add(1)
        END FUNCTION
        PRINT "CALLER"; Caller(); total

        ' MUTABLE spells the default out.
        n = 10
        bump = FUNCTION() AS INTEGER CAPTURES MUTABLE n
          n = n + 1
          RETURN n
        END FUNCTION
        x = bump()
        PRINT "MUTABLE"; n

        ' STRONG: the closure's own copy, kept between calls.
        m = 10
        own = FUNCTION() AS INTEGER CAPTURES STRONG m
          m = m + 1
          RETURN m
        END FUNCTION
        PRINT "STRONG"; own(); own()
        m = 50
        PRINT "STRONG"; own(); m

        ' READONLY: frozen; READONLY's other names are shared.
        prefix$ = "LOCKED="
        bonus = 5
        locked = FUNCTION(v AS INTEGER) AS STRING CAPTURES READONLY prefix$ = prefix$ + STR$(v + bonus)
        prefix$ = "LIVE="
        bonus = 20
        PRINT locked(2)

        ' A shared array.
        DIM a(3) AS INTEGER
        setter = FUNCTION(i AS INTEGER, v AS INTEGER) AS INTEGER
          a(i) = v
          RETURN a(i)
        END FUNCTION
        x = setter(2, 42)
        a(1) = 7
        PRINT "ARRAY"; a(2); a(1) + a(2)

        ' A function's local array, shared after it returns.
        FUNCTION MakeStack() AS Getter
          DIM items(5) AS INTEGER
          LOCAL top AS INTEGER = 0
          LOCAL push AS Getter
          push = FUNCTION() AS INTEGER
            top = top + 1
            items(top) = top * 10
            RETURN items(top) + items(1)
          END FUNCTION
          RETURN push
        END FUNCTION
        p = MakeStack()
        x = p()
        PRINT "STACK"; p(); p()

        ' ME is the closure's own copy (C6); a record can be READONLY or shared.
        FUNCTION TYPE Bump() AS INTEGER
        TYPE Pt
          X AS INTEGER
        END TYPE
        CLASS Box
          PUBLIC N AS INTEGER
          FUNCTION Bumper() AS Bump
            LOCAL b AS Bump
            b = FUNCTION() AS INTEGER
              ME.N = ME.N + 1
              RETURN ME.N
            END FUNCTION
            RETURN b
          END FUNCTION
        END CLASS
        DIM box AS Box
        box = NEW Box()
        box.N = 5
        f = box.Bumper()
        PRINT "ME"; f(); f(); box.N
        DIM pt AS Pt
        pt.X = 3
        g = FUNCTION() AS INTEGER CAPTURES READONLY pt = pt.X * 2
        h = FUNCTION() AS INTEGER
          pt.X = pt.X + 1
          RETURN pt.X
        END FUNCTION
        pt.X = 4
        PRINT "RECORD"; g(); h(); pt.X

        ' Assigning a READONLY capture is an error ON ERROR traps.
        ON ERROR GOTO Trapped
        q$ = "A"
        frozen = FUNCTION() AS STRING CAPTURES READONLY q$
          q$ = "B"
          RETURN q$
        END FUNCTION
        r$ = frozen()
        PRINT "AFTER TRAP "; q$
        END

        Trapped:
          PRINT "TRAPPED"; ERR
          RESUME NEXT
        """)
        #expect(output == ["COUNTERS1231", "TOTAL12", "AFTER101", "CALLER102102", "MUTABLE11", "STRONG1112", "STRONG1350", "LOCKED= 22", "ARRAY4249", "STACK3040", "ME675", "RECORD655", "TRAPPED5", "AFTER TRAP A"])
    }

    /// UserDocs/CLOSURES.md's examples, as the page prints them.
    @Test("the manual's examples print what the manual says")
    func manualExamples() {
        #expect(run("""
            bonus = 5
            score = function(v as integer) as string = "SCORE=" + str$(v + bonus)
            bonus = 100
            print score(7)
            """) == ["SCORE= 107"])
        #expect(run("""
            total = 0
            add = function(n as integer) as integer
                total = total + n
                return total
            end function
            x = add(5)
            x = add(7)
            print total
            """) == ["12"])
        #expect(run("""
            function type Counter() as integer

            function MakeCounter() as Counter
                local count as integer = 0
                local tick as Counter
                tick = function() as integer
                    count = count + 1
                    return count
                end function
                return tick
            end function

            c = MakeCounter()
            d = MakeCounter()
            print c(); c(); c(); d()
            """) == ["1231"])
        #expect(run("""
            prefix$ = "LOCKED="
            bonus = 5
            score = function(v as integer) as string captures readonly prefix$ = prefix$ + str$(v + bonus)
            prefix$ = "LIVE="
            bonus = 20
            print score(2)
            """) == ["LOCKED= 22"])
        #expect(run("""
            n = 10
            own = function() as integer captures strong n
                n = n + 1
                return n
            end function
            print own(); own(); n
            """) == ["111210"])
        #expect(run("""
            function type Formatter(value as integer) as string

            function Apply$(f as Formatter, n as integer) as string
                return "[" + f(n) + "]"
            end function

            print Apply$(function(v as integer) as string = "N=" + str$(v), 4)
            """) == ["[N= 4]"])
    }
}
