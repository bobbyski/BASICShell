# GLOBAL Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Creates or updates a variable in the global context. `GLOBAL` can include `AS <type>` and an optional initializer.

`GLOBAL` can declare scalar values, dictionaries, records/classes, and arrays. If no initializer is provided, the variable gets the default value for its type.

```basic
global total as integer = 0
global name$ as string = "BASICSHELL"
global done as boolean = true
global sharedScores(2) as integer
```
