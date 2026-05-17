# DIM Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Creates an array or typed variable. Array bounds are inclusive and zero-based, so `DIM a(2)` creates elements `a(0)`, `a(1)`, and `a(2)`.

```basic
dim scores(2) as integer
scores(0) = 10
scores(1) = 20
scores(2) = scores(0) + scores(1)
print scores(2)
```

String suffixes still infer type when no `AS` clause is provided.

```basic
dim names$(1)
names$(0) = "Ada"
names$(1) = names$(0) + " Lovelace"
print names$(1)
```

`DIM` can also create variables or arrays using a user-defined `TYPE`.

```basic
dim student as Student
dim roster(10) as Student
```

For scoped declarations, use `LOCAL`, `GLOBAL`, or `LET` with the same array/type shape.

```basic
local scratch(2) as integer
global shared as dictionary
let report as FancyReport
```

Use `*` inside the parentheses for variable-length arrays that resize when JSON is decoded into them. `()` is accepted as shorthand for a one-dimensional dynamic array, but `(*)` makes the intent clearer. Multidimensional dynamic arrays use one `*` per rank.

```basic
let scores(*) as integer
scores = FromJsonString("[10,20,30]", true)
print len(scores)

let grid(*, *) as integer
grid = FromJsonString("[[1,2],[3,4]]", true)
print grid(1, 1)
```
