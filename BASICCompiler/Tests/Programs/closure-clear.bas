' Clearing a closure, as VB clears a delegate with Nothing.
'
' NULL is this dialect's Nothing, so assigning it clears a closure. Neither
' the interpreter nor the compilers accepted that, which meant a handler, once
' set, could never be taken away again.

FUNCTION TYPE Handler(Value AS DOUBLE) AS DOUBLE

DIM H AS Handler
H = FUNCTION(Value AS DOUBLE) AS DOUBLE = Value * 2
PRINT "set: "; H(21)

H = NULL
PRINT "cleared"

' A cleared closure can be set again.
H = FUNCTION(Value AS DOUBLE) AS DOUBLE = Value + 1
PRINT "set again: "; H(41)

' Clear it once more and call it: an error that says the closure is not set.
' The interpreter used to read the call as an array element and report "H is
' not an array"; both engines now say what is wrong.
H = NULL
ON ERROR GOTO NotSet
PRINT H(1)
PRINT "not reached"
END

NotSet:
PRINT "calling a cleared closure is an error"
