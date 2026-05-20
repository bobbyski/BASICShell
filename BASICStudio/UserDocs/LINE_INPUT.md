# LINE INPUT Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Reads one complete line into a string variable without treating commas as separators.

```basic
line input "Name: "; name$
print name$
```

`LINE INPUT#` reads one complete line from a legacy sequential input file.

```basic
open "notes.txt" for input as #1
line input #1, line$
print line$
close #1
```

Use `INPUT#` when reading comma-separated fields from a file.
