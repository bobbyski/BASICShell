# OPTION STRING-SUB

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Turns on `${...}` substitution inside ordinary string literals. Off by default, so a program that means to print a brace prints one.

```basic
option string-sub on
name$ = "world"
count = 3
print "hello ${name$}, ${count * 2} times"
```

prints `hello world, 6 times`.

What is between the braces is a full expression, evaluated where the string is, and rendered the way `PRINT` would render it. `OPTION STRINGSUB ON` is accepted as the same thing, and `OFF` turns it back off.
