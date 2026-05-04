# RUN Command

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Runs the current program. In BASICStudio, `RUN` uses the current editor contents. In BASICShell, `RUN` uses the current loaded or typed program. Add a line number to start execution at that line.

```basic
10 print "HELLO"
20 end
run
```

```basic
65535 save"demo.bas"
run 65535
```
