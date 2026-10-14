REM The program chain.bas chains to, at line 200 with A, B$, C() and P.
REM Run on its own it starts at the top with nothing carried.
TYPE Pair
  Left AS DOUBLE
  Right AS STRING
END TYPE
DIM P AS Pair
100 PRINT "top"
200 PRINT "next"; A; B$; C(1); D
210 PRINT P.Left; P.Right
220 RUN "chain-last"
