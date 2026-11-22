# DATE$ and TIME$ Functions

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

The clock. Both take no arguments and answer a string.

| Function | Answers |
| --- | --- |
| `DATE$()` | Today, as `MM-DD-YYYY`. |
| `TIME$()` | Now, as `HH:MM:SS` on a 24-hour clock. |
| `CDATE(s$)` | Text as a `DATE`: `CDATE("2026-11-04")`. The same date can be written as a literal, `#2026-11-04#`. |
| `CTIME(s$)` | Text as a `TIME`: `CTIME("13:45:00")`, or `#13:45:00#`. |
| `CDATETIME(s$)` | Text as a `DATETIME`: `CDATETIME("2026-11-04 13:45:00")`, or `#2026-11-04 13:45:00#`. |

```basic
print date$(); " "; time$()
```

prints something like `09-05-2026 18:22:49`.

`TIME$()` counts whole seconds, which is the only clock the language has. A program that wants to measure itself reads it before and after and subtracts — remembering that the two readings can straddle midnight:

```basic
function SecondsOfDay(clock as string) as integer
    return val(left$(clock, 2)) * 3600 + val(mid$(clock, 4, 2)) * 60 + val(mid$(clock, 7, 2))
end function

started = SecondsOfDay(time$())
' ... the work ...
elapsed = SecondsOfDay(time$()) - started
if elapsed < 0 then elapsed = elapsed + 86400
```

Whole seconds is coarse for anything quick. To time something short, run it many times and divide.
