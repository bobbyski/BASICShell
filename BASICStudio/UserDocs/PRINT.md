# PRINT Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Displays values in the console. Use commas to advance to the next 14-column print zone, or semicolons to join values without extra spacing.

```basic
print "HELLO"
print "TOTAL =", 10 + 5
print "TOTAL ="; 10 + 5
print "LEFT", "NEXT ZONE"
name$ = "AIBASIC"
print name$
```

`PRINT USING` formats values with a GW-BASIC style format string. The first pass supports numeric `#` fields, decimal points, comma grouping, `$`, leading `+`, `*` fill, overflow markers, `!` for the first character of a string, and `&` for a full string.

```basic
print using "TOTAL ###.##"; 12.3
print using "$#,###.##"; 1234.5
print using "NAME ! &"; "Ada", "Lovelace"
print using "## "; 1, 2, 3
```

`PRINT#` writes to a legacy numbered sequential file opened for `OUTPUT` or `APPEND`.

```basic
open "out.txt" for output as #1
print #1, "HELLO"; " "; 42
print #1, using "TOTAL ###.##"; 12.3
print#1, "NEXT LINE"
close #1
```
