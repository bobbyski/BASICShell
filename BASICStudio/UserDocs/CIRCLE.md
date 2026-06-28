# CIRCLE Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-VTG%20terminal-brightgreen)

Draws a circle or ellipse outline centered on a graphics point. If no color is provided, the current graphics color from `COLOR` is used.

Numeric colors use the legacy BASICShell palette. Quoted full-color values may use hex, named colors, or RGBA bytes.

BASICShell supports `CIRCLE` only when VTG graphics are available.

```text
CIRCLE (x,y), radius[, color[, aspect]]
```

`aspect` is the vertical-to-horizontal ratio. Values below `1` draw wider ellipses; values above `1` draw taller ellipses. Omit it for a circle.

```basic
screen 1
circle (160,100), 40, 3
color "#22c55e"
circle (160,100), 60
circle (160,100), 80, "#38bdf8", 0.5
```
