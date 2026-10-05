' Strings are equal when their contents are, however each was made.
'
' CHR$ makes a string of bytes and a literal makes text, and the two are the
' same string when they hold the same characters: CHR$(65) is "A". It is how
' a program tells which key INKEY$ read — Return is CHR$(13).
PRINT "CHR IS LITERAL ="; (CHR$(65) = "A"); (CHR$(65) <> "A")
PRINT "LITERAL IS CHR ="; ("A" = CHR$(65))

key$ = MID$("x" + CHR$(13), 2)
PRINT "RETURN ="; (key$ = CHR$(13)); (key$ = CHR$(10))

word$ = LEFT$("BASIC", 2)
PRINT "BUILT ="; (word$ = CHR$(66) + CHR$(65)); (word$ = "BA")

PRINT "STILL DIFFERENT ="; ("A" + CHR$(0) = "A"); (CHR$(66) = "A")

SELECT CASE "Q"
CASE CHR$(81)
    PRINT "CASE = CHR$"
CASE ELSE
    PRINT "CASE = ELSE"
END SELECT

IF CHR$(27) = MID$("a" + CHR$(27), 2) THEN PRINT "ESCAPE = YES" ELSE PRINT "ESCAPE = NO"
