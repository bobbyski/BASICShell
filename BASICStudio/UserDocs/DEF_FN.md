# DEF Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Defines a function on one line, in the old style.

```basic
def fnsq(x) = x * x
print fnsq(5)
```

prints `25`.

The name begins with `FN`, the parameters are in brackets, and everything after `=` is the expression the call becomes. There is no separate end: the line is the whole definition.

For anything longer than an expression, use [FUNCTION](FUNCTION.md), which has a body, statements and a return type.
