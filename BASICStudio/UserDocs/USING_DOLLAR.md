# USING$() Function

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Returns a formatted string using the same first-pass format language as `PRINT USING`. The format string is the first argument; each remaining argument is formatted into the next field.

Supported fields include numeric `#` placeholders, decimal points, comma grouping, `$`, leading `+`, `*` fill, `!` for the first character of a string, and `&` for a full string. If a numeric value does not fit in its field, the field is filled with `%` characters.

```basic
print using$("TOTAL ###.##", 12.3)
print using$("$#,###.##", 1234.5)
print using$("NAME ! &", "Ada", "Lovelace")
```
