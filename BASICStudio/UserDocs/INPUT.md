# INPUT Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Reads a value from the host. Numeric variables require numeric input. String variables end with `$`.

```basic
input name$
print "HELLO", name$
input age
print age + 1
```

`INPUT#` reads comma-separated fields from a legacy sequential file opened for `INPUT`.

```basic
open "data.txt" for output as #1
print #1, "Ada,16"
close #1

open "data.txt" for input as #1
input #1, name$, age
print name$, age
close #1
```

Use `INPUT$()` when you need a fixed number of characters instead of comma-separated fields.
