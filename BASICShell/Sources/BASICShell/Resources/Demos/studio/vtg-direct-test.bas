#! /usr/bin/env BASICShell
' Direct VectorTerminal SDK wrapper test.
' Coordinates are native VTG pixels.

cls
print "VTG DIRECT WRAPPER TEST"
print "This should draw retained native-resolution VTG graphics."

let vtg = VectorTerminal()
vtg.clear()
vtg.setDefaultLayer(1)
vtg.rect("panel", 32, 48, 520, 260, "#22c55e", "#07111dcc", 2, 16, 1)
vtg.line("diagonal-a", 48, 64, 536, 292, "#5eead4", 3, 1)
vtg.line("diagonal-b", 536, 64, 48, 292, "#fb7185", 3, 1)
vtg.circle("badge", 292, 178, 56, "#f8fafc", "none", 3, 1)
vtg.ellipse("orbit", 292, 178, 120, 42, "#3b82f6", "none", 2, 1)
vtg.pixel("center-dot", 292, 178, "#f8fafc", 1)
vtg.text("label", 72, 94, "VectorTerminal()", "#f8fafc", 24, 1)
vtg.vectorPrint("retro", 96, 226, 52, "AIBASIC VTG", "#22c55e", 2, 1)
vtg.present()

print "VTG commands sent. Traditional BASIC graphics were not used."
end
