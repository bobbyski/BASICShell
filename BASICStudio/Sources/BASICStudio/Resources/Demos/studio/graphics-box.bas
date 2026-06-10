print "AIBasic Studio graphics demo"
screen 1
color 2
line (30,50)-(290,50), 2
line (290,50)-(290,180), 3
line (290,180)-(30,180), 1
line (30,180)-(30,50), 2
pset (160,115), 3
print "CENTER =", point(160,100)
locate screenheight - 2, 1
print "Press any key to exit.";
wait$ = input$(1)
cls
end
