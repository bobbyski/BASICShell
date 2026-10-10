' TIMER(): seconds since midnight, with the fraction, as QuickBASIC's and
' VB's Timer. The values differ from run to run, so only their range and
' order are printed.
T1 = TIMER()
S = 0
FOR I = 1 TO 20000
  S = S + I
NEXT I
T2 = TIMER()
IF T1 >= 0 AND T1 < 86400 THEN PRINT "in a day" ELSE PRINT "out of range"
IF T2 >= T1 OR T2 < 1 THEN PRINT "in order" ELSE PRINT "backward"
PRINT S
' Without its parentheses, timer is still a name a program may use.
LET timer = 5
PRINT timer + 1
