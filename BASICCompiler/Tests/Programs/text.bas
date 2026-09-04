Name$ = "Ada"
Age = 36
PRINT $"Hello ${Name$}, you are ${Age} years old and ${Age + 1} next year."
PRINT $"Bool: ${Age > 30} and ${1 = 2}"
PRINT "No ${substitution} here"
OPTION STRING-SUB ON
PRINT "Now ${Name$} substitutes"
OPTION STRING-SUB OFF
PRINT "And ${Name$} does not"
PRINT USING "##.##"; 3.14159
PRINT USING "Total: $#,###.## for !"; 1234.5; "Ada"
PRINT USING "+###"; 42; -7
PRINT USING "&|&"; "left"; "right"
PRINT USING "###"; 12345
PRINT USING "**##.#"; 2.5
PRINT USING "no fields"; 1
PRINT USING "##"; 1;
PRINT " same line"
