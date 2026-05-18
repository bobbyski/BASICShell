# OPEN Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Opens a legacy numbered text file handle. The first pass supports sequential `INPUT`, `OUTPUT`, and `APPEND` modes.

```basic
open "notes.txt" for output as #1
print #1, "HELLO"
close #1
```

```basic
open "notes.txt" for input as #1
line input #1, line$
print line$
close #1
```

`INPUT` fails if the file is missing. `OUTPUT` creates or replaces the file. `APPEND` creates the file if needed and writes at the end.
