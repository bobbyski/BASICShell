# ERR And ERL Functions

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Return information about the most recent trapped runtime error. `ERR` returns the error number. `ERL` returns the line of the statement that failed: its BASIC line number, or its physical source line in a program without line numbers. An error inside a `FUNCTION` reports the line inside the function, not the line that called it.

```basic
on error goto Problem
error 42
end

Problem:
    print "ERROR NUMBER "; ERR
    print "ERROR LINE "; ERL
```
