' {{NAME}} — functions, arrays, and DATA.
'
' A FUNCTION's parameters and LOCAL variables are its own; every
' other name is shared with the whole program.

FUNCTION Average(Count AS INTEGER) AS DOUBLE
  LOCAL Total = 0
  FOR K = 1 TO Count
    Total = Total + Scores(K)
  NEXT K
  RETURN Total / Count
END FUNCTION

FUNCTION Grade$(Score AS DOUBLE) AS STRING
  SELECT CASE Score
    CASE IS >= 90: RETURN "A"
    CASE IS >= 80: RETURN "B"
    CASE IS >= 70: RETURN "C"
    CASE ELSE: RETURN "F"
  END SELECT
END FUNCTION

DATA "Ada", 96, "Grace", 88, "Linus", 72
DIM Scores(3)
FOR I = 1 TO 3
  READ Student$, Scores(I)
  PRINT Student$; TAB(12); Scores(I); TAB(20); Grade$(Scores(I))
NEXT I
PRINT "Average:"; Average(3)
