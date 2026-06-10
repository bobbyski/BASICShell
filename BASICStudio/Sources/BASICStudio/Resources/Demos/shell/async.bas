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
print "SLICE 8: AWAIT STATE PRIMITIVE"
print "SLICE 8 HOST/API VERIFIED"
print
print "SLICE 9: ASYNC FUNCTION AND AWAIT"
asyncTotal = await AsyncAdd(4, 5)
if asyncTotal = 9 then Slice9Passed
print "SLICE 9 FAILED, ASYNCTOTAL ="; asyncTotal
end

Slice9Passed:
    print "SLICE 9 PASSED"
    print "ASYNCTOTAL ="; asyncTotal
    print

print "SLICE 10: RESUMABLE ASYNC SUSPENSION"
print "SLICE 10 HOST/API VERIFIED"
print
print "SLICE 11: COOPERATIVE AWAIT RESUME"
print "SLICE 11 HOST/API VERIFIED"
print
print "SLICE 12: USER-VISIBLE SUSPENDED AWAIT"
awaited$ = await AsyncValue("payload")
awaitedNumber = await AsyncValue(12)
if awaited$ = "payload" then Slice12StringPassed
print "SLICE 12 FAILED, AWAITED ="; awaited$
end

Slice12StringPassed:
    if awaitedNumber = 12 then Slice12Passed
    print "SLICE 12 FAILED, NUMBER ="; awaitedNumber
    end

Slice12Passed:
    print "SLICE 12 PASSED"
    print "AWAITED ="; awaited$
    print "AWAITED NUMBER ="; awaitedNumber
    print

print "SLICE 13: ASYNC FUNCTION TASK SCHEDULING"
asyncHandle = AsyncAdd(6, 7)
if asyncHandle > 0 then Slice13HandlePassed
print "SLICE 13 FAILED, HANDLE ="; asyncHandle
end

Slice13HandlePassed:
    asyncScheduledTotal = await asyncHandle
    if asyncScheduledTotal = 13 then Slice13Passed
    print "SLICE 13 FAILED, TOTAL ="; asyncScheduledTotal
    end

Slice13Passed:
    print "SLICE 13 PASSED"
    print "HANDLE ="; asyncHandle
    print "SCHEDULED TOTAL ="; asyncScheduledTotal
    print

print "SLICE 14: TRUE ASYNC BASIC BODY RESUME"
bodyHandle = AsyncBody("GAMMA", 4)
print "CALLER AFTER BODY HANDLE"
bodyValue$ = await bodyHandle
if bodyValue$ = "GAMMA: 4" then Slice14Passed
print "SLICE 14 FAILED, VALUE ="; bodyValue$
end

Slice14Passed:
    print "SLICE 14 PASSED"
    print "BODY VALUE ="; bodyValue$
    print

print "SLICE 15: LAUNCH-TIME GLOBAL SNAPSHOT"
type AsyncSnapshot
    Name as string
    Count as integer
end type
global shared as integer = 10
global title$ = "SNAP"
global payload as AsyncSnapshot
payload.Name = "Ada"
payload.Count = 7
snapshotHandle = ReadSnapshot(5)
shared = 99
title$ = "LIVE"
payload.Name = "Grace"
payload.Count = 8
snapshotValue$ = await snapshotHandle
if snapshotValue$ = "SNAP: 15:Ada: 7" then Slice15Passed
print "SLICE 15 FAILED, VALUE ="; snapshotValue$
end

Slice15Passed:
    print "SLICE 15 PASSED"
    print "SNAPSHOT VALUE ="; snapshotValue$
    print "LIVE VALUE ="; title$; ":"; shared; ":"; payload.Name; ":"; payload.Count
    print

print "SLICE 16: AWAIT ERROR HANDLING"
on error goto Slice16Handler
failingHandle = FailingAsync()
print "SLICE 16 BEFORE AWAIT"
failingValue = await failingHandle
print "SLICE 16 FAILED"
end

Slice16Handler:
    if err = 11 then Slice16Passed
    print "SLICE 16 FAILED, ERR ="; err
    end

Slice16Passed:
    print "SLICE 16 PASSED"
    print "ERR ="; err
    print "ERL ="; erl
    print
    on error goto 0

