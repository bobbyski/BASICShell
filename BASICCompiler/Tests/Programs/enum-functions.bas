' ENUM values crossing function boundaries (E1).
'
' A FUNCTION declared AS an ENUM returns one, and PRINT shows the member's
' name — VB's rule, which a variable of the ENUM already followed. The
' interpreter refused the RETURN outright, because a bare type name was
' checked as a record, and the compiler printed the ordinal. This pins both,
' and the parameter direction with them.

ENUM Shade
  Light
  Medium
  Dark
END ENUM

FUNCTION Pick(Index AS DOUBLE) AS Shade
  IF Index = 0 THEN
    RETURN Shade.Light
  END IF
  RETURN Shade.Dark
END FUNCTION

FUNCTION Describe(S AS Shade) AS STRING
  RETURN "shade number" + STR$(S)
END FUNCTION

' A result printed directly, and through a variable.
PRINT Pick(0)
PRINT Pick(1)
DIM Chosen AS Shade
Chosen = Pick(1)
PRINT Chosen

' A result passed straight on as an argument.
PRINT Describe(Pick(0))

' A result compared with a member.
IF Pick(1) = Shade.Dark THEN
  PRINT "compares equal to Dark"
END IF
