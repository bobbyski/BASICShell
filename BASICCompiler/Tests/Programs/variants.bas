' VARIANT semantics: the interpreter's BASICValue, boxed.
DIM v AS VARIANT
PRINT "["; v; "]"
PRINT v + 1
PRINT v + "x"
v = 5
PRINT v; v + 2; v * 3; v - 1; v / 2
PRINT v = 5; v = "5"; v <> 5; v < 6; v > 6
v = "abc"
PRINT v; v + "def"; LEN(v); v = "abc"
v = TRUE
PRINT v; v + 1
v = NULL
PRINT "["; v; "]"; v = NULL
DIM n AS INTEGER
n = 7
v = n
n = v
PRINT n
DIM s$
v = "text"
s$ = v
PRINT s$
DIM d AS DICTIONARY
d("one") = 1
d("two") = "second"
d(3) = TRUE
PRINT d("one"); d("two"); d("3"); d(3); "["; d("missing"); "]"
PRINT d
v = d
PRINT v
PRINT v("two")
PRINT ToJsonString(d, FALSE)
DIM a(2) AS INTEGER
a(0) = 4
a(1) = 5
a(2) = 6
PRINT LEN(a); a
d("list") = a
PRINT ToJsonString(d, FALSE)
v = FromJsonString("[10, 20, 30]", TRUE)
PRINT LEN(v); v(1)
DIM w AS VARIANT
w = FromJsonString('{"k": [1, {"z": null}], "b": false}', TRUE)
PRINT ToJsonString(w, FALSE)
PRINT ToJsonString(w, TRUE)
IF w THEN PRINT "truthy"
DIM e AS VARIANT
IF e THEN PRINT "bad" ELSE PRINT "empty is false"
SELECT CASE w("b")
CASE FALSE
    PRINT "false case"
CASE ELSE
    PRINT "else case"
END SELECT
FUNCTION Twice(x AS VARIANT) AS VARIANT
    RETURN x + x
END FUNCTION
PRINT Twice(21); Twice("ab")
FUNCTION Describe$(x AS VARIANT) AS STRING
    Describe$ = "got " + STR$(LEN(x))
END FUNCTION
PRINT Describe$("hello")
ON ERROR GOTO Trap
w = "oops"
n = w
PRINT "not reached"
Trap:
PRINT "ERR"; ERR
ON ERROR GOTO Trap2
' v holds an array, so the interpreter coerces every later assignment to its shape.
v = "not an array"
PRINT "not reached either"
Trap2:
PRINT "ERR"; ERR
END
