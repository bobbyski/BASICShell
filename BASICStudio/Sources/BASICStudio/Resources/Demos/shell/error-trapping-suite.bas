#! /usr/bin/env aibasic
' Error trapping smoke test for BASICStudio and BASICShell.
' This intentionally raises common runtime errors and verifies that
' ON ERROR GOTO, ERR, ERL, and RESUME NEXT keep the program moving.

print "ERROR TRAPPING SUITE"
print

on error goto Trap

print "CASE 1: ERROR 42"
error 42
print "CASE 1 CONTINUED"

print "CASE 2: DIVISION BY ZERO"
print 10 / 0
print "CASE 2 CONTINUED"

print "CASE 3: MISSING LINE"
goto 99999
print "CASE 3 CONTINUED"

print "CASE 4: MISSING LABEL"
goto NotThere
print "CASE 4 CONTINUED"

print "CASE 5: TYPE MISMATCH"
local count as integer = "not a number"
print "CASE 5 CONTINUED"

print "CASE 6: RETURN WITHOUT GOSUB"
return
print "CASE 6 CONTINUED"

on error goto 0
print
print "ALL ERROR TRAPS COMPLETED"
end

Trap:
    print "TRAPPED ERR="; ERR; " ERL="; ERL
    resume next
