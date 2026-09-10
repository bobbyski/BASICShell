' Object work, for the dialect performance gate (R2.4).
'
' Deliberately object-heavy: allocation, field reads and writes, method
' calls, virtual dispatch and copies — the operations Rev 2 moves off the
' runtime's records and onto Swift objects. Arithmetic-only benchmarks would
' show nothing, because the two dialects lower arithmetic identically.
'
' Deterministic and terminal-free: a checksum at the end, so a dialect that
' is fast and wrong is caught by the same run that times it.

CLASS Point
    PUBLIC X AS DOUBLE
    PUBLIC Y AS DOUBLE
    FUNCTION Length2() AS DOUBLE
        RETURN ME.X * ME.X + ME.Y * ME.Y
    END FUNCTION
    FUNCTION Shift(By AS DOUBLE) AS VOID
        ME.X = ME.X + By
        ME.Y = ME.Y - By
    END FUNCTION
END CLASS

CLASS Marked
    INHERITS Point
    OVERRIDES FUNCTION Length2() AS DOUBLE
        RETURN ME.X * ME.X + ME.Y * ME.Y + 1
    END FUNCTION
END CLASS

DIM total AS DOUBLE
DIM i AS INTEGER
DIM p AS Point
DIM m AS Marked
DIM copy AS Point

FOR i = 1 TO 400000
    p = NEW Point
    p.X = i
    p.Y = i / 2
    p.Shift(1)
    total = total + p.Length2()

    m = NEW Marked
    m.X = i
    m.Y = 1
    total = total + m.Length2()

    ' A copy, which is where value semantics cost something.
    copy = p
    copy.Shift(2)
    total = total + copy.X - p.X
NEXT i

PRINT "OBJECTS"; total
