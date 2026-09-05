# PAUSE Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Stops until Return is pressed.

```basic
print "before"
pause
print "after"
```

It prints `PAUSE` and waits. Where there is nobody to press anything — a program reading from a file or a pipe — it prints `PAUSE` and carries straight on, so a script does not hang on it.

Use it to hold a screen still long enough to read. To wait for a length of time instead, see [SLEEP](SLEEP.md); to read something the person types, see [INPUT](INPUT.md).
