# LOCAL Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Creates or updates a variable in the current local context. `GOSUB` pushes a local context and `RETURN` pops it.

```basic
option local-let
gosub Work
end

Work:
local temp as integer = 5
print temp
return
```
