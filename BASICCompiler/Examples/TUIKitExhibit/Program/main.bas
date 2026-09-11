' A compiled BASIC program driving TUIKit directly (R5.1).
'
' A real App, on a headless terminal, draws a real Window; BASIC schedules
' its own stop and then reads back the frame the terminal received. Nothing
' here is hand-written Swift: every call is TUIKit's own, reached through what
' basicc read out of TUIKit's symbol graph.
IMPORT "TUIKit"

DIM D AS HeadlessDriver
D = NEW HeadlessDriver(40, 8, FALSE)

' NULL for the timer source means Swift's own default: the real clock App
' would have chosen.
DIM A AS App
A = NEW App(D, NULL)

DIM W AS Window
W = NEW Window(0, 0, 40, 8)

' The timer's handler, written in BASIC. It puts text on the window, then
' asks the app to stop; TUIKit presents one more frame after a handler runs,
' so the text is in the frame BASIC reads back.
FUNCTION Finish() AS DOUBLE
  W.showTooltip("Hello from BASIC", 2, 2)
  A.stop()
  RETURN 0
END FUNCTION

' Stop after the first frames — 50 milliseconds, as SLEEP counts time. The
' handler is a BASIC closure, stored by TUIKit as a Swift one.
A.schedule(50, FUNCTION() AS DOUBLE = Finish())
A.run(W)

DIM Lines AS VARIANT
Lines = D.snapshotText()
PRINT "TUIKit drew"; LEN(Lines); " lines:"
FOR I = 0 TO LEN(Lines) - 1
  PRINT "|"; Lines(I); "|"
NEXT I
