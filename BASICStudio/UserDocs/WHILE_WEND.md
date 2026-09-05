# WHILE...WEND Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Repeats while a condition holds. The test happens before each pass, so a condition that is false to begin with runs the body no times at all.

```basic
i = 1
while i <= 3
    print "i="; i
    i = i + 1
wend
```

prints `i=1`, `i=2`, `i=3`.

`WEND` closes the loop. Nothing advances the loop for you — a `WHILE` whose body never changes the condition runs forever, which is the price of a loop that does not have to count.

Use [FOR...NEXT](FOR_NEXT.md) when you know how many passes there are, and `WHILE` when you do not: reading until the end of a file, retrying until something succeeds, or waiting for a clock to tick over.
