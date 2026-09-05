# Sequential Files: PRINT#, WRITE# and INPUT#

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Reading and writing a text file from beginning to end. For fixed-length records addressed by number, see [Random and Binary Files](RANDOM_FILES.md).

```basic
open "/tmp/notes.txt" for output as #1
print #1, "alpha"
write #1, "beta", 42
close #1

open "/tmp/notes.txt" for input as #1
line input #1, first$
input #1, word$, count
close #1

print first$
print word$; count
```

prints `alpha`, then `beta42` — the semicolon joins without spacing.

| | Does |
| --- | --- |
| `PRINT #n, ...` | Writes as `PRINT` would — for people to read. |
| `WRITE #n, ...` | Writes with strings quoted and values separated by commas — for `INPUT #` to read back. |
| `INPUT #n, ...` | Reads comma-separated values into variables. |
| `LINE INPUT #n, s$` | Reads one whole line, commas and all. |
| `RESET #n` | Returns to the start of the file. |
| `EOF(n)` | True when there is no more to read. |

The two ways of writing are not interchangeable, and choosing wrongly is the classic way to lose an afternoon. `PRINT #1, "beta", 42` writes `beta` and `42` spaced into print zones; `WRITE #1, "beta", 42` writes `"beta",42`. Only the second reads back correctly with `INPUT #`.

```basic
open "/tmp/notes.txt" for input as #1
while not eof(1)
    line input #1, line$
    print line$
wend
close #1
```

See [OPEN](OPEN.md) for the modes a file can be opened in, and [EOF](EOF.md).
