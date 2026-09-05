# Trigonometric Functions

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Angles are in **radians**. Use `RAD` and `DEC` to convert.

| Function | Answers |
| --- | --- |
| `SIN(x)` `COS(x)` `TAN(x)` | Sine, cosine, tangent. |
| `ASN(x)` `ACS(x)` `ATN(x)` | Arc sine, arc cosine, arc tangent. |
| `SEC(x)` `CSC(x)` `COT(x)` | Secant, cosecant, cotangent — the reciprocals of cosine, sine and tangent. |
| `HSN(x)` `HCS(x)` `HTN(x)` | Hyperbolic sine, cosine and tangent. |
| `RAD(x)` | Degrees as radians. |
| `DEC(x)` | Radians as degrees. |

```basic
print rad(180)
print dec(3.141592653589793)
print atn(1) * 4
```

prints `3.141592653589793`, `180` and `3.141592653589793` — the last being the old way of getting pi out of a machine that has no name for it.

There is no `PI`. `ATN(1) * 4` or `RAD(180)` is how you write it.
