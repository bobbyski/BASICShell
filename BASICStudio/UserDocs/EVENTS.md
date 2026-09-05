# ON ... CALL: Events

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Registers a handler to be run when something happens.

```basic
on mouse call MouseChanged
on mouse move call MouseMoved
on mouse up call MouseUp
on resize call ResizeChanged
on gamepad call GamepadChanged
```

The handler is named, not written inline, and is called with the event's details. A timer takes `GOSUB` and a label instead:

```basic
let timer = SecondsTimer(1)
timer.repeating = true
timer.start()
on timer gosub TimerTick
```

Registering a handler is also what turns the input on: a program that asks for mouse events gets mouse reporting enabled for it, and one that does not is not charged for it. [OPTION MOUSE](OPTION.md) and `OPTION GAMEPAD` override that either way.

Handlers run between statements, so a program has to keep running for them to fire — a loop reading [INKEY$](INKEY.md), or a TUI application's own loop. A program that has ended is not listening.

See [TUTORIAL_GRAPHICS](TUTORIAL_GRAPHICS.md) for a worked example.
