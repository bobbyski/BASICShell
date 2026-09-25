' DATE, TIME, DATETIME and DECIMAL (DB19, D0.7).
'
' Four types the language did not have, in all three engines. The reason they
' are types rather than a DOUBLE and a STRING is exactness, so that is mostly
' what this shows.

DIM D AS DATE
DIM T AS TIME
DIM S AS DATETIME
DIM M AS DECIMAL

D = #2026-09-25#
T = #14:30:00#
S = #2026-09-25 14:30:00#
M = 123.45D

PRINT "date:     "; D
PRINT "time:     "; T
PRINT "datetime: "; S
PRINT "decimal:  "; M

PRINT ""
PRINT "-- a decimal is exact; a double is not --"
PRINT "0.1D + 0.2D = "; 0.1D + 0.2D
PRINT "0.1  + 0.2  = "; 0.1 + 0.2
PRINT "1D / 3D     = "; 1D / 3D
PRINT "19.99D * 3D = "; 19.99D * 3D

PRINT ""
PRINT "-- a hundred pennies is a pound, which in DOUBLE it is not --"
DIM TOTAL AS DECIMAL
TOTAL = 0D
RUNNING = 0
FOR I = 1 TO 100
    TOTAL = TOTAL + 0.01D
    RUNNING = RUNNING + 0.01
NEXT
PRINT "decimal: "; TOTAL; "  equal to 1? "; TOTAL = 1D
PRINT "double:  "; RUNNING; "  equal to 1? "; RUNNING = 1

PRINT ""
PRINT "-- converting from text, which is how these arrive --"
PRINT CDATE("2026-01-02"); " "; CTIME("09:05"); " "; CDATETIME("2026-01-02 09:05:00")
PRINT "CDEC of 0.1 plus 0.2 = "; CDEC("0.1") + CDEC("0.2")
PRINT "a DATETIME gives either half: "; CDATE(#2026-01-02 09:05:00#); " "; CTIME(#2026-01-02 09:05:00#)

PRINT ""
PRINT "-- comparison is by value, not by text --"
PRINT "later date?   "; #2026-09-26# > #2026-09-25#
PRINT "same instant? "; #14:30:00.5# = #14:30:00.500#
PRINT "exact money?  "; 19.99D * 3D = 59.97D

PRINT ""
PRINT "-- text still assigns, as it does from a file --"
D = "2026-03-04"
PRINT D
PRINT "and STR$ of one is what PRINT shows: "; STR$(M)

PRINT ""
PRINT "-- # has meant a file number since the 1970s, and still does --"
OPEN "exacttypes-check.txt" FOR OUTPUT AS #1
PRINT #1, "written through a file number"
CLOSE #1
OPEN "exacttypes-check.txt" FOR INPUT AS #1
LINE INPUT #1, L$
CLOSE #1
PRINT L$

