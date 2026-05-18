#! /usr/bin/env aibasic

print "LEGACY FILE DEMO"

open "legacy-demo.txt" for output as #1
print #1, "Ada,16"
print #1, "Grace,17"
close #1

open "legacy-demo.txt" for append as #1
print #1, "Katherine,18"
close #1

open "legacy-demo.txt" for input as #1
Again:
    if eof(1) then Done
    input #1, name$, age
    print name$; " -> "; age
    goto Again
Done:
close #1

print "DONE"
