# ERROR Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Raises a runtime error with a numeric error code. If an `ON ERROR GOTO` handler is active, execution jumps to that handler and `ERR` receives the supplied number.

```basic
on error goto Handler
error 42
end

Handler:
    print "TRAPPED "; ERR
```
