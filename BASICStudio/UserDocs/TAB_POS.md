# TAB, POS and LOCATE

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Putting text where you want it.

| | Does |
| --- | --- |
| `TAB(n)` | Inside `PRINT`, moves to column `n`. |
| `SPC(n)` | Inside `PRINT`, writes `n` spaces. |
| `POS(n)` | The column the cursor is in. |
| `LOCATE row, column` | Moves the cursor. |

```basic
print "TAB:"; tab(10); "x"
print pos(0)
```

prints `x` at column 10, then `1` — the column the cursor was in at the start of the next line.

`TAB` and `SPC` belong to `PRINT` and cannot be used as ordinary functions. `TAB` moves to an absolute column and `SPC` writes a number of spaces, which is the difference that matters when something has already been printed on the line.

A comma in `PRINT` moves to the next 14-column zone, which is the older and coarser way to line a table up. See [PRINT](PRINT.md).
