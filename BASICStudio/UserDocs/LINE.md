# LINE Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-VTG%20terminal-brightgreen)

Draws a line between two graphics points. If no color is provided, the current graphics color from `COLOR` is used.

Numeric colors use the legacy BASICShell palette. Quoted full-color values may use hex, named colors, or RGBA bytes.

BASICShell supports `LINE` only when VTG graphics are available.

```basic
screen 1
line (10,10)-(310,190), 2
color "#22c55e"
line (10,190)-(310,10)
```
