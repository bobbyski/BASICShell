# ERR And ERL Functions

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Return information about the most recent trapped runtime error. `ERR` returns the error number. `ERL` returns the BASIC source line where the error occurred, using the physical source line for line-number-free programs.

```basic
on error goto Problem
error 42
end

Problem:
    print "ERROR NUMBER "; ERR
    print "ERROR LINE "; ERL
```
