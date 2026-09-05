# RECORD Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Declares a value with named fields, like [TYPE](TYPE.md).

```basic
record Pair
    a as integer
    b as string
end record

dim r as Pair
r.a = 1
r.b = "two"
print r.a; r.b
```

prints `1two`.

A record is a **value**: assigning one to another variable copies it, and passing one to a function passes a copy. That is the difference from [CLASS](CLASS.md), where two names can refer to the same object.

Fields can carry metadata for [reflection](REFLECTION.md) and JSON:

```basic
record Person
    name as string meta { "json": "full_name" }
    age as integer
end record
```
