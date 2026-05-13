# RESTORE Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Resets the `READ` pointer to the beginning of the program's `DATA` values.

```basic
data Ada, Grace
read first$
restore
read again$
print first$, again$
```
