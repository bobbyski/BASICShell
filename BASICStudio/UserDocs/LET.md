# LET and Assignment Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Assigns a value to a variable. `LET` is optional, so plain assignment works too. Variables are case-insensitive. `LET` can include `AS <type>` and follows the active `OPTION GLOBAL-LET` or `OPTION LOCAL-LET` mode.

When `LET` includes a type but no initializer, it creates the default value for that type. `LET` can also declare arrays.

```basic
let x as integer = 42
y = x + 8
name$ = "BASICSHELL"
done as boolean = true
print y, name$
```

```basic
let payload as dictionary
let scores(2) as integer
let report as FancyReport
```
