A$ = "Hello"
B$ = A$ + ", " + "World"
PRINT B$; LEN(B$)
PRINT LEFT$(B$, 2); RIGHT$(B$, 3); MID$(B$, 8); MID$(B$, 3, 2)
PRINT INSTR(B$, "World"); INSTR(3, B$, "l"); INSTR(B$, "zzz")
PRINT VAL("12.5abc"); VAL("abc"); STR$(7); STR$(-7); CHR$(65); ASC("Z")
PRINT SPACE$(3); "|"; STRING$(4, "-"); "|"
IF A$ = "Hello" THEN PRINT "EQ"
IF A$ <> "hello" THEN PRINT "NE"
PRINT A$ = "Hello"; A$ = "x"
