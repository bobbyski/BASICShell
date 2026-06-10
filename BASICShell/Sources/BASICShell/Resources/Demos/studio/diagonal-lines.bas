print "Diagonal line demo"
screen 1
line (20,50)-(300,190), 1
line (300,50)-(20,190), 2
line (20,120)-(300,120), 3
line (160,50)-(160,190), 2
locate screenheight - 2, 1
print "Press any key to exit.";
wait$ = input$(1)
cls
end
