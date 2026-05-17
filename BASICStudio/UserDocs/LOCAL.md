# LOCAL Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Creates or updates a variable in the current local context. `GOSUB` pushes a local context and `RETURN` pops it.

`LOCAL` can declare scalar values, dictionaries, records/classes, and arrays. If no initializer is provided, the variable gets the default value for its type.

```basic
option local-let
gosub Work
end

Work:
local temp as integer = 5
local scratch(2) as integer
print temp
return
```
