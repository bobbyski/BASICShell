# GOSUB Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Calls a subroutine at a line number or label. The subroutine must return with `RETURN`.

```basic
gosub "Banner"
print "BACK"
end

LABEL "Banner"
print "BASICSHELL"
return
```
