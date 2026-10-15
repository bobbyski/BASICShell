' A runtime error inside a closure's body is placed on its own line, in
' both engines, as one in a FUNCTION is (Documents/CLOSURES.md 4.9).
divide = FUNCTION(x AS INTEGER) AS INTEGER
  LOCAL y AS INTEGER = 0
  RETURN x / y
END FUNCTION
PRINT "BEFORE"
PRINT divide(1)
