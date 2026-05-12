# IMPORT Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![Shell](https://img.shields.io/badge/Shell-supported-brightgreen)

Loads declarations from another `.bas` source file before running the current program. Imported top-level statements are parsed for declarations but are not executed in this first pass, so imported files should contain shared `TYPE`, `INTERFACE`, `CLASS`, and `FUNCTION` definitions.

```basic
import "math.bas"

print AddOne(4)
```

```basic
function AddOne(value as integer) as integer
    return value + 1
end function
```
