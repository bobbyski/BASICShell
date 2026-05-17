# LEN() Function

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Returns the displayed character count for a string, not the byte count. NUL bytes from `CHR$(0)` are not counted. When passed an array, returns the number of elements in the array.

```basic
print len("HELLO")
print len("A" + chr$(0) + "B")

let scores(*) as integer
scores = FromJsonString("[10,20,30]", true)
print len(scores)

let grid(*, *) as integer
grid = FromJsonString("[[1,2],[3,4]]", true)
print len(grid)
```
