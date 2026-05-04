# SAVE Command and Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Writes the current program listing to a text file. Give `SAVE` a string path the first time. After a successful `SAVE` or `LOAD`, `SAVE` with no path reuses that last file name. It can be used directly at the prompt or as a program statement.

```basic
save "demo.bas"
```

```basic
load "demo.bas"
10 print "UPDATED"
save
```

```basic
65535 save"demo.bas"
run 65535
```
