# INPUT$() Function

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Reads a fixed number of characters. `INPUT$(count, #file)` reads from a legacy numbered file opened for `INPUT` and advances that file's read position. `INPUT$(count)` reads normalized keyboard input from the host and waits until the requested number of key presses is available.

```basic
open "raw.txt" for output as #1
print #1, "ABCDEF";
close #1

open "raw.txt" for input as #1
print input$(2, #1)
print input$(3, #1)
print eof(1)
close #1
```

```basic
print "Press two keys"
print input$(2)
```
