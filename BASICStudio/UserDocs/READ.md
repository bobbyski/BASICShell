# READ Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Reads one or more values from the program's `DATA` pool into variables, arrays, record fields, or object fields. Each `READ` advances the shared data pointer.

```basic
dim scores(2) as integer
data 10, 20, 30
read scores(0), scores(1), scores(2)
print scores(0), scores(1), scores(2)
```

Reading past the available data raises `Out of DATA`.
