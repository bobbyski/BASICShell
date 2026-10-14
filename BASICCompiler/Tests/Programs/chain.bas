REM CHAIN (BBC_ADINS.md A7, rulings B5 and B6): the next program starts at
REM line 200 with what COMMON names (an array and a record among them),
REM and nothing else. A compiled program hands over to chain-next's own
REM binary, which basicc builds beside it.
TYPE Pair
  Left AS DOUBLE
  Right AS STRING
END TYPE
COMMON A, B$, C(), P
DIM C(3)
DIM P AS Pair
A = 42: B$ = "kept": C(1) = 7: D = 99
P.Left = 1.5: P.Right = "right"
PRINT "first"
CHAIN "chain-next", 200
PRINT "never"
