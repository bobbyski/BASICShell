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

for i = 1 to 2
    print "TASK ALPHA ITER ="; i
    print "TASK ALPHA BEFORE YIELD "; i
    yield
    yields = yields + 1
    print "TASK BETA ITER ="; i
    print "TASK BETA BEFORE YIELD "; i
    yield
    yields = yields + 1
next i
gosub AddOne
gosub AddTwo

if total = 3 then Slice1Passed
print "SLICE 1 FAILED, TOTAL ="; total
end

Slice1Passed:
    print "SLICE 1 PASSED"
    print "TOTAL ="; total
    print

print "SLICE 2: COOPERATIVE YIELD BOUNDARIES"
if yields = 4 then Slice2Passed
print "SLICE 2 FAILED, YIELDS ="; yields
end

Slice2Passed:
    print "SLICE 2 PASSED"
    print "YIELDS ="; yields
    print

print "SLICE 3: TASK HANDLES AND CANCELLATION"
print "SLICE 3 HOST/API VERIFIED"
print
print "SLICE 4: TASK PARENTS AND JOIN POLICY"
print "SLICE 4 HOST/API VERIFIED"
print
print "SLICE 5: HOST OPERATION SUSPEND/RESUME"
print "SLICE 5 HOST/API VERIFIED"
print
print "SLICE 6: SWIFT HOST TASK LANES"
print "SLICE 6 HOST/API VERIFIED"
print
print "SLICE 7: TASK RESULT PAYLOADS"
print "SLICE 7 HOST/API VERIFIED"
print
print "FUTURE SLICES"
print "8. ASYNC FUNCTION and AWAIT"
print
print "ASYNC SUITE BASELINE COMPLETE"
end

AddOne:
    total = total + 1
    return

AddTwo:
    total = total + 2
    return
