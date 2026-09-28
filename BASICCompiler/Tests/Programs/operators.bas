REM ^, MOD and \ with GW-BASIC's precedence and rules (BBC_ADINS.md A1, A2).
PRINT 2 ^ 3; " "; -2 ^ 2; " "; 2 ^ 3 ^ 2; " "; 2 ^ -1; " "; 2 * -3 ^ 2
PRINT 2 ^ 0.5
PRINT 7 MOD 3; " "; -7 MOD 3; " "; 7 MOD -3; " "; 10.4 MOD 4; " "; 25.68 MOD 6.99
PRINT 7 \ 2; " "; -7 \ 2; " "; 25.68 \ 6.99
PRINT 1 + 7 MOD 3 * 2; " "; 10 \ 4 MOD 3; " "; 7 MOD 3 MOD 2
N% = 2 ^ 3
PRINT N%
PRINT 1.5D ^ 2; " "; 2D ^ -2; " "; 10.5D MOD 3; " "; 7D \ 2
10 ON ERROR GOTO 900
20 PRINT 0 ^ -1
30 PRINT (-8) ^ 0.5
40 PRINT 10 ^ 400
50 PRINT 5 MOD 0.4
60 PRINT 1 \ 0
70 PRINT 2D ^ 0.5D
80 END
900 PRINT "TRAPPED ERR="; ERR; "ERL="; ERL
910 RESUME NEXT
