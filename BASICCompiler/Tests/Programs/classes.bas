INTERFACE Shape
  FUNCTION Area() AS DOUBLE
  FUNCTION Describe$() AS STRING
END INTERFACE

CLASS Rect
  IMPLEMENTS Shape
  W AS DOUBLE
  H AS DOUBLE
  PRIVATE Tag$ AS STRING = "rect"
  FUNCTION New(Width AS DOUBLE, Height AS DOUBLE) AS VOID
    ME.W = Width
    ME.H = Height
  END FUNCTION
  FUNCTION Area() AS DOUBLE
    RETURN ME.W * ME.H
  END FUNCTION
  FUNCTION Describe$() AS STRING
    RETURN ME.Tag$ + " " + STR$(ME.W) + " x" + STR$(ME.H)
  END FUNCTION
  FUNCTION Grow(By AS DOUBLE) AS VOID
    ME.W = ME.W + By
    ME.H = ME.H + By
  END FUNCTION
END CLASS

CLASS Square
  INHERITS Rect
  OVERRIDES FUNCTION Describe$() AS STRING
    RETURN "square " + STR$(ME.W)
  END FUNCTION
END CLASS

A = NEW Rect(2, 3)
B = NEW Square(4, 4)
PRINT A.Area(); B.Area()
PRINT A.Describe$()
PRINT B.Describe$()
A.Grow(1)
PRINT A.W; A.H; A.Area()
C = A
C.Grow(10)
PRINT A.W; C.W
DIM S AS Shape
S = B
PRINT S.Area(); S.Describe$()
S = A
PRINT S.Area(); S.Describe$()
PRINT A
