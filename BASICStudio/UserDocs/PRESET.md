# PRESET Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-VTG%20terminal-brightgreen)

Clears one graphics pixel by setting it to color `0`, or to the explicit color provided.

BASICShell supports `PRESET` only when VTG graphics are available.

```basic
screen 1
pset (160,100), 3
preset (160,100)
print point(160,100)
```
