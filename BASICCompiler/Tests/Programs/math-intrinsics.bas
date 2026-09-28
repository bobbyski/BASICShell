REM The one-argument math family, PI and its seeding, and the domain errors
REM (BBC_ADINS.md A3, A4).
PRINT PI
PRINT DEG(PI); " "; DEC(PI / 2); " "; RAD(180)
PRINT SQR(16); " "; SQR(2); " "; SIN(0); " "; COS(0); " "; TAN(0); " "; ATN(1) * 4
PRINT LOG(1); " "; LN(1); " "; LOG(EXP(2)); " "; LOG10(1000); " "; LCT(100); " "; LTW(8)
PRINT ACS(1); " "; ASN(0); " "; HCS(0); " "; HSN(0); " "; HTN(0); " "; SCN(-5); " "; SEC(0)
PRINT COT(PI / 4) > 0.99; " "; CSC(PI / 2)
REM With no file open, LOC is IBM BASIC 1970's natural log.
PRINT LOC(1); " "; LOC(EXP(3))
FUNCTION Area(R AS DOUBLE) AS DOUBLE
  RETURN PI * R * R
END FUNCTION
PRINT Area(2)
PI = 3.14159
PRINT PI * 2
10 ON ERROR GOTO 900
20 PRINT LOG(0)
30 PRINT LN(-1)
40 PRINT SQR(-1)
50 PRINT ACS(2)
60 PRINT COT(0)
70 PRINT EXP(1000)
80 PRINT LOG10(-5)
90 PRINT HCS(1000)
100 PRINT LOC(0)
110 END
900 PRINT "TRAPPED ERR="; ERR; "ERL="; ERL
910 RESUME NEXT
