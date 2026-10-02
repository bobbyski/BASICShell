# KEYDOWN Function

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Returns 1 while a key is held down and 0 when it is not. Use it in a game loop for keys you hold: turning, thrusting, walking. `INKEY$` is still the way to read keys you press once, such as fire, pause, or a letter typed.

```basic
while running
    if KEYDOWN("LEFT") or KEYDOWN("A") then angle = angle - 5
    if KEYDOWN("RIGHT") or KEYDOWN("D") then angle = angle + 5
    if KEYDOWN("UP") then Thrust()

    k$ = inkey$
    if k$ = " " then Fire()
    if k$ = "q" then running = 0
wend
```

## Naming a key

Name a key the way you read it. All of these mean the left arrow: `"LEFT"`, `"[K"` (what `INKEY$` returns for it), and `CHR$(0) + "K"` (the `OPTION IBM-KEYS` form). Letters can be either case.

| Keys | Names |
|---|---|
| Arrows | `LEFT`, `RIGHT`, `UP`, `DOWN` |
| Editing | `SPACE` (or `" "`), `ENTER` (or `RETURN`), `TAB`, `ESCAPE` (or `ESC`), `BACKSPACE`, `DELETE`, `INSERT` |
| Navigation | `HOME`, `END`, `PAGEUP`, `PAGEDOWN` |
| Modifiers | `SHIFT`, `CONTROL` (or `CTRL`), `OPTION` (or `ALT`), `COMMAND` (or `CMD`) |
| Function keys | `F1` to `F24` |
| Letters, digits, punctuation | the character itself, such as `"A"`, `"7"`, or `","` |

A name `KEYDOWN` does not know is an error.

## How it knows

BASICStudio sees each key go down and come up, on the Mac and on an iPad with a hardware keyboard, so `KEYDOWN` is exact there.

A terminal only sends keys as they repeat, and never says when a key comes up. In BASICShell, and in compiled programs, `KEYDOWN` counts a key as held while `INKEY$` keeps seeing it, so the program must keep reading `INKEY$` every frame. Expect a held key to start a moment late and stop a moment late, and a single tap to read as a short hold.

`KEYDOWN` does not take keys out of the queue: a held key still arrives at `INKEY$` too, once and then repeating. A program that moves with `KEYDOWN` should ignore those keys when it reads `INKEY$`, or they count twice.
