# PSET Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-VTG%20terminal-brightgreen)

Sets one graphics pixel to a color. If no color is provided, the current graphics color from `COLOR` is used.

Numeric colors use the legacy BASICShell palette. Quoted full-color values may use hex, named colors, or RGBA bytes.

BASICShell supports `PSET` only when VTG graphics are available.

`PSET` remains supported for compatibility, but it can be expensive for graphics-heavy programs because each visible pixel may become retained VTG drawing state. Prefer vector primitives such as `LINE`, `CIRCLE`, `PAINT`, and `DRAW` when possible.

```basic
screen 1
color "orange"
pset (160,100), 3
pset (170,100)
print point(160,100)
```
