#!/usr/bin/env BASICShell
' Minimal timer event smoke test.

print "TIMER TEST"
print "Prints once every 5 seconds."
print "Press Q to exit."

let timer = SecondsTimer(5)
timer.repeating = true
timer.start()
on timer gosub TimerTick

MainLoop:
    key$ = inkey$()
    if key$ = "q" then Done
    if key$ = "Q" then Done
    yield
    goto MainLoop

function TimerTick(event as variant)
    print "Timer fired at "; time$()
end function

Done:
    print "Timer test done."
    end
