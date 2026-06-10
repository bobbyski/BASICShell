#! /usr/bin/env BASICShell
' Traditional BASIC graphics command test.
' This intentionally avoids the direct VectorTerminal SDK wrapper.

print "BASIC GRAPHICS COMMAND TEST"
screen 1
color 2
line (20,20)-(180,20), 2
line (180,20)-(180,120), 3
line (180,120)-(20,120), 1
line (20,120)-(20,20), 2
line (20,20)-(180,120), 1
line (180,20)-(20,120), 2
pset (100,70), 3
print "POINT CENTER =", point(100,70)
print "Legacy BASIC graphics commands completed."
end
