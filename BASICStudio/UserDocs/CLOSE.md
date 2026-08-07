# CLOSE Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Closes one legacy numbered file handle, or all numbered handles when no file number is supplied.

```basic
open "notes.txt" for output as #1
print #1, "HELLO"
close #1
```

```basic
open "a.txt" for output as #1
open "b.txt" for output as #2
close
```

Modern File objects use `file.close` or `file.close()`. Closing retains path and summary information for the debugger but rejects further I/O until the object is opened again.
