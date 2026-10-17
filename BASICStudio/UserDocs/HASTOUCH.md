# HASTOUCH Function

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Returns 1 when the screen the program runs on takes touch, and 0 when it does not. A game uses it to adjust for being played with a finger: bigger targets, a tap where the mouse would click, and hints that talk about dragging rather than keys.

`HASTOUCH` can be written with or without parentheses: `HASTOUCH` and `HASTOUCH()` are the same.

```basic
' A finger is wider than a mouse pointer, and there are no arrow keys.
if HASTOUCH then
    buttonSize = 64
    hint$ = "DRAG TO STEER, TAP TO SERVE"
else
    buttonSize = 32
    hint$ = "ARROWS OR MOUSE TO STEER, SPACE TO SERVE"
end if
print hint$
```

## Where it is 1

| Running in | `HASTOUCH` |
|---|---|
| BASICStudio on iPad and iPhone | 1 |
| BASICStudio on the Mac | 0 |
| BASICShell | 0 |
| A compiled program, run from a terminal | 0 |
| A compiled program BASICStudio runs | What BASICStudio says: 1 on iPad and iPhone |

## HASTOUCH and TouchControls

`HASTOUCH` needs no `TouchControls()` object, so any program can ask. It says whether the screen takes touch, which it does whether or not the program puts controls on it.

[TouchControls](TOUCH_CONTROLS.md)' `Available` says something narrower: whether on-screen controls will be drawn. Someone playing on an iPad with a game controller can turn the controls off from Console ▸ Show On-Screen Game Controls; `Available` is then FALSE, but the screen still takes touch, so `HASTOUCH` is still 1. Use `Available` to decide whether to show a hint about the on-screen controls, and `HASTOUCH` to decide how to play by touch at all.

```basic
touch = TouchControls()
if touch.Available then
    hint$ = "STICK TO STEER, LAUNCH TO SERVE"
elseif HASTOUCH then
    hint$ = "DRAG TO STEER, TAP TO SERVE"
else
    hint$ = "ARROWS OR MOUSE TO STEER"
end if
```

A touch is the mouse as well (see [EVENTS](EVENTS.md)): a finger going down, dragging and lifting arrives as `ON MOUSE DOWN`, `MOVE` and `UP`, so a game that handles the mouse already works by touch. `HASTOUCH` is for what should look or behave differently when it does.
