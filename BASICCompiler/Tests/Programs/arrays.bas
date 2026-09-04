DIM A(5)
FOR I = 0 TO 5
  A(I) = I * I
NEXT I
PRINT A(0); A(3); A(5)
DIM Grid(2, 3)
Grid(1, 2) = 7
Grid(2, 3) = 9
PRINT Grid(1, 2); Grid(2, 3); Grid(0, 0)
Names$(2) = "two"
Names$(10) = "ten"
PRINT Names$(2); "|"; Names$(10); "|"; Names$(5); "|"
N = 3
DIM B(N)
B(N) = 42
PRINT B(3)
FUNCTION SumTo(Count AS INTEGER) AS DOUBLE
  LOCAL Total = 0
  FOR K = 1 TO Count
    Total = Total + A(K)
  NEXT K
  RETURN Total
END FUNCTION
PRINT SumTo(5)
PRINT A(6)
PRINT "NEVER"
