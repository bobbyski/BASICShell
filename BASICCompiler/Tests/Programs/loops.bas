' Nested FOR loops, negative steps, and a loop that never enters.
FOR I = 1 TO 3
  FOR J = 3 TO 1 STEP -1
    PRINT I * 10 + J;
  NEXT J
  PRINT
NEXT I
FOR K = 5 TO 1
  PRINT "NEVER"
NEXT K
PRINT "K AFTER ="; K
FOR X = 0 TO 1 STEP 0.25
  PRINT X;
NEXT
PRINT
