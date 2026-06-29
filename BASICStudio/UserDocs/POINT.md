# POINT() Function

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-VTG%20terminal-brightgreen)

Returns the legacy palette color at a graphics pixel.

`POINT()` reads BASICShell's semantic framebuffer, so it returns the same palette-style value in BASICStudio and VTG-capable shell sessions. Full RGBA readback is not defined yet; full-color drawing currently stores its legacy palette fallback for `POINT()`.

For Release 1 VTG graphics, `POINT()` is intentionally a compatibility function. It is not a full graphics readback API, and it should not be used for new full-color image processing code.

```basic
screen 1
pset (160,100), 3
print point(160,100)
```
