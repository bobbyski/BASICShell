' {{NAME}} — functions, arrays, and DATA.
'
' One file, on purpose: the shape a real program grows into, small enough
' to read at once. The data is in DATA, read into an array; the work is in
' FUNCTIONs, each documented with a /// comment (summary, then
' - Parameter and - Returns:, as Swift writes them); the statements at the
' bottom run it. A FUNCTION's parameters and LOCAL variables are its own;
' every other name is shared with the whole program.

/// The scores read from DATA, one place for each student, from 1.
DIM Scores(3)

/// The average of the first scores.
///
/// - Parameter Count: How many scores to average, from Scores(1).
/// - Returns: Their mean.
FUNCTION Average(Count AS INTEGER) AS DOUBLE
  ' LOCAL keeps the total and the counter this function's own: an
  ' undeclared K would be the whole program's K.
  LOCAL Total = 0
  LOCAL K = 0
  FOR K = 1 TO Count
    Total = Total + Scores(K)
  NEXT K
  RETURN Total / Count
END FUNCTION

/// The letter grade for a score.
///
/// - Parameter Score: A score out of 100.
/// - Returns: "A", "B", "C" or "F".
FUNCTION Grade$(Score AS DOUBLE) AS STRING
  ' The first CASE that is true wins, so the highest bar comes first.
  SELECT CASE Score
    CASE IS >= 90: RETURN "A"
    CASE IS >= 80: RETURN "B"
    CASE IS >= 70: RETURN "C"
    CASE ELSE: RETURN "F"
  END SELECT
END FUNCTION

' The class: each student's name, then their score. READ takes them in
' this order.
DATA "Ada", 96, "Grace", 88, "Linus", 72

' One line a student: the name, the score and the grade, in columns.
FOR I = 1 TO 3
  READ Student$, Scores(I)
  PRINT Student$; TAB(12); Scores(I); TAB(20); Grade$(Scores(I))
NEXT I
PRINT "Average:"; Average(3)
