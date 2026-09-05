# TRON and TROFF Statements

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Turns statement tracing on and off. With tracing on, each statement is reported as it runs — which is the oldest way there is of finding out where a program actually went.

```basic
tron
y = 2 + 2
troff
print "y="; y
```

The trace goes to the log rather than into the program's own output, so it does not disturb what the program prints. In BASICStudio it appears in the log pane; see [LOG](LOG.md).

Turn it on around the part you are suspicious of rather than over the whole program: tracing a loop of a million passes produces a million lines.
