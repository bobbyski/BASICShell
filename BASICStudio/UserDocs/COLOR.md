# COLOR Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Sets the current text foreground color and optional text background color. In graphics-capable hosts, the foreground color also becomes the default drawing color for graphics commands that omit an explicit color.

In BASICShell, text color works in normal ANSI terminals. Graphics color is applied only when VTG graphics are available.

Classic palette indexes are numeric. Full-color values are strings and may be hex, named colors, or comma-separated RGBA bytes. The `#` prefix is optional for hex strings. Alpha may be omitted and defaults to 100%.

```basic
screen 1
color 2, 0
print "Green text on black"
pset (160,100)

color "orange,alpha: 50%", "000000"
line (10,10)-(100,100)

color "255,0,0,128"
pset (40,40)
```
