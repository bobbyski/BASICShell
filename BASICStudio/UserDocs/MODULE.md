# MODULE Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Names the module that [LOG](LOG.md) messages are filed under from this point on.

```basic
module "Payroll"
log info, "starting"
```

It does not declare a namespace and does not change what any name means — it labels log output, so a program with several parts can have its messages sorted by which part wrote them.

For splitting a program across files, see [IMPORT](IMPORT.md).
