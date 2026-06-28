# INKEY$ Function

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Returns one pending key without blocking. If no key is waiting, returns an empty string.

In the default `OPTION BASICSHELL-KEYS` mode, printable keys return themselves. Special keys return readable bracket-prefixed strings, such as `"[K"` for Left Arrow, `"[H"` for Up Arrow, and `"[F1"` for F1. Shift, Command, and Option/Alt are encoded after the bracket when the host reports them; Control status is ignored for special keys.

In BASICStudio, connected gamepad button and digital direction presses are also reported through `INKEY$` as strings beginning with `"[GP:"`, such as `"[GP:A"` or `"[GP:DPAD_LEFT"`.

`OPTION IBM-KEYS` returns GW-BASIC-style extended key strings for special keys: `CHR$(0)` followed by the IBM scan-code-compatible character.

```basic
print "Press a key"
k$ = inkey$

if k$ = "[K" then print "LEFT"
if k$ = "[F1" then print "F1"
if k$ = "[GP:A" then print "GAMEPAD A"

option ibm-keys
k$ = inkey$
if len(k$) = 2 and asc(left$(k$, 1)) = 0 then print "IBM EXTENDED KEY"
```
