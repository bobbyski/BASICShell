' Containers inside a CLASS: arrays, dictionaries and VARIANTs as fields.
'
' These are the fields Rev 2's escape analysis used to refuse, so this
' program is what says the two dialects agree about them. Every line here is
' about the *semantics*, not the storage: BASIC objects copy on assignment,
' and a container inside one copies with it.
'
' No DICTIONARY field: the interpreter accepts `obj.Tags("k") = v` on one and
' basicc refuses it as "Tags is not an array", in both dialects. That is a
' Rev 1 divergence from the oracle, recorded in BASIC_COMPILER.md rather than
' worked around here.

CLASS Bag
    PUBLIC Items(3) AS DOUBLE
    PUBLIC Extra AS VARIANT
    PUBLIC Label AS STRING

    FUNCTION Total() AS DOUBLE
        DIM t AS DOUBLE
        DIM i AS INTEGER
        FOR i = 1 TO 3
            t = t + ME.Items(i)
        NEXT i
        RETURN t
    END FUNCTION

    FUNCTION Fill(By AS DOUBLE) AS VOID
        DIM i AS INTEGER
        FOR i = 1 TO 3
            ME.Items(i) = i * By
        NEXT i
    END FUNCTION
END CLASS

DIM A AS Bag
A = NEW Bag
A.Label = "first"
A.Fill(10)
A.Extra = 42
PRINT "TOTAL"; A.Total()
PRINT "ITEM"; A.Items(2)
PRINT "EXTRA"; A.Extra
PRINT "LABEL "; A.Label

' Value semantics: the copy is its own object, containers and all.
DIM C AS Bag
C = A
C.Fill(100)
C.Extra = "changed"
C.Label = "second"
PRINT "AFTER COPY"
PRINT "A"; A.Total(); A.Extra; A.Label
PRINT "C"; C.Total(); C.Extra; C.Label

' Through a function, which takes its own copy.
FUNCTION Grow(Item AS Bag) AS DOUBLE
    Item.Fill(1)
    RETURN Item.Total()
END FUNCTION
PRINT "GROWN"; Grow(A); "ORIGINAL"; A.Total()
PRINT A
