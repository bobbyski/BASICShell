# OPTION Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Sets interpreter options. `OPTION GLOBAL-LET` is the default and makes `LET` create global variables. `OPTION LOCAL-LET` makes `LET` create variables in the current local context when one is active.

`OPTION BASICSHELL-KEYS` is the default keyboard mode for `INKEY$`. It returns readable special-key strings such as `"[K"` for Left Arrow and `"[F1"` for F1. `OPTION IBM-KEYS` switches `INKEY$` to GW-BASIC-style extended key strings using `CHR$(0)` as the first character.

`OPTION MOUSE AUTO` is the default mouse event mode. Mouse input is collected when the program registers an `ON MOUSE ... CALL` handler. `OPTION MOUSE ON` forces mouse input on, and `OPTION MOUSE OFF` suppresses mouse events and asks VTG hosts to disable mouse reporting where possible.

`OPTION GAMEPAD AUTO` is the default gamepad event mode. Gamepad input is accepted when the program registers an `ON GAMEPAD ... CALL` handler. `OPTION GAMEPAD ON` forces gamepad events on, and `OPTION GAMEPAD OFF` suppresses them. BASICShell gamepad events are not part of the MVP.

```basic
option global-let
let shared = 1

option local-let
gosub Demo
print shared
end

Demo:
let shared = 2
print shared
return
```

```basic
option basicshell-keys
k$ = inkey$

option ibm-keys
k$ = inkey$
```

```basic
option mouse auto
on mouse up call MouseUp

option gamepad off
```
