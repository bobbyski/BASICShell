# LIST Command

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Lists the current program. In BASICStudio, `LIST` mirrors the editor contents.

Planned syntax:

```basic
list [[beginning-line]-[ending-line]][ check]
```

`CHECK` will list the selected range and include parser/linter diagnostics. Warnings should be shown in yellow and errors in red where the host supports color.

```basic
list
```

```basic
list 100-200 check
```
