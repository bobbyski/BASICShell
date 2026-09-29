REM ENVIRON$ in both engines: unset is empty, and a set one is found.
PRINT "["; ENVIRON$("BASIC_NO_SUCH_VARIABLE"); "]"
PRINT ENVIRON$("PATH") <> ""
