# SCREEN Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-VTG%20terminal-brightgreen)

Selects a graphics mode and enables the graphics host.

In the current VTG implementation, `SCREEN` accepts classic mode numbers for source compatibility, but visible drawing uses native VTG canvas coordinates. Legacy fixed-resolution scaling, visible pages, and dialect-specific palettes are planned later.

In BASICShell, graphics require a VTG-capable terminal. Use `BASICShell --graphics=auto`, `--graphics=vtg`, or `--graphics=off` to control shell graphics policy.

```basic
screen 1
line (0,0)-(319,199), 1
```
