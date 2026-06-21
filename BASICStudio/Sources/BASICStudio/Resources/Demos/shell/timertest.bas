#!/usr/bin/env BASICShell
' Minimal timer event smoke test.

print "TIMER TEST"
print "Prints once every 5 seconds."
print "Resize or mouse up to print event payloads."
print "Press Q to exit."

let timer = SecondsTimer(5)
timer.repeating = true
timer.start()
on timer gosub TimerTick
on resize call ResizeChanged
on mouse up call MouseUp

MainLoop:
    key$ = inkey$()
    if key$ = "q" then Done
    if key$ = "Q" then Done
    yield
    goto MainLoop

function TimerTick(event as variant)
    print "Timer fired at "; time$()
end function

function ResizeChanged(event as variant)
    print "Resize "; int(event("width")); " x "; int(event("height"))
end function

function MouseUp(event as variant)
    print "Mouse up button "; int(event("button")); " at "; int(event("x")); ","; int(event("y"))
end function

Done:
    print "Timer test done."
    end
