' {{NAME}} — a console program.
'
' Everything here runs the same way under BASICShell and basicc:
' the interpreter is the reference, the compiler matches it.

PRINT "Hello from {{NAME}}!"
INPUT "What is your name? "; Name$
IF Name$ = "" THEN Name$ = "stranger"
PRINT "Nice to meet you, "; Name$; "."

FOR I = 1 TO 5
  PRINT I; " squared is "; I * I
NEXT I
