' Async closures (Documents/CLOSURES.md 3.9, 3.10): ASYNC FUNCTION(...)
' makes a closure whose call starts a task, as an ASYNC FUNCTION's does,
' and an ASYNC FUNCTION TYPE variable holds one.
ASYNC FUNCTION TYPE Loader(n AS INTEGER) AS STRING
FUNCTION TYPE Plain(n AS INTEGER) AS STRING

DIM loader AS Loader
loader = ASYNC FUNCTION(n AS INTEGER) AS STRING
  RETURN "LOADED" + STR$(n)
END FUNCTION
t = loader(7)
PRINT AWAIT t

quick = ASYNC FUNCTION(x AS INTEGER) AS INTEGER = x * 2
PRINT "QUICK"; AWAIT quick(21)

' A task shares what its closure shares.
counter = 10
bump = ASYNC FUNCTION() AS INTEGER
  counter = counter + 1
  RETURN counter
END FUNCTION
PRINT "BUMPED"; AWAIT bump()

' An async closure is not a plain function type's, nor the other way round.
ON ERROR GOTO Trapped
DIM v AS VARIANT
v = loader
DIM plain AS Plain
plain = v
PRINT "AFTER PLAIN"
v = FUNCTION(n AS INTEGER) AS STRING = "SYNC"
loader = v
PRINT "AFTER LOADER"
END

Trapped:
  PRINT "TRAPPED"; ERR
  RESUME NEXT
