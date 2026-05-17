# NULL Value

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Represents a JSON-style null value. `NULL` is distinct from `EMPTY`; `EMPTY` is the default uninitialized variant value, while `NULL` is an explicit absence value used by JSON parsing and serialization.

```basic
dim payload as dictionary
payload("missing") = NULL
print ToJsonString(payload, false)
```

```basic
let parsed = FromJsonString("null", true)
print parsed
```
