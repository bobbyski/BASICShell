#! /usr/bin/env BASICShell
' Traditional BASIC graphics command test.
' This intentionally avoids the direct VectorTerminal SDK wrapper.

cls
screen 1
color 2
line (80,80)-(220,80), 2
line (220,80)-(220,160), 2
line (220,160)-(80,160), 2
line (80,160)-(80,80), 2
paint (150,120), 6, 2
line (80,80)-(220,160), 1
line (220,80)-(80,160), 2
circle (150,120), 28, 3
pset (150,120), 3
pset (260,90), 4
draw "C5R50D30L50U30"
locate screenheight - 5, 1
print "BASIC GRAPHICS COMMAND TEST"
print "POINT CENTER =", point(150,120)
print "Legacy BASIC graphics commands completed."
locate screenheight - 2, 1
print "Press any key to exit.";
wait$ = input$(1)
cls
end
