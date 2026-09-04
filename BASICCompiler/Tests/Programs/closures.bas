FUNCTION TYPE Formatter(value AS INTEGER) AS STRING

bonus = 5
prefix$ = "SCORE="
scoreText = FUNCTION(value AS INTEGER) AS STRING = prefix$ + STR$(value + bonus)
bonus = 100
PRINT scoreText(7)

locked = FUNCTION(value AS INTEGER) AS STRING CAPTURES READONLY prefix$ = prefix$ + STR$(value + bonus)
prefix$ = "LIVE="
PRINT locked(2)

LOCAL fmt AS Formatter
fmt = FUNCTION(value AS INTEGER) AS STRING
  LOCAL adjusted AS INTEGER = value * 2
  RETURN "BLOCK=" + STR$(adjusted)
END FUNCTION
PRINT fmt(21)

FUNCTION Apply$(f AS Formatter, n AS INTEGER) AS STRING
  RETURN "[" + f(n) + "]"
END FUNCTION
PRINT Apply$(fmt, 4)

FUNCTION MakeAdder(amount AS INTEGER) AS Formatter
  RETURN FUNCTION(value AS INTEGER) AS STRING = STR$(value + amount)
END FUNCTION
add10 = MakeAdder(10)
PRINT add10(5)
