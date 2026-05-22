#! /usr/bin/env aibasic
' INKEY$ manual keyboard test.
' Press keys to see their AIBasic names. Press Control-Q to exit.

option local-let
option aibasic-keys

print "INKEY$ TEST"
print "Press keys to display their names."
print "Press Control-Q to exit."

Loop:
    let k$ = inkey$
    if k$ = "" then Loop
    if k$ = chr$(17) then Done
    print KeyName$(k$)
    goto Loop

Done:
    print "DONE"
end

function KeyName$(k$ as string) as string
    if k$ = chr$(8) then return "BACKSPACE"
    if k$ = chr$(9) then return "TAB"
    if k$ = chr$(10) then return "LINE FEED"
    if k$ = chr$(13) then return "RETURN"
    if k$ = chr$(27) then return "ESCAPE"

    if k$ = "[GP:CONNECTED" then return "GAMEPAD CONNECTED"
    if left$(k$, 4) = "[GP:" then return "GAMEPAD " + mid$(k$, 5)

    if len(k$) = 1 then
        let code as integer = asc(k$)
        if code < 32 then return "CTRL-" + chr$(code + 64) + " (" + str$(code) + ")"
        return "CHAR " + k$
    end if


    let p as integer = 2
    let mods$ = ""

    if mid$(k$, p, 1) = "!" then
        mods$ = mods$ + "SHIFT+"
        p = p + 1
    end if

    if mid$(k$, p, 1) = "$" then
        mods$ = mods$ + "COMMAND+"
        p = p + 1
    end if

    if mid$(k$, p, 1) = "#" then
        mods$ = mods$ + "OPTION+"
        p = p + 1
    end if

    let code$ = mid$(k$, p, 1)

    if code$ = "F" then return mods$ + "FUNCTION " + mid$(k$, p + 1)

    if code$ = "G" then return mods$ + "HOME"
    if code$ = "H" then return mods$ + "UP"
    if code$ = "I" then return mods$ + "PAGE UP"
    if code$ = "K" then return mods$ + "LEFT"
    if code$ = "M" then return mods$ + "RIGHT"
    if code$ = "O" then return mods$ + "END"
    if code$ = "P" then return mods$ + "DOWN"
    if code$ = "Q" then return mods$ + "PAGE DOWN"
    if code$ = "R" then return mods$ + "INSERT"
    if code$ = "S" then return mods$ + "DELETE"
    if mods$ <> "" then return mods$ + "CHAR " + code$

    return "SPECIAL " + k$
end function
