# INPUT$() Function

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Reads a fixed amount. `INPUT$(count, #file)` reads characters from a text handle or exact bytes from a BINARY handle and advances its position. The `#` is optional inside the function. `INPUT$(count)` reads normalized keyboard input from the host and waits until the requested number of key presses is available.

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

Binary example:

```basic
open "payload.bin" for binary as #1
payload$ = input$(lof(1), 1)
close #1
```
