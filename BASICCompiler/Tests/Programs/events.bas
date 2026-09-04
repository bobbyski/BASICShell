' Event parity: a SecondsTimer, its handler, a typed event object, and the
' tick divisor of `ON timer(n)`. What a tick's payload says is checked, but
' not how many ticks arrive: the interpreter runs its timer on a real clock
' and a loaded machine coalesces ticks, so a count is not an oracle.
' Terminal-sourced events (resize, mouse) need a terminal and are driven
' through a pty instead.
DIM seen AS INTEGER
DIM divided AS INTEGER
seen = 0
divided = 0

LET timer = SecondsTimer(0.05)
timer.repeating = true
PRINT "BEFORE START"
timer.start()
ON timer GOSUB Tick
ON timer(3) GOSUB Every3

Wait:
    YIELD
    IF divided = 0 THEN GOTO Wait

timer.stop()
PRINT "DONE"
END

FUNCTION Tick(event AS BASICTimerEvent)
    IF seen = 0 THEN
        seen = 1
        PRINT "TICK type "; event.Type; " ticks "; event.Ticks; " interval "; event.Interval; " handled "; event.Handled
        PRINT "TICK positive "; event.Sequence > 0; " elapsed "; event.Elapsed > 0
    END IF
END FUNCTION

FUNCTION Every3(event AS VARIANT)
    IF divided = 0 THEN
        divided = 1
        PRINT "EVERY "; INT(event("ticks")); " REMAINDER "; INT(event("sequence")) MOD 3
    END IF
END FUNCTION
