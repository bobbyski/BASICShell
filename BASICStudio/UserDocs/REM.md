# REM Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Adds a comment. `REM` ignores the rest of the physical line, including characters that would otherwise be parsed as BASIC syntax. Apostrophe and `//` can also start trailing comments. `#` is accepted only at the start of a physical line, which keeps room for dialects where `#` is part of an identifier.

```basic
rem This is a comment
rem print "This ; never runs"
' apostrophe comment
# shell-style comment
// slash comment
print "RUNS" ' trailing apostrophe comment
print "ALSO RUNS" // trailing slash comment
print "COMMENTS ARE IGNORED"
```
