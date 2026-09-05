# EDIT Command

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Opens the current program in a full-screen editor.

```basic
edit
```

`^S` commits what is on screen to the program and reports the first syntax error, if there is one, in the status line — where it can still be read, which is the point of putting it there rather than behind the editor. `^X` leaves.

Leaving keeps what you were looking at, saved or not: closing a window here does not throw work away, and `RUN` should run what was just typed. The screen you were on before comes back exactly as it was.

The manual opens the same way — see [HELP](HELP.md).
