# Logical Operators

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

`NOT`, `AND`, `OR`, `XOR`, `EQV` and `IMP` work on truth rather than bits. Every one of them answers `1` or `0`, and every one treats any non-zero number as true.

| Operator | True when |
| --- | --- |
| `NOT a` | `a` is false. |
| `a AND b` | both are true. |
| `a OR b` | either is true. |
| `a XOR b` | exactly one is true. |
| `a EQV b` | both are true or both are false — equivalence. |
| `a IMP b` | `a` is false, or `b` is true — implication. Only `1 IMP 0` is false. |

```basic
print not 0, not 5
print 1 and 0, 1 or 0
print 1 xor 1, 1 eqv 0, 1 imp 0
```

prints `1`, `0` — then `0`, `1` — then `0`, `0`, `0`.

## Precedence

Loosest first:

    IMP
    EQV
    XOR
    OR
    AND
    NOT
    = <> < <= > >=

So `a = 1 AND b = 2` compares before it combines, which is what you want and not what C would do. Parenthesise when you mean otherwise.
