' Async parity: launch order, ids, snapshot, await failure, JOIN, CANCEL,
' and the end-of-run warning.
'
' Two cases are deliberately missing. The interpreter runs a task body on a
' real thread, so `BACKGROUND f()` and a dropped task's cancellation race the
' end of the run: on a loaded machine the body's output and the warning it
' earns both change. Everything below is what the interpreter does whatever
' the load.
DIM total AS INTEGER
DIM label$ AS STRING
label$ = "base"
total = 10

ASYNC FUNCTION Add(a AS INTEGER, b AS INTEGER) AS INTEGER
    PRINT "ADD BODY "; a; b
    RETURN a + b
END FUNCTION

ASYNC FUNCTION Snapshot() AS STRING
    RETURN label$ + ":" + STR$(total)
END FUNCTION

ASYNC FUNCTION Failing() AS INTEGER
    RETURN 1 / 0
END FUNCTION

ASYNC FUNCTION Noisy(name AS STRING)
    PRINT "NOISY "; name
END FUNCTION

ASYNC FUNCTION Tag(name AS STRING) AS STRING
    PRINT "TAG "; name
    RETURN "<" + name + ">"
END FUNCTION

' A body that prints nothing: the interpreter may run a task it was never
' asked to wait for, so only a silent one can be left unobserved.
ASYNC FUNCTION Quiet(n AS INTEGER) AS INTEGER
    RETURN n * 2
END FUNCTION

DIM t AS TASK
t = Add(2, 3)
PRINT "AFTER LAUNCH"
PRINT "HANDLE ="; t
PRINT "STATUS ="; TASKSTATUS$(t)
PRINT "SUM ="; AWAIT t
PRINT "STATUS ="; TASKSTATUS$(t)
PRINT "INLINE ="; AWAIT Add(4, 5)

DIM s AS TASK
s = Snapshot()
label$ = "changed"
total = 99
PRINT "SNAP ="; AWAIT s
PRINT "LIVE ="; label$; total

DIM v AS TASK
v = ASYNCVALUE("payload")
PRINT "VALUE ="; AWAIT v
PRINT "SLEPT ="; AWAIT SLEEP(5)

ON ERROR GOTO handler
DIM f AS TASK
f = Failing()
PRINT "BEFORE AWAIT"
PRINT "NEVER ="; AWAIT f
PRINT "AFTER AWAIT"
PRINT "ERROR$ ="; TASKERROR$(f)
PRINT "STATUS ="; TASKSTATUS$(f)

DIM n AS TASK
n = Tag("joined")
PRINT "BEFORE JOIN"
JOIN n
PRINT "AFTER JOIN"

DIM c AS TASK
c = Quiet(1)
CANCEL c
PRINT "CANCELLED ="; TASKSTATUS$(c)

DIM u AS TASK
u = Quiet(2)
PRINT "DONE"
END

handler:
PRINT "CAUGHT "; ERR; " "; ERL
RESUME NEXT
