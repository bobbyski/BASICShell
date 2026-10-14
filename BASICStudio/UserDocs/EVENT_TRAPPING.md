# ON TIMER, ON KEY, ON PLAY: Event Trapping

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

GW-BASIC's event traps: a `GOSUB` to a line when something happens, checked as each statement of the program starts.

```basic
ON TIMER(n) GOSUB line      ' n seconds after TIMER ON, and every n after
ON KEY(n) GOSUB line        ' F1–F10 are 1–10; Up, Left, Right, Down are 11–14
ON PLAY(n) GOSUB line       ' the background music queue drops below n notes
ON STRIG(n) GOSUB line      ' joystick button
ON COM(n) GOSUB line        ' serial port
ON PEN GOSUB line           ' light pen
TIMER ON | OFF | STOP       ' likewise KEY(n), PLAY, STRIG(n), COM(n), PEN
```

- **`ON`** arms a trap. **`OFF`** disarms it, and what happens meanwhile is forgotten. **`STOP`** holds it: what happens is remembered, and the trap fires as soon as it is `ON` again.
- **While its handler runs,** a trap is held, so it never fires inside itself. The handler's `RETURN` turns it back on, unless the handler turned it `OFF`.
- **`GOSUB 0`** turns a trap off. The target may be a label as well as a line.
- **Keys 15–20** are yours to define, as GW defines them: `KEY 15, CHR$(0) + CHR$(30)` makes key 15 the A key, by its keyboard scan code. A key a trap takes is not seen by [INKEY$](INKEY.md).
- **`ON PLAY`** watches music playing in the background (`PLAY "MB…"`).
- **No hardware:** `STRIG`, `COM` and `PEN` arm and disarm, but never fire. `KEY ON`, `KEY OFF`, `STRIG ON` and `STRIG OFF` do nothing.

Traps fire only while a program runs, never at the prompt. They wait while an [ON ERROR](ON_ERROR.md) handler runs, and while a `FUNCTION` runs, firing when the main program goes on.

```basic
10 ON TIMER(1) GOSUB 100
20 TIMER ON
30 IF TICKS < 3 THEN 30
40 PRINT "done"
50 END
100 TICKS = TICKS + 1: PRINT "tick"; TICKS
110 RETURN
```

Handlers that are functions, called with an event's details, are [ON ... CALL](EVENTS.md).
