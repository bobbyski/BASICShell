# PAINT Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-VTG%20terminal-brightgreen)

Flood-fills the contiguous graphics region at a point. The fill starts at the point and replaces connected pixels that match the starting pixel. An optional border color can be supplied for compatibility with classic BASIC source.

Numeric colors use the legacy BASICShell palette. Quoted full-color values may use hex, named colors, or RGBA bytes.

BASICShell supports `PAINT` only when VTG graphics are available. Large fills can create many retained VTG pixels, so this is currently best for modest regions.

```basic
screen 1
line (80,80)-(220,80), 2
line (220,80)-(220,160), 2
line (220,160)-(80,160), 2
line (80,160)-(80,80), 2
paint (150,120), "orange", 2
```
