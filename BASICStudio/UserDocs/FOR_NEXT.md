# FOR...NEXT

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Repeats a block while a numeric loop variable moves from a start value to an end value. `STEP` is optional and defaults to `1`. Negative steps count down. A loop whose start is already past the end is skipped.

`NEXT` may omit the variable name, or name the current loop variable. Multiple variables are accepted in one `NEXT` statement for nested loops.

```basic
for i = 1 to 5
print i
next i
```

```basic
for x = 10 to 2 step -2
print x
next
```

```basic
for row = 1 to 2
for col = 1 to 3
print row;",";col
next col
next row
```
