#!/usr/bin/env BASICShell
' LINE INPUT EXITVAR manual test.
' Type text, then press Enter or a special key.
' F10 or Escape exits the test.

option local-let
option aibasic-keys

let text$ = "COFFEE-001"
let key$ = ""

print "LINE INPUT EXITVAR TEST"
print "Type text. Press arrows, Tab, F-keys, Escape, or Enter."
print "F10 or Escape exits."
print

Loop:
    print "Field: ";
    line input text$ length 30 default text$ exitvar key$
    print "Text = "; text$
    print "Exit = "; KeyName$(key$)
    print
    if key$ = "[F10" then Done
    if key$ = chr$(27) then Done
    goto Loop

Done:
    print "DONE"
end

function KeyName$(k$ as string) as string
    if k$ = "" then return "NORMAL ENTER"
    if k$ = chr$(8) then return "BACKSPACE"
    if k$ = chr$(9) then return "TAB"
    if k$ = "[!T" then return "SHIFT+TAB"
    if k$ = chr$(10) then return "LINE FEED"
    if k$ = chr$(13) then return "RETURN"
    if k$ = chr$(27) then return "ESCAPE"

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
