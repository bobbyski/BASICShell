#!/usr/bin/env BASICShell
' Async/task runtime growing verification surface.
' Slice 1 has no public ASYNC/AWAIT syntax yet. It verifies that ordinary
' BASIC execution still behaves correctly while the runtime represents RUN
' as one logical task internally.

print "ASYNC / TASK RUNTIME SUITE"
print

print "SLICE 1: SINGLE LOGICAL TASK"
global total as integer = 0
local yields as integer = 0

gosub AddOne
yield
yields = yields + 1
gosub AddTwo
yield
yields = yields + 1

if total = 3 then Slice1Passed
print "SLICE 1 FAILED, TOTAL ="; total
end

Slice1Passed:
    print "SLICE 1 PASSED"
    print "TOTAL ="; total
    print

print "SLICE 2: COOPERATIVE YIELD BOUNDARIES"
if yields = 2 then Slice2Passed
print "SLICE 2 FAILED, YIELDS ="; yields
end

Slice2Passed:
    print "SLICE 2 PASSED"
    print "YIELDS ="; yields
    print

print "FUTURE SLICES"
print "2. cooperative scheduler and yield points: started"
print "3. host async suspension and resume"
print "4. thread-backed execution"
print "5. ASYNC FUNCTION and AWAIT"
print
print "ASYNC SUITE BASELINE COMPLETE"
end

AddOne:
    total = total + 1
    return

AddTwo:
    total = total + 2
    return
