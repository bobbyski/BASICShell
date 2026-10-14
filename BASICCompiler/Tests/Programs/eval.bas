REM EVAL (BBC_ADINS.md A10, ruling B8): an expression in a string, evaluated
REM at run time over the variables in scope and the program's own FUNCTIONs;
REM pure unless OPTION EVAL FULL; a string that does not parse is ERR 2.
TYPE Point
  X AS DOUBLE
  Y AS DOUBLE
END TYPE
FUNCTION Square(N AS DOUBLE) AS DOUBLE
  RETURN N * N
END FUNCTION
FUNCTION Plot(X AS DOUBLE, F$ AS STRING) AS DOUBLE
  LOCAL K = 10
  RETURN EVAL(F$)
END FUNCTION
Q$ = CHR$(34)
X = 3
PRINT EVAL("X * 2 + 1")
WHO$ = "Ada"
PRINT EVAL("WHO$ + " + Q$ + " Lovelace" + Q$)
DIM V(3)
V(2) = 5
PRINT EVAL("V(2) * 2 + V(0)")
DIM P AS Point
P.X = 4: P.Y = 1.5
PRINT EVAL("P.X * P.Y")
SCORE1 = 10: SCORE2 = 20
FOR I = 1 TO 2
  PRINT EVAL("SCORE" + MID$(STR$(I), 2));
NEXT I
PRINT
FOR X = 1 TO 3
  PRINT Plot(X, "Square(X) + K");
NEXT X
PRINT
PRINT EVAL("LEN(" + Q$ + "abc" + Q$ + ") + SQR(16) + LN(1) + LOG(100)")
IF EVAL("2 = 2") THEN PRINT "= compares"
10 ON ERROR GOTO 100
20 Y = EVAL("2 +")
30 Z$ = EVAL("SYSTEM$(" + Q$ + "echo hi" + Q$ + ")")
40 PRINT "done"
50 END
100 PRINT "ERR"; ERR; "ERL"; ERL
110 RESUME NEXT
