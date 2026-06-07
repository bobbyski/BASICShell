# LIST Command

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Lists the current program. In BASICStudio, `LIST` mirrors the editor contents.

Syntax:

```basic
list [[beginning-line]-[ending-line]][ check]
```

`LIST` preserves the source casing and whitespace stored in the program. Ranges may specify a single line, an open-ended range, or a closed range. `CHECK` includes parser/runtime-shape diagnostics after the listing. BASICStudio and BASICShell render syntax-colored listing output where ANSI color is available, and the color state is reset at the end of the listing.

```basic
list
```

```basic
list 100
```

```basic
list 100-
```

```basic
list -200
```

```basic
list 100-200 check
```
