# LINE INPUT# Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Reads one complete line from a legacy sequential input file into a variable.

```basic
open "notes.txt" for input as #1
line input #1, line$
print line$
close #1
```

`LINE INPUT#` keeps commas and other text exactly as part of the line. Use `INPUT#` when reading comma-separated fields.
