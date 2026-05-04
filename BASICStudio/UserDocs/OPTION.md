# OPTION

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Sets interpreter options. `OPTION GLOBAL-LET` is the default and makes `LET` create global variables. `OPTION LOCAL-LET` makes `LET` create variables in the current local context when one is active.

```basic
option global-let
let shared = 1

option local-let
gosub Demo
print shared
end

Demo:
let shared = 2
print shared
return
```
