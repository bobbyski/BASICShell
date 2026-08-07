# EOF() Function

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Returns `TRUE` when a legacy numbered file's current position has reached the end of its contents. Text positions count characters; RAW/BINARY positions count bytes.

```basic
open "notes.txt" for input as #1
while eof(1) = false
    line input #1, line$
    print line$
wend
close #1
```

`WHILE`/`WEND` is not implemented yet; for now use `EOF()` with `IF` and `GOTO`.

```basic
open "notes.txt" for input as #1
Again:
    if eof(1) then Done
    line input #1, line$
    print line$
    goto Again
Done:
close #1
```
