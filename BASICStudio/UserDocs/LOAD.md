# LOAD Command and Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Loads a BASIC source file into the current program. Quoted paths are supported. It can be used directly at the prompt or as a program statement.

```basic
load "basicPrograms/demos/test-suite.bas"
run
```

After a successful `LOAD`, `SAVE` with no path writes back to the loaded file name.
