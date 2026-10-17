' HASTOUCH (BASIC-70): 1 when the screen takes touch. A terminal does not,
' so both engines print the same here.
PRINT HASTOUCH; HASTOUCH()
IF HASTOUCH THEN PRINT "DRAG TO STEER" ELSE PRINT "ARROWS OR MOUSE TO STEER"
targetSize = 24
IF HASTOUCH() = 1 THEN targetSize = 48
PRINT "TARGETS "; targetSize
