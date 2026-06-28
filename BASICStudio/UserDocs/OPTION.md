# OPTION Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Sets interpreter options. `OPTION GLOBAL-LET` is the default and makes `LET` create global variables. `OPTION LOCAL-LET` makes `LET` create variables in the current local context when one is active.

`OPTION BASICSHELL-KEYS` is the default keyboard mode for `INKEY$`. It returns readable special-key strings such as `"[K"` for Left Arrow and `"[F1"` for F1. `OPTION IBM-KEYS` switches `INKEY$` to GW-BASIC-style extended key strings using `CHR$(0)` as the first character.

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

```basic
option basicshell-keys
k$ = inkey$

option ibm-keys
k$ = inkey$
```
