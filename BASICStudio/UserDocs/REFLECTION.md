# Reflection Functions

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Looking at the shape of a value at run time: how many fields it has, what they are called, and what is in them.

| Function | Answers |
| --- | --- |
| `REFLECT(v)` | A dictionary describing `v` itself — its `name`, `path` and `type`. |
| `FIELDCOUNT(v)` | How many fields `v` has. |
| `FIELDMETA(v, which)` | A dictionary describing one field, plus any `META` attached to it. |
| `FIELDVALUE(v, which)` | The value in that field. |
| `FIELDVALUE$(v, which)` | That value as a string. |
| `SETFIELD(v, which, new)` | A **copy** of `v` with that field changed. |

`which` is either the field's position, counting from 0, or its name.

```basic
type Point
    x as integer
    y as integer
end type

dim p as Point
p.x = 3
p.y = 4

print fieldcount(p)
print fieldvalue(p, 0); fieldvalue(p, "y")
print tojsonstring(fieldmeta(p, 0), false)
```

prints `2`, then `34`, then `{"name":"x","path":"x","type":"INTEGER"}`.

`SETFIELD` does not change the value it is given — it hands back a new one:

```basic
q = setfield(p, 0, 99)
print fieldvalue(p, 0); fieldvalue(q, 0)
```

prints `399`: the original still holds 3, the copy holds 99.

## META

A field can carry metadata, which `FIELDMETA` reports alongside the field's own description.

```basic
type Person
    name as string meta { "json": "full_name" }
    age as integer
end type
```

`FIELDMETA(p, 0)` then answers a dictionary carrying `"json": "full_name"` as well as the `name`, `path` and `type`.
