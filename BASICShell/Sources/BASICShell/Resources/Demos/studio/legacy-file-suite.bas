#!/usr/bin/env BASICShell

print "LEGACY FILE TEST SUITE"

print "WRITE OUTPUT"
open "legacy-file-suite.txt" for output as #1
print #1, "NAME,AGE,SCORE"
print #1, "Ada,16,98.5"
print #1, "Grace,17,97.25"
print #1, using "SUBTOTAL ###.##"; 195.75
close #1

print "APPEND"
open "legacy-file-suite.txt" for append as #1
print #1, "TAIL,1,2"
close #1

print "READ BACK"
open "legacy-file-suite.txt" for input as #2
line input #2, header$
input #2, name1$, age1, score1
input #2, name2$, age2, score2
line input #2, subtotal$
input #2, tail$, tailA, tailB

print "HEADER = "; header$
print name1$; " AGE="; age1; " SCORE="; score1
print name2$; " AGE="; age2; " SCORE="; score2
print subtotal$
print tail$; " "; tailA; " "; tailB
print "EOF = "; eof(2)
close #2

print "DONE"
