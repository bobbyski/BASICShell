# LOG Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-stubbed-yellow)

Writes a diagnostic message to the log pane. `LOG` uses a `PRINT`-style list after the level, so strings, numbers, variables, expressions, semicolons, and comma tab stops are formatted the same way they are for console output.

`LOG` entries written by BASIC code are User log entries. BASICStudio, BASICShell, and interpreter diagnostics use BASIC/internal log entries.

```basic
log info, "Starting checkout"
log debug, "count="; itemCount
log warn, "Missing optional field "; fieldName$
log target, "menu selected="; selected
```

The level is the expression before the comma. Common levels are `INFO`, `DEBUG`, `WARN`, `ERROR`, and `TARGET`.

Unlike `PRINT`, `LOG` always writes one complete log entry. A trailing semicolon or comma does not keep the entry open.

```basic
module "pos.bas"
log target, "entered main menu"
log target, "selection="; choice, "rows="; rows
```

`MODULE` changes the module name shown in later log entries. If no module is set, AIBasic uses the current BASIC source file name when it is available.

BASICShell currently accepts `LOG`, but the shell logging viewer is stubbed and does not display persistent log entries yet.
