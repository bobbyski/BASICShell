# Data Types

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

| Type | Holds |
| --- | --- |
| `INTEGER` | A whole number. |
| `SINGLE` | A number with a fraction. |
| `DOUBLE` | A number with a fraction, kept more precisely. |
| `STRING` | Text. |
| `BOOLEAN` | `TRUE` or `FALSE`. |
| `VARIANT` | Anything, decided as the program runs. |
| `DICTIONARY` | Keys and values. |
| `TASK` | Work in progress — see [ASYNC and AWAIT](ASYNC_AWAIT.md). |
| `VOID` | Nothing. Only a function's return type. |

```basic
dim count as integer
dim ratio as double
dim name$ as string
dim ready as boolean
dim anything as variant

ready = true
anything = 5
print ready; anything
```

prints `TRUE5`: a BOOLEAN shows as `TRUE` or `FALSE`, and the VARIANT shows the number it was given.

A name ending in `$` is a string whether or not it is declared, which is the old convention and still the shortest way to write one.

`VARIANT` is what a value is when nothing says otherwise. It costs a check at run time and buys the ability to hold whatever turns up — from a dictionary, a JSON document, or a function that can answer more than one kind of thing.

See [TYPE](TYPE.md) and [CLASS](CLASS.md) for types you declare yourself, and [DIM](DIM.md) for declaring variables.
