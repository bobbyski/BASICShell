# LINE INPUT Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Reads one complete line into a string variable without treating commas as separators.

```basic
line input "Name: "; name$
print name$
```

`LENGTH` sets the visible field width. `MAX` sets the maximum number of
characters accepted. When `MAX` is greater than `LENGTH`, interactive hosts use
a fixed-width field that scrolls horizontally as the input grows.

```basic
line input "Name: "; name$ length 20 max 60
```

`EXITVAR` can be combined with `LENGTH` and `MAX`.

```basic
line input "Choice: "; choice$ length 12 max 30 exitvar key$
```

`LINE INPUT#` reads one complete line from a legacy sequential input file.

```basic
open "notes.txt" for input as #1
line input #1, line$
print line$
close #1
```

Use `INPUT#` when reading comma-separated fields from a file.
