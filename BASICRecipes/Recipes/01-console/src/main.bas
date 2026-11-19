' {{NAME}} — a console program.
'
' The smallest program, on purpose: one file of statements, run from the
' top, for trying the language. Everything here runs the same way under
' BASICShell and basicc: the interpreter is the reference, the compiler
' matches it. When a program grows routines of its own, the Structured
' Program shows the next step, and the Game, the TUI App and the ActiveUI
' starters show a program split into files.

' Say hello, then ask who is there. INPUT prints its prompt and waits for a
' line; Name$ is a string because of its $.
PRINT "Hello from {{NAME}}!"
INPUT "What is your name? "; Name$

' Nothing typed is still someone.
IF Name$ = "" THEN Name$ = "stranger"
PRINT "Nice to meet you, "; Name$; "."

' A loop: I counts from 1 to 5, and each pass prints one line.
FOR I = 1 TO 5
  PRINT I; " squared is "; I * I
NEXT I