print "SLICE 17: TASK WAITER DEBUG SUMMARIES"
print "SLICE 17 HOST/API VERIFIED"
print
print "SLICE 18: CANCELLATION WAKES AWAITERS"
print "SLICE 18 HOST/API VERIFIED"
print
print "SLICE 19: MUTABLE SHARED CELLS"
print "SLICE 19 HOST/API VERIFIED"
print
print "SLICE 20: READ-ONLY CAPTURE REFERENCES"
print "SLICE 20 HOST/API VERIFIED"
print
print "SLICE 21: CAPTURED ENVIRONMENT CELLS"
print "SLICE 21 HOST/API VERIFIED"
print
print "SLICE 22: CAPTURED CLOSURE RUNTIME"
print "SLICE 22 HOST/API VERIFIED"
print
print "SLICE 23: BASIC CLOSURE SYNTAX"
bonus = 5
scoreText = function(value as integer) as string = "SCORE=" + str$(value + bonus)
bonus = 100
if scoreText(7) = "SCORE= 12" then print "SLICE 23 PASSED"
print
print "SLICE 24: EXPLICIT CAPTURE POLICY"
prefix$ = "LOCKED="
bonus = 5
explicitScore = function(value as integer) as string captures readonly prefix$ = prefix$ + str$(value + bonus)
prefix$ = "LIVE="
bonus = 20
if explicitScore(2) = "LOCKED= 22" then print "SLICE 24 PASSED"
print
print "SLICE 25: FUNCTION TYPE CLOSURE VARIABLES"
function type ScoreFormatter(value as integer) as string
local typedScore as ScoreFormatter
typedScore = function(points as integer) as string = "TYPED=" + str$(points)
if typedScore(25) = "TYPED= 25" then print "SLICE 25 PASSED"
print
print "SLICE 26: FUNCTION TYPE CALLBACKS AND FACTORIES"
callbackScore$ = RenderScore(16, typedScore)
factoryScore = MakeFormatter("FACTORY=")
if callbackScore$ = "TYPED= 16" then Slice26CallbackPassed
print "SLICE 26 FAILED, CALLBACK ="; callbackScore$
end

Slice26CallbackPassed:
    if factoryScore(26) = "FACTORY= 26" then Slice26Passed
    print "SLICE 26 FAILED, FACTORY ="; factoryScore(26)
    end

Slice26Passed:
    print "SLICE 26 PASSED"
    print "CALLBACK ="; callbackScore$
    print "FACTORY ="; factoryScore(26)
    print

print "SLICE 27: MULTI-LINE CLOSURES"
blockPrefix$ = "BLOCK="
blockBonus = 1
blockScore = function(value as integer) as string
    local adjusted as integer = value + blockBonus
    return blockPrefix$ + str$(adjusted)
end function
blockPrefix$ = "LIVE="
blockBonus = 100
if blockScore(26) = "BLOCK= 27" then Slice27Passed
print "SLICE 27 FAILED, VALUE ="; blockScore(26)
end

Slice27Passed:
    print "SLICE 27 PASSED"
    print "BLOCK ="; blockScore(26)
    print

print "SLICE 28: BLOCKING/COOPERATIVE JOIN"
joinHandle = AsyncBody("JOIN", 28)
print "CALLER BEFORE JOIN"
join joinHandle
print "CALLER AFTER JOIN"
print "SLICE 28 PASSED"
print

print "SLICE 29: DEBUGGER TASK-LIST UI"
print "SLICE 29 STUDIO UI VERIFIED"
print

print "SLICE 30: TASK-OWNED STACK AND LOCALS"
print "SLICE 30 STUDIO UI VERIFIED"
print
print "SLICE 31: TASK-OWNED GLOBAL SNAPSHOT FILTERING"
print "SLICE 31 STUDIO UI VERIFIED"
print
print "SLICE 32: TASK-SPECIFIC STEPPING"
print "SLICE 32 HOST/UI VERIFIED"
print
print "SLICE 33: SHELL TASK STATUS COMMANDS"
print "SLICE 33 HOST/API VERIFIED"
print
print "SLICE 34: CLOSURE DEBUGGER VISIBILITY"
print "SLICE 34 HOST/UI VERIFIED"
print
print "SLICE 35: WORKER-LANE API PREP"
print "SLICE 35 HOST/API VERIFIED"
print
print "SLICE 36: STUDIO WORKER-LANE MIGRATION"
print "SLICE 36 STUDIO HOST VERIFIED"
print
print "SLICE 37: SHELL FOREGROUND WORKER LANE"
print "SLICE 37 SHELL HOST VERIFIED"
print
print "FUTURE SLICES"
print "38. EVENT LOOP DESIGN"
print
print "ASYNC SUITE BASELINE COMPLETE"
end

async function AsyncAdd(a as integer, b as integer) as integer
    return a + b
end function

async function AsyncBody(name$ as string, count as integer) as string
    print "ASYNC BODY "; name$; " "; count
    return name$ + ":" + str$(count)
end function

async function ReadSnapshot(extra as integer) as string
    return title$ + ":" + str$(shared + extra) + ":" + payload.Name + ":" + str$(payload.Count)
end function

async function FailingAsync() as integer
    return 10 / 0
end function

function RenderScore(value as integer, formatter as ScoreFormatter) as string
    return formatter(value)
end function

function MakeFormatter(prefix$ as string) as ScoreFormatter
    return function(value as integer) as string = prefix$ + str$(value)
end function

AddOne:
    total = total + 1
    return

AddTwo:
    total = total + 2
    return
