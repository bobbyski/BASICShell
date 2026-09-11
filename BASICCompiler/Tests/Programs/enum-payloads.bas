' ENUM members that carry fields (E3) — Swift's associated values, read
' through SELECT CASE and field access the way a BASIC TYPE is read.
'
' A value is its case plus that case's fields. PRINT shows it as it would be
' written; = compares the case and every field; SELECT CASE matches the case
' alone. Reading a field the current case does not have is a runtime error
' naming the case — silently answering 0 would hide exactly the bug this
' feature exists to catch.

ENUM Shot
  Missed
  Hit(Damage AS DOUBLE)
  Critical(Damage AS DOUBLE, Note AS STRING)
END ENUM

DIM S AS Shot
PRINT "default:"; S
S = Shot.Hit(12)
PRINT "print:"; S
PRINT "damage:"; S.Damage

SELECT CASE S
  CASE Shot.Missed
    PRINT "select: missed"
  CASE Shot.Hit
    PRINT "select: hit for"; S.Damage
  CASE ELSE
    PRINT "select: other"
END SELECT

S = Shot.Critical(30, "headshot")
PRINT "print:"; S
SELECT CASE S
  CASE Shot.Hit, Shot.Critical
    PRINT "select: landed"; S.Damage; " "; S.Note
END SELECT

' Equality is the case and every field.
DIM T AS Shot
T = Shot.Critical(30, "headshot")
IF S = T THEN PRINT "equal: same case, same fields"
T = Shot.Critical(31, "headshot")
IF S <> T THEN PRINT "not equal: a field differs"
T = Shot.Hit(30)
IF S <> T THEN PRINT "not equal: a different case"

' A value, not a reference: reassigning the copy leaves the original alone.
T = S
T = Shot.Missed
PRINT "original:"; S; " copy:"; T

S = Shot.Missed
PRINT "print:"; S
ON ERROR GOTO NoField
PRINT S.Damage
PRINT "not reached"
END

NoField:
PRINT "caught, ERR ="; ERR
