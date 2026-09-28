REM MID$ as a statement: overwrite in place, never changing the length
REM (BBC_ADINS.md A6). VBA's own examples, then GW-BASIC's.
M$ = "The dog jumps"
MID$(M$, 5, 3) = "fox": PRINT M$
MID$(M$, 5) = "cow": PRINT M$
MID$(M$, 5) = "cow jumped over": PRINT M$
MID$(M$, 5, 3) = "duck": PRINT M$
A$ = "KANSAS CITY, MO"
MID$(A$, 14) = "KS"
PRINT A$
DIM N$(2)
N$(1) = "hello"
MID$(N$(1), 1, 1) = "J"
PRINT N$(1)
10 ON ERROR GOTO 900
20 B$ = "abc"
30 MID$(B$, 0) = "x"
40 MID$(B$, 4) = "x"
50 MID$(B$, 1, -1) = "x"
60 MID$(B$, 2, 0) = "x"
70 PRINT B$
80 END
900 PRINT "TRAPPED ERR="; ERR; "ERL="; ERL
910 RESUME NEXT
