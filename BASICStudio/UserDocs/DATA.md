# DATA Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Stores literal values inside the program for later `READ` statements. `DATA` statements are skipped during normal execution.

```basic
data Ada, 18, TRUE
read name$, score%, passed
print name$, score%, passed
```

Values may be numbers, quoted strings, unquoted words, `TRUE`, or `FALSE`.
