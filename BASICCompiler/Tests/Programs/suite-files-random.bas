#!/usr/bin/env BASICShell

print "RANDOM AND BINARY FILE TEST SUITE"

open "file-random-suite.dat" as #1 len = 16
field #1, 10 as name$, 4 as scoreBytes$, 2 as code$

lset name$ = "ADA"
lset scoreBytes$ = mks$(98.5)
rset code$ = "A1"
put #1, 1

lset name$ = "GRACE"
lset scoreBytes$ = mks$(97.25)
rset code$ = "G2"
put #1, 2

get #1, 1
print "["; name$; "] SCORE="; cvs(scoreBytes$); " CODE=["; code$; "]"
print "LOF="; lof(1); " LOC="; loc(1); " SEEK="; seek(1)

get #1, 2
print "["; name$; "] SCORE="; cvs(scoreBytes$); " CODE=["; code$; "]"
close #1

open "file-random-suite.dat" for binary as #2
payload$ = input$(lof(2), 2)
print "BINARY BYTES="; lof(2); " READ="; len(payload$); " EOF="; eof(2)
close #2

print "CVI="; cvi(mki$(-1234))
print "CVS="; cvs(mks$(12.5))
print "CVD="; cvd(mkd$(42.25))

File.Rm "file-random-suite.dat"

print "RANDOM AND BINARY FILE TEST SUITE COMPLETE"
