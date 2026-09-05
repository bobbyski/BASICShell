' WHILE / WEND: the loop whose count is not known when it starts.
'
' The condition is tested before the body, so a WHILE that is false to begin
' with runs no times. A WEND goes back to the test, not to the body.
DIM i AS INTEGER
i = 0
WHILE i < 3
    PRINT "i ="; i
    i = i + 1
WEND
PRINT "after ="; i

DIM never AS INTEGER
never = 9
WHILE never < 0
    PRINT "this never runs"
WEND
PRINT "skipped"

' Nested, and with a FOR inside, so the two loop forms are seen not to
' confuse each other's ends.
DIM outer AS INTEGER
DIM inner AS INTEGER
DIM k AS INTEGER
DIM total AS INTEGER
outer = 0
total = 0
WHILE outer < 3
    inner = 0
    WHILE inner < 2
        FOR k = 1 TO 2
            total = total + k
        NEXT k
        inner = inner + 1
    WEND
    outer = outer + 1
WEND
PRINT "total ="; total

' A string condition, and one that ends by changing the variable inside an IF.
DIM word AS STRING
word = ""
WHILE LEN(word) < 5
    word = word + "ab"
    IF LEN(word) > 4 THEN
        PRINT "grew to"; LEN(word)
    END IF
WEND
PRINT "word ="; word

' In a FUNCTION, where the loop is over a local.
PRINT "counted ="; CountDown(4)

FUNCTION CountDown(from AS INTEGER) AS INTEGER
    LOCAL steps = 0
    LOCAL value = from
    WHILE value > 0
        value = value - 1
        steps = steps + 1
    WEND
    RETURN steps
END FUNCTION
