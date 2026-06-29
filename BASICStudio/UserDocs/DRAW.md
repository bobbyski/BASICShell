# DRAW Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-VTG%20terminal-brightgreen)

Draws connected line segments from a compact motion string. `DRAW` starts at the current graphics point, which is updated by `PSET`, `PRESET`, `LINE`, `CIRCLE`, `PAINT`, and previous `DRAW` commands.

Supported commands are `U`, `D`, `L`, `R`, diagonals `E`, `F`, `G`, `H`, `M x,y`, `C n`, `S n`, `A n`, `B`, and `N`. Distances default to `1` when omitted. `B` moves without drawing the next motion. `N` draws the next motion without updating the current graphics point. `S` scales following motion commands, where `S4` is normal size. `A` rotates following relative motion by quarter turns: `A0`, `A1`, `A2`, or `A3`.

BASICShell supports `DRAW` only when VTG graphics are available.

Contiguous `DRAW` motion segments are batched as VTG polylines by Studio and Shell. Blank moves, no-update moves, and color changes still preserve classic `DRAW` cursor behavior.

```basic
screen 1
color 2
pset (100,100)
draw "R40D40L40U40"

draw "C3BM160,80R50D30L50U30"
draw "C1M+20,+20E20F20G20H20"
draw "S8A1R20A0S4D20"
```
