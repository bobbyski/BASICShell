# CIRCLE Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-VTG%20terminal-brightgreen)

Draws a circle outline centered on a graphics point. If no color is provided, the current graphics color from `COLOR` is used.

Numeric colors use the legacy AIBasic palette. Quoted full-color values may use hex, named colors, or RGBA bytes.

BASICShell supports `CIRCLE` only when VTG graphics are available.

```basic
screen 1
circle (160,100), 40, 3
color "#22c55e"
circle (160,100), 60
```
