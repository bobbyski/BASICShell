# RETURN Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Returns from the most recent `GOSUB`. Using `RETURN` without a matching `GOSUB` is a runtime error.

```basic
gosub Work
end
Work:
print "WORKING"
return
```
