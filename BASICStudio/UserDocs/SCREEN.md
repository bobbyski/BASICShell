# SCREEN Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-VTG%20terminal-brightgreen)

Accepts a classic graphics mode request for source compatibility.

In the current VTG implementation, `SCREEN` does not apply legacy fixed-resolution sizing, clear graphics, switch pages, or change palettes. Visible drawing uses native VTG canvas coordinates. Legacy fixed-resolution scaling, visible pages, and dialect-specific palettes are planned later.

In BASICShell, graphics auto-enable when the terminal reports VTG support. Use `BASICShell --graphics=off` only when you deliberately want to run without shell graphics support.

```basic
screen 1
line (0,0)-(319,199), 1
```
