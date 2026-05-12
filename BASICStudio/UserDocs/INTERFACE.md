# INTERFACE Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![Shell](https://img.shields.io/badge/Shell-supported-brightgreen)

Defines a named interface contract. Phase I supports function signatures inside the interface body. Class declarations may name an interface with `IMPLEMENTS`; method-body enforcement and dispatch are planned next.

```basic
interface Printable
    function Title() as string
end interface
```
