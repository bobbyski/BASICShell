# LEN() Function

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Returns the displayed character count for a string, not the byte count. NUL bytes from `CHR$(0)` are not counted.

```basic
print len("HELLO")
print len("A" + chr$(0) + "B")
```
