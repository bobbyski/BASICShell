REM GW's ON TIMER(n) GOSUB with a label (BBC_ADINS.md A14), in a program
REM without line numbers. The handler being a label, not a FUNCTION, is
REM what makes this a trap rather than a SecondsTimer's handler.
ON TIMER(0.01) GOSUB Tick
TIMER ON
S = TIMER()
WHILE N < 2 AND TIMER() - S < 5
WEND
PRINT "ticks"; N
ON KEY(1) GOSUB Tick: KEY(1) ON: KEY(1) STOP: KEY(1) OFF
PRINT "keys armed and disarmed"
END
Tick:
N = N + 1
IF N = 2 THEN TIMER OFF
RETURN
