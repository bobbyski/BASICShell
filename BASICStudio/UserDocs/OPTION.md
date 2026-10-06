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

## OPTION GRAPHICS-ON-STOP

What BASICShell does with a program's graphics when the program stops on a break (Ctrl-C) or a runtime error, in a terminal that draws them, such as VGTerm.

| Value | What happens |
| --- | --- |
| `HIDE` (the default) | The graphics are hidden so the error, its caret and the prompt can be read. The picture is kept: the terminal's Show Graphics brings it back to look at, and `RUN` or `CLS` shows the graphics again, starting afresh. |
| `CLEAR` | The graphics are erased. |
| `KEEP` | The graphics are left showing, over the error. |

A program that ends normally is not affected: its graphics are erased when it ends, as before. Graphics you have hidden yourself stay hidden. The first time graphics are hidden this way BASICShell says so under the error, once.

Set it in `~/.BASICrc` to have it in every shell; see [Startup Files](STARTUP_FILES.md).

```basic
' ~/.BASICrc
option graphics-on-stop keep
```

BASICStudio has the same choice in its settings, under Console ▸ Graphics, and does not read this option. A compiled program accepts it and ignores it.
